#!/bin/bash
# 2026-11-12, on top of the 2026-11-11 image (no full rebuild):
#  - Keyboards, mice, gamepads plugged in for the FIRST time after Debian started work: Android's
#    SELinux keeps the kernel's devtmpfs from adding nodes after boot ("kdevtmpfs denied
#    { write }"), so they had no /dev/input/eventN (devices present at boot were fine, and a
#    replug reuses their number). nx-input-hotplug now makes missing input nodes (event, js,
#    mouse) before its udev pass. Reported on the GitHub issue; tested 2026-11-08 with a DS4
#    controller plugged in after boot (its touchpad moves the cursor).
# Run in WSL as root. Writes a NEW image on D:; the 11-11 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261111.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261112.ext4
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
install -D -m 755 -o 0 -g 0 /dev/null $M/usr/local/sbin/nx-input-hotplug
tr -d '\r' < $OV/usr/local/sbin/nx-input-hotplug > $M/usr/local/sbin/nx-input-hotplug

echo "== checks"
sh -n $M/usr/local/sbin/nx-input-hotplug
grep -q '^mknode()' $M/usr/local/sbin/nx-input-hotplug
grep -q 'snd-card' $M/usr/local/sbin/nx-input-hotplug
grep -q 'class Mic' $M/usr/local/sbin/nx-jack
# nothing private or phone-specific may be in the image
[ ! -e $M/var/lib/nx/audio-volumes.json ] || { echo "volume state in the image"; exit 1; }
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
! ls -d $M/var/lib/bluetooth/*:* >/dev/null 2>&1 || { echo "Bluetooth pairings in the image"; exit 1; }
[ ! -e $M/var/lib/nx/wifi-imported ] && [ ! -e $M/var/lib/nx/bt-imported ] || { echo "first-boot markers in the image"; exit 1; }
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
