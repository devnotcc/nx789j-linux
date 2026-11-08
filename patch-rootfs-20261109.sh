#!/bin/bash
# 2026-11-09, on top of the 2026-11-08 image (no full rebuild):
#  - Bluetooth pairings from Android: nx-bt-import is switched on (runs before bluetoothd). The
#    key is byte-reversed (Android's bt_config order vs the controller's, checked on an HCI log),
#    and the newer pairing wins (Android's key is taken when it changed since the last import).
#    Tested: LinkBuds S paired in Android connect in Debian without pairing, and keep working in
#    Android afterwards.
# Run in WSL as root. Writes a NEW image on D:; the 11-08 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261108.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261109.ext4
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
install -D -m 755 -o 0 -g 0 /dev/null $M/usr/local/sbin/nx-bt-import
tr -d '\r' < $OV/usr/local/sbin/nx-bt-import > $M/usr/local/sbin/nx-bt-import
install -D -m 644 -o 0 -g 0 /dev/null $M/etc/systemd/system/nx-bt-import.service
tr -d '\r' < $OV/etc/systemd/system/nx-bt-import.service > $M/etc/systemd/system/nx-bt-import.service
mkdir -p $M/etc/systemd/system/bluetooth.service.wants
ln -sf /etc/systemd/system/nx-bt-import.service $M/etc/systemd/system/bluetooth.service.wants/nx-bt-import.service

echo "== checks"
python3 -m py_compile $M/usr/local/sbin/nx-bt-import && rm -rf $M/usr/local/sbin/__pycache__
grep -q 'def bluez_key' $M/usr/local/sbin/nx-bt-import
[ "$(readlink $M/etc/systemd/system/bluetooth.service.wants/nx-bt-import.service)" = /etc/systemd/system/nx-bt-import.service ]
ls $M/usr/local/lib/modules/hci_vhci.ko $M/etc/systemd/system/multi-user.target.wants/nx-bluetooth.service
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
! ls -d $M/var/lib/bluetooth/*:* >/dev/null 2>&1 || { echo "Bluetooth pairings in the image"; exit 1; }
[ ! -e $M/var/lib/nx/wifi-imported ] && [ ! -e $M/var/lib/nx/bt-imported ] || { echo "first-boot markers in the image"; exit 1; }
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
