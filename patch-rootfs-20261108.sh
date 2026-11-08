#!/bin/bash
# 2026-11-08, on top of the 2026-11-07 image (no full rebuild):
#  - Bluetooth: hci_vhci.ko (built for the EvoX/LineageOS 6.6.92 kernel by tools/gki/build-hci-vhci.sh)
#    in /usr/local/lib/modules; nx-bluetooth.service loads it and makes /dev/vhci
#  - nx-bt-import (copies Android's pairings into BlueZ, never over a pairing made in Debian) is
#    shipped but NOT enabled: the imported keys fail authentication so far (devices would show as
#    paired and then not connect); devices are paired in Debian instead
#  - Bluetooth headphones become the default output (the speaker sink's priority was above BlueZ's)
#  - minimised windows no longer stay on screen (nx_pixelshift kept animating them)
#  - nx-firstboot: Android's saved Wi-Fi networks are imported once on a fresh install
#  - display scale 2 instead of 2.5 on the phone screen (new installs: kwinoutputconfig.json)
# Run in WSL as root. Writes a NEW image on D:; the 11-07 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261107.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261108.ext4
OV=/mnt/c/zte/backup/tools/linux/overlay
PUB=/mnt/c/zte/backup/tools/linux/public/overlay
KO=/mnt/c/zte/backup/out/gki-linux/modules-evox/hci_vhci.ko
M=/mnt/nx-patch
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f $SRC ] && [ -f $KO ] || { echo "no $SRC or $KO"; exit 1; }
mkdir -p $M
echo "== copy (sparse)"
cp --sparse=always $SRC $NEW
mount -o loop $NEW $M
trap 'umount $M 2>/dev/null || true' EXIT

echo "== files"
inst() { # mode path [source root]; text files: CRs stripped
	local src=${3:-$OV}
	install -D -m "$1" -o 0 -g 0 /dev/null "$M$2"
	tr -d '\r' < "$src$2" > "$M$2"
	chmod "$1" "$M$2"
}
inst 644 /etc/systemd/system/nx-bluetooth.service
inst 644 /etc/systemd/system/nx-bt-import.service
inst 755 /usr/local/sbin/nx-bt-import
inst 644 /etc/systemd/system/nx-bluetooth.service.d/20-public.conf $PUB
inst 644 /etc/pipewire/pipewire.conf.d/50-nx-speaker.conf
inst 644 /usr/local/share/nx789j/plasma-phone-layout.js
inst 644 /usr/local/share/nx789j/plasma-landscape-layout.js
inst 755 /usr/local/sbin/nx-firstboot $PUB
install -D -m 644 -o 0 -g 0 $KO $M/usr/local/lib/modules/hci_vhci.ko
rm -f $M/etc/systemd/system/bluetooth.service.wants/nx-bt-import.service
# the desktop user's files keep the user's owner
NXU=$(stat -c %u $M/home/nx); NXG=$(stat -c %g $M/home/nx)
for f in .local/share/kwin/effects/nx_pixelshift/contents/code/main.js:$OV .config/kwinoutputconfig.json:$PUB; do
	p=${f%%:*}; s=${f#*:}
	install -D -m 644 -o $NXU -g $NXG /dev/null "$M/home/nx/$p"
	tr -d '\r' < "$s/home/nx/$p" > "$M/home/nx/$p"
done

echo "== checks"
python3 -m py_compile $M/usr/local/sbin/nx-bt-import && rm -rf $M/usr/local/sbin/__pycache__
sh -n $M/usr/local/sbin/nx-firstboot; grep -q wifi-imported $M/usr/local/sbin/nx-firstboot
grep -q 'insmod /usr/local/lib/modules/hci_vhci.ko' $M/etc/systemd/system/nx-bluetooth.service
modinfo -F vermagic $M/usr/local/lib/modules/hci_vhci.ko | grep -q '^6.6.92-4k-g7548e17901c5 '
ls $M/usr/local/sbin/bluebinder $M/etc/systemd/system/multi-user.target.wants/nx-bluetooth.service
grep -q 'priority.session = 600' $M/etc/pipewire/pipewire.conf.d/50-nx-speaker.conf
grep -q 'w.minimized' $M/home/nx/.local/share/kwin/effects/nx_pixelshift/contents/code/main.js
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); s=[o['scale'] for g in d if g['name']=='outputs' for o in g['data'] if o['connectorName']=='DSI-1']; assert s==[2], s" $M/home/nx/.config/kwinoutputconfig.json
! grep -q KWIN_DRM_NO_DIRECT_SCANOUT $M/etc/systemd/system/nx-plasma.service
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
! ls -d $M/var/lib/bluetooth/*:* >/dev/null 2>&1 || { echo "Bluetooth pairings in the image"; exit 1; }
[ ! -e $M/var/lib/nx/wifi-imported ] && [ ! -e $M/var/lib/nx/bt-imported ] || { echo "first-boot markers in the image"; exit 1; }
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
