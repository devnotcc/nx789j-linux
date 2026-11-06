import android.hardware.radio.RadioResponseInfo;
import android.hardware.radio.config.IRadioConfig;
import android.hardware.radio.data.DataProfileInfo;
import android.hardware.radio.data.IRadioData;
import android.hardware.radio.data.LinkAddress;
import android.hardware.radio.data.SetupDataCallResult;
import android.hardware.radio.data.TrafficDescriptor;
import android.hardware.radio.modem.IRadioModem;
import android.hardware.radio.network.IRadioNetwork;
import android.hardware.radio.network.RegStateResult;
import android.os.IBinder;

/**
 * Mobile data without the Android framework (Linux boots on the NX789J).
 *
 * The vendor radio stack (qcrild = radio AIDL HALs, dataqti, ipacm) keeps running when the
 * framework is held down; only the phone process that normally drives it is missing. This tool
 * talks to the HALs the way the framework's RIL does: it registers itself as the response /
 * indication receiver, powers the radio on, makes the slot the data SIM, waits for packet
 * registration and sets up a data call. It prints the result as "NX key=value" lines and stays
 * running (the HAL calls back into this process) until it is stopped, then tears the call down.
 *
 * Run as root: CLASSPATH=nx-radio.dex app_process /system/bin NxRadio up --slot 2 --apn net
 * Commands: up | status. Exit codes: 0 stopped, 2 usage, 3 call lost, 4 setup failed.
 */
public final class NxRadio {
    static int serial = 1000;
    static IRadioData data;
    static int cid = -1;

    static void log(String s) { System.err.println("nx-radio: " + s); System.err.flush(); }
    static void out(String s) { System.out.println("NX " + s); System.out.flush(); }

    static IBinder service(String name) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder b = (IBinder) sm.getMethod("waitForDeclaredService", String.class).invoke(null, name);
        if (b == null) throw new IllegalStateException("no service " + name);
        return b;
    }

    /** Waits for the response with this serial; returns its args (args[0] = RadioResponseInfo). */
    static Object[] await(int s, String what, long ms) throws Exception {
        long end = System.currentTimeMillis() + ms;
        while (true) {
            long left = end - System.currentTimeMillis();
            if (left <= 0) throw new IllegalStateException(what + ": no response");
            Ev e = Ev.next(left);
            if (e == null) continue;
            if (e.args.length > 0 && e.args[0] instanceof RadioResponseInfo
                    && ((RadioResponseInfo) e.args[0]).serial == s) {
                int err = ((RadioResponseInfo) e.args[0]).error;
                if (err != 0) log(what + ": error " + err);
                return e.args;
            }
            handleIndication(e);
        }
    }

    static int error(Object[] r) { return ((RadioResponseInfo) r[0]).error; }

    /**
     * Per slot: SIM state and packet registration, after switching the radio on. One line each:
     * "NX slot=1 sim=ready|pin|puk|absent|other reg=1 rat=14 plmn=22601" (reg 1 home, 5 roaming).
     */
    static void probe() throws Exception {
        String[] simState = new String[3];
        IRadioNetwork[] nets = new IRadioNetwork[3];
        for (int slot = 1; slot <= 2; slot++) {
            String sl = "slot" + slot;
            try {
                android.hardware.radio.sim.IRadioSim sim = android.hardware.radio.sim.IRadioSim.Stub.asInterface(
                        service("android.hardware.radio.sim.IRadioSim/" + sl));
                sim.setResponseFunctions(new NxCbSimResponse(), new NxCbSimIndication());
                int s = serial++; sim.getIccCardStatus(s);
                android.hardware.radio.sim.CardStatus c = (android.hardware.radio.sim.CardStatus) await(s, "getIccCardStatus", 10000)[1];
                String st = "other";
                if (c.cardState == 0) st = "absent";
                else if (c.applications != null && c.gsmUmtsSubscriptionAppIndex >= 0
                        && c.gsmUmtsSubscriptionAppIndex < c.applications.length) {
                    int a = c.applications[c.gsmUmtsSubscriptionAppIndex].appState;
                    st = a == 5 ? "ready" : a == 2 ? "pin" : a == 3 ? "puk" : "app" + a;
                }
                simState[slot] = st;
                if (!st.equals("ready")) continue;
                IRadioModem modem = IRadioModem.Stub.asInterface(service("android.hardware.radio.modem.IRadioModem/" + sl));
                modem.setResponseFunctions(new NxCbModemResponse(), new NxCbModemIndication());
                try { s = serial++; modem.enableModem(s, true); await(s, "enableModem", 15000); }
                catch (Exception e) { log(sl + " enableModem: " + e.getMessage() + " (ignored)"); }
                s = serial++; modem.setRadioPower(s, true, false, false);
                await(s, "setRadioPower", 30000);
                nets[slot] = IRadioNetwork.Stub.asInterface(service("android.hardware.radio.network.IRadioNetwork/" + sl));
                nets[slot].setResponseFunctions(new NxCbNetworkResponse(), new NxCbNetworkIndication());
            } catch (Exception e) {
                log(sl + ": " + e.getMessage());
                simState[slot] = "error";
            }
        }
        // registration can take a while after the radio comes on
        RegStateResult[] reg = new RegStateResult[3];
        for (int i = 0; i < 45; i++) {
            boolean waiting = false;
            for (int slot = 1; slot <= 2; slot++) {
                if (nets[slot] == null || (reg[slot] != null && (reg[slot].regState == 1 || reg[slot].regState == 5))) continue;
                int s = serial++; nets[slot].getDataRegistrationState(s);
                reg[slot] = (RegStateResult) await(s, "getDataRegistrationState", 10000)[1];
                if (reg[slot].regState != 1 && reg[slot].regState != 5) waiting = true;
            }
            if (!waiting) break;
            Thread.sleep(1000);
        }
        for (int slot = 1; slot <= 2; slot++) {
            RegStateResult r = reg[slot];
            String op = "";
            if (r != null) {
                try { op = r.cellIdentity.getLte().operatorNames.alphaLong; } catch (Exception ignored) { }
                if (op == null || op.isEmpty()) {
                    try { op = r.cellIdentity.getNr().operatorNames.alphaLong; } catch (Exception ignored) { }
                }
            }
            out("slot=" + slot + " sim=" + simState[slot] + " reg=" + (r == null ? 0 : r.regState)
                    + " rat=" + (r == null ? 0 : r.rat) + " plmn=" + (r == null || r.registeredPlmn == null ? "" : r.registeredPlmn)
                    + " op=" + (op == null ? "" : op.replace("%", "%25").replace(" ", "%20")));
        }
    }

    static void diag(int s, String what) {
        try {
            Object[] r = await(s, what, 10000);
            StringBuilder b = new StringBuilder(what).append(": error=").append(error(r));
            for (int i = 1; i < r.length; i++) b.append(' ').append(java.util.Arrays.deepToString(new Object[] {r[i]}));
            out(b.toString());
        } catch (Exception e) { out(what + ": " + e.getMessage()); }
    }

    /** Indications that arrive while waiting for something else. */
    static String lastSignal = "";

    /** Signal level 0-4 the way Android computes it (CellSignalStrengthLte/Nr RSRP thresholds). */
    static void signal(android.hardware.radio.network.SignalStrength ss) {
        String rat = null;
        int dbm = 0, level = 0;
        // the HAL reports RSRP as a positive number (95 = -95 dBm); INT_MAX = unknown
        if (ss.nr != null && ss.nr.ssRsrp > 0 && ss.nr.ssRsrp < 200) {
            rat = "5g"; dbm = -ss.nr.ssRsrp;
            level = dbm >= -65 ? 4 : dbm >= -80 ? 3 : dbm >= -90 ? 2 : dbm >= -110 ? 1 : 0;
        } else if (ss.lte != null && ss.lte.rsrp > 0 && ss.lte.rsrp < 200) {
            rat = "lte"; dbm = -ss.lte.rsrp;
            level = dbm >= -85 ? 4 : dbm >= -95 ? 3 : dbm >= -105 ? 2 : dbm >= -115 ? 1 : 0;
        }
        if (rat == null) return;
        String s = "signal level=" + level + " rat=" + rat + " dbm=" + dbm;
        // report level/rat changes at once, the dBm value at most every ~5 dB
        if (s.equals(lastSignal)) return;
        if (!lastSignal.isEmpty() && lastSignal.startsWith("signal level=" + level + " rat=" + rat + " ")) {
            int old = Integer.parseInt(lastSignal.substring(lastSignal.lastIndexOf('=') + 1));
            if (Math.abs(old - dbm) < 5) return;
        }
        lastSignal = s;
        out(s);
    }

    /**
     * Enters the SIM PIN of a slot. The PIN is read from stdin (one line), never from the command
     * line, and is not stored. Prints "NX unlock result=ok|wrong|blocked|notlocked|error ..."
     * with the remaining attempts the modem reports.
     */
    static void unlock(int slot) throws Exception {
        String pin = new java.io.BufferedReader(new java.io.InputStreamReader(System.in)).readLine();
        if (pin == null || !pin.trim().matches("[0-9]{4,8}")) { out("unlock result=error reason=format"); return; }
        pin = pin.trim();
        android.hardware.radio.sim.IRadioSim sim = android.hardware.radio.sim.IRadioSim.Stub.asInterface(
                service("android.hardware.radio.sim.IRadioSim/slot" + slot));
        sim.setResponseFunctions(new NxCbSimResponse(), new NxCbSimIndication());
        int s = serial++; sim.getIccCardStatus(s);
        android.hardware.radio.sim.CardStatus c = (android.hardware.radio.sim.CardStatus) await(s, "getIccCardStatus", 10000)[1];
        int idx = c.gsmUmtsSubscriptionAppIndex;
        if (c.applications == null || idx < 0 || idx >= c.applications.length) { out("unlock result=error reason=no-app"); return; }
        android.hardware.radio.sim.AppStatus app = c.applications[idx];
        if (app.appState == 5) { out("unlock result=notlocked"); return; }
        if (app.appState == 3) { out("unlock result=blocked reason=puk"); return; }
        s = serial++; sim.supplyIccPinForApp(s, pin, app.aidPtr);
        Object[] r = await(s, "supplyIccPinForApp", 20000);
        int err = error(r), left = (Integer) r[1];
        if (err == 0) out("unlock result=ok remaining=" + left);
        else if (err == 3) out("unlock result=" + (left == 0 ? "blocked" : "wrong") + " remaining=" + left);
        else out("unlock result=error error=" + err + " remaining=" + left);
    }

    static void handleIndication(Ev e) {
        if (e.name.equals("currentSignalStrength")) {
            signal((android.hardware.radio.network.SignalStrength) e.args[1]);
            return;
        }
        if (!e.name.equals("dataCallListChanged") || cid < 0) return;
        SetupDataCallResult[] list = (SetupDataCallResult[]) e.args[1];
        for (SetupDataCallResult r : list) {
            if (r.cid == cid && r.active != 0) { print(r, "update"); return; }
        }
        out("lost cid=" + cid);
        log("data call " + cid + " is gone");
        cid = -1;
        System.exit(3);
    }

    static void print(SetupDataCallResult r, String state) {
        StringBuilder a = new StringBuilder();
        if (r.addresses != null) for (LinkAddress l : r.addresses) a.append(a.length() > 0 ? "," : "").append(l.address);
        out(state + " cid=" + r.cid + " ifname=" + r.ifname + " addresses=" + a
                + " gateways=" + String.join(",", r.gateways == null ? new String[0] : r.gateways)
                + " dns=" + String.join(",", r.dnses == null ? new String[0] : r.dnses)
                + " mtu4=" + r.mtuV4 + " mtu6=" + r.mtuV6 + " type=" + r.type);
    }

    static int protocol(String ip) {
        switch (ip) {
            case "ipv4": return 0;      // PdpProtocolType.IP
            case "ipv6": return 1;      // IPV6
            case "ipv4v6": return 2;    // IPV4V6
            default: throw new IllegalArgumentException("--ip ipv4|ipv6|ipv4v6");
        }
    }

    public static void main(String[] argv) throws Exception {
        String cmd = argv.length > 0 ? argv[0] : "";
        int slot = 2;
        String apn = null, ip = "ipv4v6";
        for (int i = 1; i < argv.length; i++) {
            switch (argv[i]) {
                case "--slot": slot = Integer.parseInt(argv[++i]); break;
                case "--apn": apn = argv[++i]; break;
                case "--ip": ip = argv[++i]; break;
                case "-v": Ev.verbose = true; break;
                default: log("unknown option " + argv[i]); System.exit(2);
            }
        }
        if (!(cmd.equals("up") || cmd.equals("status") || cmd.equals("diag") || cmd.equals("fix") || cmd.equals("probe")
                || cmd.equals("unlock"))
                || (cmd.equals("up") && apn == null)) {
            log("usage: NxRadio up --slot 1|2 --apn APN [--ip ipv4|ipv6|ipv4v6] [-v] | status|diag --slot 1|2 | probe");
            System.exit(2);
        }
        if (cmd.equals("probe")) { probe(); return; }
        if (cmd.equals("unlock")) { unlock(slot); return; }
        String sl = "slot" + slot;

        IRadioNetwork net = IRadioNetwork.Stub.asInterface(service("android.hardware.radio.network.IRadioNetwork/" + sl));
        net.setResponseFunctions(new NxCbNetworkResponse(), new NxCbNetworkIndication());
        data = IRadioData.Stub.asInterface(service("android.hardware.radio.data.IRadioData/" + sl));
        data.setResponseFunctions(new NxCbDataResponse(), new NxCbDataIndication());

        if (cmd.equals("diag")) {
            // read-only: everything the framework normally sets per slot, printed raw
            android.hardware.radio.sim.IRadioSim sim = android.hardware.radio.sim.IRadioSim.Stub.asInterface(
                    service("android.hardware.radio.sim.IRadioSim/" + sl));
            sim.setResponseFunctions(new NxCbSimResponse(), new NxCbSimIndication());
            IRadioModem modem = IRadioModem.Stub.asInterface(service("android.hardware.radio.modem.IRadioModem/" + sl));
            modem.setResponseFunctions(new NxCbModemResponse(), new NxCbModemIndication());
            int s;
            s = serial++; sim.getIccCardStatus(s); diag(s, "getIccCardStatus");
            s = serial++; sim.areUiccApplicationsEnabled(s); diag(s, "areUiccApplicationsEnabled");
            s = serial++; modem.getModemStackStatus(s); diag(s, "getModemStackStatus");
            s = serial++; modem.getRadioCapability(s); diag(s, "getRadioCapability");
            s = serial++; net.getAllowedNetworkTypesBitmap(s); diag(s, "getAllowedNetworkTypesBitmap");
            s = serial++; net.getNetworkSelectionMode(s); diag(s, "getNetworkSelectionMode");
            s = serial++; net.getVoiceRegistrationState(s); diag(s, "getVoiceRegistrationState");
            s = serial++; net.getDataRegistrationState(s); diag(s, "getDataRegistrationState");
            return;
        }
        if (cmd.equals("fix")) {
            // what the framework does for a SIM that should be in service (each step logged)
            android.hardware.radio.sim.IRadioSim sim = android.hardware.radio.sim.IRadioSim.Stub.asInterface(
                    service("android.hardware.radio.sim.IRadioSim/" + sl));
            sim.setResponseFunctions(new NxCbSimResponse(), new NxCbSimIndication());
            IRadioModem modem = IRadioModem.Stub.asInterface(service("android.hardware.radio.modem.IRadioModem/" + sl));
            modem.setResponseFunctions(new NxCbModemResponse(), new NxCbModemIndication());
            int s;
            s = serial++; modem.enableModem(s, true); diag(s, "enableModem");
            s = serial++; sim.enableUiccApplications(s, true); diag(s, "enableUiccApplications");
            s = serial++; net.setNetworkSelectionModeAutomatic(s); diag(s, "setNetworkSelectionModeAutomatic");
            s = serial++; modem.setRadioPower(s, true, false, false); diag(s, "setRadioPower");
            return;
        }
        if (cmd.equals("status")) {
            int s = serial++; net.getDataRegistrationState(s);
            Object[] r = await(s, "getDataRegistrationState", 10000);
            RegStateResult reg = (RegStateResult) r[1];
            out("reg state=" + reg.regState + " rat=" + reg.rat + " plmn=" + reg.registeredPlmn);
            s = serial++; data.getDataCallList(s);
            r = await(s, "getDataCallList", 10000);
            for (SetupDataCallResult c : (SetupDataCallResult[]) r[1]) print(c, "call");
            return;
        }

        // 1. this SIM carries data (the modem allows data on one SIM at a time)
        IRadioConfig config = IRadioConfig.Stub.asInterface(service("android.hardware.radio.config.IRadioConfig/default"));
        config.setResponseFunctions(new NxCbConfigResponse(), new NxCbConfigIndication());
        int s = serial++; config.setPreferredDataModem(s, (byte) (slot - 1));
        await(s, "setPreferredDataModem", 15000);

        // 2. radio on (the framework does this after boot; without it the modem stays offline)
        IRadioModem modem = IRadioModem.Stub.asInterface(service("android.hardware.radio.modem.IRadioModem/" + sl));
        modem.setResponseFunctions(new NxCbModemResponse(), new NxCbModemIndication());
        // the slot's modem stack can be off (seen on the PIN-locked slot); the framework enables it
        try { s = serial++; modem.enableModem(s, true); await(s, "enableModem", 15000); }
        catch (Exception e) { log("enableModem: " + e.getMessage() + " (ignored)"); }
        s = serial++; modem.setRadioPower(s, true, false, false);
        await(s, "setRadioPower", 30000);

        // legacy switches; qcrild may never answer them (the framework no longer sends them)
        // (setDataAllowed is never answered, setUserDataEnabled is not implemented by this HAL)

        // 3. wait for packet registration (home 1 / roaming 5)
        RegStateResult reg = null;
        for (int i = 0; i < 90; i++) {
            s = serial++; net.getDataRegistrationState(s);
            Object[] r = await(s, "getDataRegistrationState", 10000);
            reg = (RegStateResult) r[1];
            if (error(r) == 0 && (reg.regState == 1 || reg.regState == 5)) break;
            reg = null;
            Thread.sleep(1000);
        }
        if (reg == null) { out("failed reason=not-registered"); System.exit(4); }
        String op = "";
        try { op = reg.cellIdentity.getLte().operatorNames.alphaLong; } catch (Exception ignored) { }
        if (op == null || op.isEmpty()) {
            try { op = reg.cellIdentity.getNr().operatorNames.alphaLong; } catch (Exception ignored) { }
        }
        // operator last: it may contain spaces
        out("registered state=" + reg.regState + " rat=" + reg.rat + " plmn=" + reg.registeredPlmn
                + " operator=" + (op == null ? "" : op));
        // an immediate signal reading (indications only come on change)
        try {
            s = serial++; net.getSignalStrength(s);
            signal((android.hardware.radio.network.SignalStrength) await(s, "getSignalStrength", 10000)[1]);
        } catch (Exception ex) { log("getSignalStrength: " + ex.getMessage()); }
        int access = reg.rat == 20 ? 6 /* NGRAN */ : 3 /* EUTRAN */;

        // 4. calls left over from an earlier run of this tool (it was killed, or crashed) go first;
        //    IMS is not in this list (qcrild/IMS handle that PDN themselves)
        s = serial++; data.getDataCallList(s);
        for (SetupDataCallResult old : (SetupDataCallResult[]) await(s, "getDataCallList", 10000)[1]) {
            log("deactivating old call " + old.cid + " on " + old.ifname);
            int t = serial++; data.deactivateDataCall(t, old.cid, 1 /* NORMAL */);
            await(t, "deactivateDataCall", 15000);
        }

        // 5. the data call
        DataProfileInfo p = new DataProfileInfo();
        p.profileId = DataProfileInfo.ID_DEFAULT;
        p.apn = apn;
        p.protocol = protocol(ip);
        p.roamingProtocol = p.protocol;
        p.authType = 0;           // NO_PAP_NO_CHAP
        p.user = "";
        p.password = "";
        p.type = DataProfileInfo.TYPE_3GPP;
        p.enabled = true;
        p.supportedApnTypesBitmap = 1 | 4 | 16;  // DEFAULT | SUPL | HIPRI
        p.trafficDescriptor = new TrafficDescriptor();
        p.trafficDescriptor.dnn = apn;
        p.infrastructureBitmap = DataProfileInfo.INFRASTRUCTURE_CELLULAR;

        SetupDataCallResult res = null;
        for (int attempt = 1; attempt <= 5 && res == null; attempt++) {
            s = serial++;
            data.setupDataCall(s, access, p, reg.regState == 5, 1 /* NORMAL */,
                    new LinkAddress[0], new String[0], 0, null, true);
            Object[] r = await(s, "setupDataCall", 60000);
            SetupDataCallResult c = (SetupDataCallResult) r[1];
            if (error(r) == 0 && c != null && c.cause == 0 && c.active != 0) { res = c; break; }
            log("setupDataCall attempt " + attempt + ": error " + error(r) + " cause "
                    + (c == null ? "-" : c.cause) + " retry " + (c == null ? 0 : c.suggestedRetryTime) + " ms");
            Thread.sleep(Math.max(3000, Math.min(30000, c == null ? 0 : c.suggestedRetryTime)));
        }
        if (res == null) { out("failed reason=setup"); System.exit(4); }
        cid = res.cid;
        print(res, "up");

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (cid < 0) return;
            try {
                int t = serial++;
                int c = cid;
                cid = -1;   // the main loop must not treat our own teardown as a lost call
                data.deactivateDataCall(t, c, 1 /* NORMAL */);
                Thread.sleep(1500);  // oneway call; give qcrild a moment before the process exits
                out("down cid=" + c);
            } catch (Exception e) { log("deactivate: " + e); }
        }));

        // 6. stay registered as the HAL's client; report changes of our call
        while (true) {
            Ev e = Ev.next(60000);
            if (e != null) handleIndication(e);
        }
    }
}
