/*
 * Mobile data tray applet for the NX789J (Debian on the Android kernel).
 * Shows the state written by nx-mobiledata (/run/nx/mobiledata.state) and switches data
 * on/off by starting nx-mobiledata-on/-off.service (allowed without a password by
 * /etc/polkit-1/rules.d/50-nx-mobiledata.rules).
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    property var st: ({})
    property bool dataOn: st.enabled === "enabled"
    property bool connected: dataOn && st.active === "active" && st.state === "connected"
    property bool wifi: (st.wifi || "0") !== "0"
    property bool busy: false

    readonly property string statusCmd: "sh -c '"
        + "cat /run/nx/mobiledata.state 2>/dev/null; "
        + "echo enabled=$(systemctl is-enabled nx-mobiledata 2>/dev/null); "
        + "echo active=$(systemctl is-active nx-mobiledata 2>/dev/null); "
        + "i=$(sed -n s/^ifname=//p /run/nx/mobiledata.state 2>/dev/null); "
        + "[ -n \"$i\" ] && echo rx=$(cat /sys/class/net/$i/statistics/rx_bytes 2>/dev/null) && echo tx=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null); "
        + "echo wifi=$(nmcli -t -f TYPE,STATE device 2>/dev/null | grep -c ^wifi:connected); "
        + "sed s/^/u_/ /run/nx/unlock-result 2>/dev/null'"

    property bool needPin: dataOn && st.state === "waiting" && st.reason === "pin"
    property real unlockSent: 0     // seconds; results older than this are not shown

    function simLabel(n) {
        var s = st["sim" + n] || ""
        if (s === "pin") return i18n("locked (PIN)")
        if (s === "puk") return i18n("blocked (PUK)")
        if (s === "absent") return i18n("no SIM")
        if (s === "ready") return st["sim" + n + "op"] || i18n("ready")
        return s ? s : "–"
    }

    function setSlot(s) {
        busy = true
        run("systemctl start --no-block nx-mobiledata-slot@" + s + ".service")
        settle.restart()
    }

    function unlockText() {
        if (parseFloat(st.u_time || "0") < unlockSent) return unlockSent > 0 ? i18n("Checking the PIN…") : ""
        switch (st.u_result) {
        case "ok": return i18n("PIN accepted, connecting…")
        case "notlocked": return i18n("The SIM is not locked")
        case "wrong": return i18n("Wrong PIN – %1 attempt(s) left", st.u_remaining)
        case "blocked": return i18n("The SIM is blocked: it needs its PUK (enter it in Android)")
        case "error": return i18n("Could not unlock (%1)", st.u_reason || st.u_error || "?")
        default: return ""
        }
    }

    function unlock(slot, pin) {
        if (!/^[0-9]{4,8}$/.test(pin)) return false
        unlockSent = Date.now() / 1000 - 2
        // printf is a shell builtin: the PIN is in no command line; the file is 600 and the
        // root unit deletes it after reading it once
        run("sh -c 'umask 077; printf %s " + pin + " > /run/user/$(id -u)/nx-sim-pin && "
            + "systemctl start --no-block nx-mobiledata-unlock@" + slot + ".service'")
        return true
    }

    function iconName() {
        if (!dataOn) return "network-mobile-off"
        if (!connected) return "network-mobile-available"
        var lv = [0, 40, 60, 80, 100][Math.max(0, Math.min(4, parseInt(st.signal || "0")))]
        return "network-mobile-" + lv + (st.rat === "5g" ? "-5g" : "-lte")
    }

    function statusText() {
        if (!dataOn) return i18n("Off")
        if (busy) return i18n("Switching…")
        if (st.active !== "active" && st.active !== "activating") return i18n("Not running")
        switch (st.state) {
        case "connected": return wifi ? i18n("Connected (Wi-Fi is used while it is connected)") : i18n("Connected")
        case "connecting": return i18n("Connecting…")
        case "starting": return i18n("Starting…")
        case "waiting": return st.reason === "pin" ? i18n("SIM %1 is locked: enter its PIN", st.pinslot)
                                                   : i18n("Waiting: %1", (st.reason || "").replace(/_/g, " "))
        case "failed": return i18n("Failed: %1", (st.reason || "").replace(/_/g, " "))
        default: return i18n("Not connected")
        }
    }

    function size(b) {
        b = parseFloat(b || "0")
        if (b >= 1073741824) return (b / 1073741824).toFixed(2) + " GB"
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB"
        return Math.round(b / 1024) + " KB"
    }

    function run(cmd) { exec.connectSource(cmd) }

    function setData(on) {
        busy = true
        run("systemctl start --no-block nx-mobiledata-" + (on ? "on" : "off") + ".service")
        settle.restart()
    }

    Plasmoid.icon: iconName()
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    toolTipMainText: i18n("Mobile data")
    toolTipSubText: connected ? (st.operator || "") + (st.rat ? " · " + st.rat.toUpperCase() : "") + "\n" + statusText()
                              : statusText()


    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source !== root.statusCmd) { poll.restart(); return }
            var o = {}
            var lines = (data.stdout || "").split("\n")
            for (var i = 0; i < lines.length; i++) {
                var p = lines[i].indexOf("=")
                if (p > 0) o[lines[i].substring(0, p)] = lines[i].substring(p + 1)
            }
            root.st = o
        }
    }

    Timer {
        id: poll
        interval: root.expanded ? 2000 : 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.run(root.statusCmd)
    }
    Timer { id: settle; interval: 3000; onTriggered: root.busy = false }

    // no own compactRepresentation: the default one (Plasmoid.icon) gets the tray's tap/click
    // handling; an extra MouseArea made a tap open and close the popup at once

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 18
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Kirigami.Icon {
                source: root.iconName()
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }
            Kirigami.Heading {
                text: i18n("Mobile data")
                level: 3
                Layout.fillWidth: true
            }
            PlasmaComponents3.Switch {
                checked: root.dataOn
                enabled: !root.busy
                onToggled: root.setData(checked)
            }
        }

        PlasmaComponents3.Label {
            text: root.statusText()
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        // data SIM: Auto picks the first unlocked SIM that is on a network
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: ["auto", "1", "2"]
                delegate: PlasmaComponents3.Button {
                    required property string modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    checkable: true
                    checked: (root.st.choice || "auto") === modelData
                    enabled: !root.busy
                    text: modelData === "auto" ? i18n("Auto") : i18n("SIM %1", modelData)
                    PlasmaComponents3.ToolTip.text: modelData === "auto" ? i18n("First unlocked SIM on a network")
                                                                         : root.simLabel(modelData)
                    PlasmaComponents3.ToolTip.visible: hovered
                    onClicked: { checked = Qt.binding(() => (root.st.choice || "auto") === modelData); root.setSlot(modelData) }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label { text: i18n("SIM 1: %1", root.simLabel("1")); opacity: 0.7; Layout.fillWidth: true; elide: Text.ElideRight }
            PlasmaComponents3.Label { text: i18n("SIM 2: %1", root.simLabel("2")); opacity: 0.7; Layout.fillWidth: true; elide: Text.ElideRight }
        }

        // PIN entry for a locked SIM (not stored: once per Linux boot, like Android asks once per boot)
        ColumnLayout {
            visible: root.needPin
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents3.TextField {
                    id: pinField
                    Layout.fillWidth: true
                    placeholderText: i18n("PIN of SIM %1", root.st.pinslot || "")
                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,8}/ }
                    onAccepted: unlockButton.clicked()
                }
                PlasmaComponents3.Button {
                    id: unlockButton
                    text: i18n("Unlock")
                    icon.name: "unlock"
                    enabled: /^[0-9]{4,8}$/.test(pinField.text)
                    onClicked: { if (root.unlock(root.st.pinslot, pinField.text)) pinField.text = "" }
                }
            }
            PlasmaComponents3.Label {
                text: root.unlockText() || i18n("Careful: 3 wrong PINs block the SIM until its PUK is entered.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: root.unlockText() ? 1 : 0.6
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        GridLayout {
            columns: 2
            columnSpacing: Kirigami.Units.largeSpacing
            rowSpacing: Kirigami.Units.smallSpacing
            visible: root.dataOn
            Layout.fillWidth: true

            PlasmaComponents3.Label { text: i18n("Network:"); opacity: 0.7 }
            PlasmaComponents3.Label {
                text: (root.st.operator || "–") + (root.st.slot ? i18n("  (SIM %1)", root.st.slot) : "")
                Layout.fillWidth: true; elide: Text.ElideRight
            }
            PlasmaComponents3.Label { text: i18n("Signal:"); opacity: 0.7 }
            PlasmaComponents3.Label {
                text: root.st.signal !== undefined
                      ? i18n("%1 of 4 bars, %2 dBm, %3", root.st.signal, root.st.dbm, (root.st.rat || "").toUpperCase())
                      : "–"
            }
            PlasmaComponents3.Label { text: i18n("APN:"); opacity: 0.7 }
            PlasmaComponents3.Label { text: root.st.apn || "–" }
            PlasmaComponents3.Label { text: i18n("Address:"); opacity: 0.7 }
            PlasmaComponents3.Label { text: root.connected ? (root.st.address || "–") : "–" }
            PlasmaComponents3.Label { text: i18n("Data used:"); opacity: 0.7 }
            PlasmaComponents3.Label {
                text: root.connected ? i18n("↓ %1   ↑ %2  (this connection)", root.size(root.st.rx), root.size(root.st.tx)) : "–"
            }
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label {
                text: i18n("Settings: /etc/nx-mobiledata.conf")
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            PlasmaComponents3.Button {
                text: i18n("Reconnect")
                icon.name: "view-refresh"
                enabled: root.dataOn && !root.busy
                onClicked: {
                    root.busy = true
                    root.run("systemctl restart --no-block nx-mobiledata.service")
                    settle.restart()
                }
            }
        }
    }
}
