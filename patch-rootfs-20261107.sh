#!/bin/bash
# 2026-11-07, on top of the 2026-11-06 image (no full rebuild):
#  - a plain reboot from Debian stays in Debian (nx-phone-power arms linux-once after a one-time
#    Linux boot; Restart into Android and crashes still go to Android)
#  - USB security keys / passkeys: nx-input-hotplug makes /dev/hidrawN for keys plugged in after
#    boot and runs udev over them (fido_id + uaccess give the desktop user access)
#  - auto-rotate is a tray applet now; auto-rotate, clipboard, volume and brightness sit in the
#    tray's "Status and Notifications" popup (plasma-tray.js, applied by nx-orientation)
#  - KDE Wallet off (/etc/xdg/kwalletrc): it asked for its password on every boot (the desktop
#    starts without a login password) and Wi-Fi passwords were asked again without it
# Run in WSL as root. Writes a NEW image on D:; the 11-06 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261106.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261107.ext4
OV=/mnt/c/zte/backup/tools/linux/overlay
M=/mnt/nx-patch
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f $SRC ] || { echo "no $SRC"; exit 1; }
mkdir -p $M
echo "== copy (sparse)"
cp --sparse=always $SRC $NEW
mount -o loop $NEW $M
trap 'umount $M 2>/dev/null || true' EXIT

echo "== files"
inst() { # mode path (same in the overlay and the image); text files: CRs stripped
	install -D -m "$1" -o 0 -g 0 /dev/null "$M$2"
	tr -d '\r' < "$OV$2" > "$M$2"
	chmod "$1" "$M$2"
}
inst 755 /usr/local/sbin/nx-phone-power
inst 755 /usr/local/sbin/nx-input-hotplug
inst 755 /usr/local/bin/nx-orientation
inst 644 /usr/local/share/nx789j/plasma-phone-layout.js
inst 644 /usr/local/share/nx789j/plasma-landscape-layout.js
inst 644 /usr/local/share/nx789j/plasma-tray.js
inst 644 /usr/share/plasma/plasmoids/org.nx789j.autorotate/metadata.json
inst 644 /usr/share/plasma/plasmoids/org.nx789j.autorotate/contents/ui/main.qml
inst 644 /etc/xdg/kwalletrc

echo "== checks"
sh -n $M/usr/local/sbin/nx-phone-power; sh -n $M/usr/local/sbin/nx-input-hotplug
python3 -m py_compile $M/usr/local/bin/nx-orientation && rm -rf $M/usr/local/bin/__pycache__
python3 -c "import json,sys; json.load(open(sys.argv[1]))" $M/usr/share/plasma/plasmoids/org.nx789j.autorotate/metadata.json
! grep -q org.nx789j.autorotate $M/usr/local/share/nx789j/plasma-*-layout.js
# udev rules the passkey support relies on
ls $M/usr/lib/udev/rules.d/60-fido-id.rules $M/usr/lib/udev/rules.d/70-uaccess.rules
for p in org.kde.plasma.clipboard org.kde.plasma.volume org.kde.plasma.brightness; do
	ls -d $M/usr/share/plasma/plasmoids/$p >/dev/null 2>&1 || ls $M/usr/lib/aarch64-linux-gnu/qt6/plugins/plasma/applets/$p.so >/dev/null || { echo "no $p"; exit 1; }
done
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
