#!/bin/bash
# 2026-11-11, on top of the 2026-11-10 image (no full rebuild):
#  - The phone's 3.5 mm headphone jack: nx-jack follows the jack switch, sets the codec's
#    headphone path and tells the Android-side player (nx-linux.sh _audio, launcher) to use the
#    headphone backend; nx-audio-feed ends the stream on a route change (and waits 1.2 s so the
#    old player is gone). Speaker and headphones keep separate volumes (headphones start at 30%).
#  - Microphones: "Phone microphone" (51-nx-mic.conf, a PipeWire pipe source). Only while it is
#    in use, nx-jack sets the codec's mic path (headset mic while the jack reports one, otherwise
#    the built-in mic) and nx-linux.sh _mic (launcher) runs the vendor capture tool.
#    Tested 2026-11-08: headphones in/out while playing, separate volumes, headset mic recording.
# Run in WSL as root. Writes a NEW image on D:; the 11-10 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261110.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261111.ext4
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
put() { install -D -m $1 -o 0 -g 0 /dev/null $M/$2; tr -d '\r' < $OV/$2 > $M/$2; }
put 755 usr/local/sbin/nx-jack
put 755 usr/local/sbin/nx-audio-feed
put 644 etc/systemd/system/nx-jack.service
put 644 etc/pipewire/pipewire.conf.d/51-nx-mic.conf
ln -sf /etc/systemd/system/nx-jack.service $M/etc/systemd/system/multi-user.target.wants/nx-jack.service

echo "== checks"
python3 -m py_compile $M/usr/local/sbin/nx-jack $M/usr/local/sbin/nx-audio-feed && rm -rf $M/usr/local/sbin/__pycache__
grep -q 'class Mic' $M/usr/local/sbin/nx-jack
grep -q 'HOLD = ' $M/usr/local/sbin/nx-audio-feed
grep -q 'tunnel.mode = source' $M/etc/pipewire/pipewire.conf.d/51-nx-mic.conf
[ "$(readlink $M/etc/systemd/system/multi-user.target.wants/nx-jack.service)" = /etc/systemd/system/nx-jack.service ]
grep -q 'snd-card' $M/usr/local/sbin/nx-input-hotplug
# nothing private or phone-specific may be in the image
[ ! -e $M/var/lib/nx/audio-volumes.json ] || { echo "volume state in the image"; exit 1; }
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
! ls -d $M/var/lib/bluetooth/*:* >/dev/null 2>&1 || { echo "Bluetooth pairings in the image"; exit 1; }
[ ! -e $M/var/lib/nx/wifi-imported ] && [ ! -e $M/var/lib/nx/bt-imported ] || { echo "first-boot markers in the image"; exit 1; }
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
