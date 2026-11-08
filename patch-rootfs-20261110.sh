#!/bin/bash
# 2026-11-10, on top of the 2026-11-09 image (no full rebuild):
#  - USB audio devices (DACs, USB-C headsets, a DS4 controller's headphone jack) work, also when
#    plugged in after Debian started: nx-input-hotplug makes their /dev/snd nodes (Android's
#    SELinux keeps the kernel from adding them after boot), runs a udev pass so PipeWire takes
#    the card, and restarts WirePlumber when a card is unplugged (it otherwise kept the dead card
#    as the default output at 90% CPU). USB cards only; the phone's own card stays Android's.
#  - The matching Android-side change is in the launcher, not the image: nx-systemd.sh unloads
#    snd_usb_audio_qmi (Qualcomm USB audio offload) before Linux starts; with it loaded, a USB
#    card used by PipeWire panicked the kernel (arm-smmu fault from the USB controller).
#    Tested 2026-11-08 with a DS4 controller: playback, YouTube, unplug, replug.
# Run in WSL as root. Writes a NEW image on D:; the 11-09 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261109.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261110.ext4
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
grep -q 'snd-card' $M/usr/local/sbin/nx-input-hotplug
grep -q 'restart wireplumber' $M/usr/local/sbin/nx-input-hotplug
[ "$(readlink $M/etc/systemd/system/multi-user.target.wants/nx-input-hotplug.service)" = /etc/systemd/system/nx-input-hotplug.service ]
ls $M/usr/local/lib/modules/hci_vhci.ko $M/usr/local/sbin/nx-bt-import
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
! ls -d $M/var/lib/bluetooth/*:* >/dev/null 2>&1 || { echo "Bluetooth pairings in the image"; exit 1; }
[ ! -e $M/var/lib/nx/wifi-imported ] && [ ! -e $M/var/lib/nx/bt-imported ] || { echo "first-boot markers in the image"; exit 1; }
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
