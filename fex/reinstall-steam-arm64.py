#!/usr/bin/python3
# Fresh install of Valve's ARM64 Steam client with all client settings reset, games kept.
# Run as the desktop user with Steam closed:   python3 reinstall-steam-arm64.py
#   - downloads the packages of the "steam_client_linuxarm64" manifest (sha256 checked) and
#     unpacks them into a new, empty Steam folder
#   - moves the old folder aside to ~/.local/share/Steam.old-<date> (nothing is deleted) and moves
#     the games (steamapps: games, Proton prefixes, tools, shader cache) and the per-game user
#     data (userdata/<account>/<appid>: saves, game settings) into the new one
#   - client settings start empty (sign-in, window layout, download settings, launch options);
#     only the "run Windows games with the ARM64 Proton" mapping is written again, without it
#     no game starts on this phone
import hashlib, os, re, shutil, stat, sys, time, urllib.request, zipfile

BASE = 'https://client-update.steamstatic.com/'
HOME = os.path.expanduser('~')
ROOT = HOME + '/.local/share/Steam'
NEW = ROOT + '.new'
OLD = ROOT + '.old-' + time.strftime('%Y%m%d-%H%M')
CACHE = HOME + '/.cache/nx-steam-packages'

if os.path.exists(NEW): shutil.rmtree(NEW)
os.makedirs(NEW + '/package'); os.makedirs(CACHE, exist_ok=True)

man = urllib.request.urlopen(BASE + 'steam_client_linuxarm64', timeout=30).read()
open(NEW + '/package/steam_client_linuxarm64.manifest', 'wb').write(man)
text = man.decode().replace('\r', '')
version = re.search(r'"version"\t\t"(\d+)"', text)
print('client version', version.group(1) if version else '?', flush=True)
n = 0
for m in re.finditer(r'\t"([^"]+)"\n\t\{\n(.*?)\n\t\}', text, re.S):
    d = dict(re.findall(r'"(\w+)"\t\t"([^"]*)"', m.group(2)))
    if 'file' not in d: continue
    f = CACHE + '/' + d['file']
    for attempt in range(3):
        if not (os.path.exists(f) and os.path.getsize(f) == int(d['size'])):
            urllib.request.urlretrieve(BASE + d['file'], f)
        if hashlib.sha256(open(f, 'rb').read()).hexdigest() == d['sha2']: break
        os.remove(f)
    else:
        sys.exit('checksum mismatch: ' + d['file'])
    shutil.copy(f, NEW + '/package/' + d['file'])
    # the archives use backslashes in names and store symbolic links as entries
    with zipfile.ZipFile(f) as z:
        for i in z.infolist():
            name = i.filename.replace('\\', '/')
            if name.startswith('/') or '..' in name.split('/'): sys.exit('bad path in ' + d['file'])
            dst = NEW + '/' + name
            mode = i.external_attr >> 16
            if name.endswith('/'):
                os.makedirs(dst, exist_ok=True); continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.lexists(dst): os.remove(dst)
            if stat.S_ISLNK(mode):
                os.symlink(z.read(i).decode(), dst)
            else:
                with z.open(i) as src, open(dst, 'wb') as out: shutil.copyfileobj(src, out)
                os.chmod(dst, (mode & 0o777) or 0o644)
    n += 1
    print('ok', m.group(1), d['size'], flush=True)
# the archives carry no file modes: programs, libraries and scripts must be executable
for dp, dn, fn in os.walk(NEW):
    if dp.startswith(NEW + '/package'): continue
    for f in fn:
        q = os.path.join(dp, f)
        if os.path.islink(q): continue
        with open(q, 'rb') as h: head = h.read(4)
        if head == b'ELF' or head[:2] == b'#!': os.chmod(q, 0o755)
if not os.access(NEW + '/steamrtarm64/steam', os.X_OK):
    sys.exit('the unpacked client has no steamrtarm64/steam - nothing was changed')
print(n, 'packages unpacked', flush=True)

# the mapping that makes Steam run Windows games (and CS2's Windows build) in the ARM64 Proton
os.makedirs(NEW + '/config')
open(NEW + '/config/config.vdf', 'w').write('''"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"730"
					{
						"name"		"proton-experimental-arm64"
						"config"		""
						"priority"		"250"
					}
					"0"
					{
						"name"		"proton-experimental-arm64"
						"config"		""
						"priority"		"75"
					}
				}
			}
		}
	}
}
''')

os.rename(ROOT, OLD)
os.rename(NEW, ROOT)
os.rename(OLD + '/steamapps', ROOT + '/steamapps')
# per-game user data back, client settings of the account (userdata/<id>/config) stay behind
if os.path.isdir(OLD + '/userdata'):
    for acct in os.listdir(OLD + '/userdata'):
        for item in os.listdir(OLD + '/userdata/' + acct):
            if item == 'config' or not item.isdigit(): continue
            os.makedirs(ROOT + '/userdata/' + acct, exist_ok=True)
            os.rename(OLD + '/userdata/%s/%s' % (acct, item), ROOT + '/userdata/%s/%s' % (acct, item))
# Steam's own state outside its folder
os.makedirs(OLD + '/dot-steam', exist_ok=True)
for f in ('registry.vdf', 'steam.pid', 'steam.token', 'exportedsettings.json'):
    if os.path.exists(HOME + '/.steam/' + f): os.rename(HOME + '/.steam/' + f, OLD + '/dot-steam/' + f)
print('DONE: old folder kept as', OLD)
