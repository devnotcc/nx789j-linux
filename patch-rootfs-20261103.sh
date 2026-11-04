#!/bin/bash
# Apply the 2026-11-03 fixes to the built Debian image (out/linux/debian-plasma/rootfs.ext4,
# build-debian-plasma.sh of 2026-10-29) without rebuilding it. build-debian-plasma.sh carries
# the same changes for the next full build. Run in WSL as root. Writes a NEW image next to the
# old one (rootfs-20261103.ext4); the old image is not touched.
#  - nx-xwayland: Xwayland deadlocked on itself (Mesa device-select layer connecting to $DISPLAY)
#    -> black screen, every KDE service timed out
#  - nx-tune: create the device nodes devtmpfs misses under enforcing SELinux (one kernel)
#  - nx-orientation + layouts: auto-rotate (with nx-accel on the Android side) and a portrait /
#    landscape panel layout for the phone screen, with a panel button to lock the rotation
#  - config files copied from Windows were executable (systemd warned about every drop-in)
set -euo pipefail
O=/mnt/c/zte/backup/out/linux/debian-plasma
OV=/mnt/c/zte/backup/tools/linux/overlay
SRC=$O/rootfs.ext4; NEW=$O/rootfs-20261103.ext4
M=/mnt/nx-patch
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f $SRC ] || { echo "no $SRC"; exit 1; }
echo "== copy (sparse)"
cp --sparse=always $SRC $NEW
mkdir -p $M
mount -o loop $NEW $M
trap 'umount $M 2>/dev/null || true' EXIT

echo "== files"
inst() { # mode src dst
	install -D -m "$1" -o 0 -g 0 /dev/null "$M$3"
	tr -d '\r' < "$OV$2" > "$M$3"
	chmod "$1" "$M$3"
}
inst 755 /usr/local/sbin/nx-xwayland /usr/local/sbin/nx-xwayland
inst 755 /usr/local/sbin/nx-tune /usr/local/sbin/nx-tune
inst 755 /usr/local/bin/nx-orientation /usr/local/bin/nx-orientation
inst 644 /usr/local/share/nx789j/plasma-phone-layout.js /usr/local/share/nx789j/plasma-phone-layout.js
inst 644 /usr/local/share/nx789j/plasma-landscape-layout.js /usr/local/share/nx789j/plasma-landscape-layout.js
inst 644 /etc/systemd/user/nx-orientation.service /etc/systemd/user/nx-orientation.service
# panel button to turn auto-rotate on/off (Plasma widget) + its helper
inst 755 /usr/local/bin/nx-autorotate /usr/local/bin/nx-autorotate
W=/usr/share/plasma/plasmoids/org.nx789j.autorotate
inst 644 $W/metadata.json $W/metadata.json
inst 644 $W/contents/ui/main.qml $W/contents/ui/main.qml
# systemctl --global enable, by hand (same symlink it makes)
mkdir -p $M/etc/systemd/user/plasma-workspace.target.wants
ln -sfn /etc/systemd/user/nx-orientation.service $M/etc/systemd/user/plasma-workspace.target.wants/nx-orientation.service
echo "== permissions"
find $M/home/nx/.config $M/usr/local/share/nx789j -type f -exec chmod 644 {} +
find $M/etc/systemd/system $M/etc/systemd/user -type f -exec chmod 644 {} +

echo "== checks"
grep -q 'VK_LOADER_LAYERS_DISABLE=VK_LAYER_MESA_device_select' $M/usr/local/sbin/nx-xwayland
grep -q nx-mkdev $M/usr/local/sbin/nx-tune
[ -x $M/usr/local/sbin/nx-mkdev ]
grep -q org.nx789j.autorotate $M/usr/local/share/nx789j/plasma-phone-layout.js $M/usr/local/share/nx789j/plasma-landscape-layout.js
[ -x $M/usr/bin/kscreen-doctor ] && [ -x $M/usr/bin/qdbus6 ] && [ -x $M/usr/bin/python3 ]
for s in $M/usr/local/sbin/nx-xwayland $M/usr/local/sbin/nx-tune; do bash -n $s; done
python3 -m py_compile $M/usr/local/bin/nx-orientation && rm -rf $M/usr/local/bin/__pycache__
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
ls -la $M/usr/local/bin/nx-orientation $M/etc/systemd/user/plasma-workspace.target.wants/
umount $M; trap - EXIT
e2fsck -fn $NEW | tail -2
sha256sum $NEW
echo PATCH-OK
