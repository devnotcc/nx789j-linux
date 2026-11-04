# Download and unpack Valve's ARM64 Steam client packages (manifest steam_client_linuxarm64)
# into a separate Steam root next to the x86 install. Run as the desktop user.
import hashlib, os, re, subprocess, sys, urllib.request
BASE = "https://client-update.steamstatic.com/"
ROOT = os.path.expanduser("~/.local/share/SteamArm64")
PKG = ROOT + "/package"
os.makedirs(PKG, exist_ok=True)
man = urllib.request.urlopen(BASE + "steam_client_linuxarm64", timeout=30).read()
open(PKG + "/steam_client_linuxarm64.manifest", "wb").write(man)
s = man.decode().replace("\r", "")
for m in re.finditer(r'\t"([^"]+)"\n\t\{\n(.*?)\n\t\}', s, re.S):
    d = dict(re.findall(r'"(\w+)"\t\t"([^"]*)"', m.group(2)))
    f = PKG + "/" + d["file"]
    if not (os.path.exists(f) and os.path.getsize(f) == int(d["size"])):
        subprocess.check_call(["curl", "-sfL", "--retry", "3", "-o", f, BASE + d["file"]])
    h = hashlib.sha256(open(f, "rb").read()).hexdigest()
    if h != d["sha2"]:
        sys.exit("checksum mismatch: " + d["file"])
    subprocess.check_call(["unzip", "-qo", f, "-d", ROOT])
    print("ok", m.group(1), d["size"], flush=True)
print("DONE")
