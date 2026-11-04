#!/bin/bash
# 2026-11-04: add "Restart into Android" to the Debian image (app menu entry + nx-to-android,
# nx-phone-power reads the "android" reboot parameter) on top of the 2026-11-03 image, without rebuilding it. build-debian-plasma.sh picks the
# files up from the overlay on the next full build. Run in WSL as root. Writes a NEW image
# (on D:, C: is nearly full); the 11-03 image is not touched.
set -euo pipefail
SRC=/mnt/c/zte/backup/out/linux/debian-plasma/rootfs-20261103.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261104.ext4
OV=/mnt/c/zte/backup/tools/linux/overlay
M=/mnt/nx-patch
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f $SRC ] || { echo "no $SRC"; exit 1; }
mkdir -p "$(dirname $NEW)" $M
echo "== copy (sparse)"
cp --sparse=always $SRC $NEW
mount -o loop $NEW $M
trap 'umount $M 2>/dev/null || true' EXIT

echo "== files"
inst() { # mode path (same in the overlay and the image)
	install -D -m "$1" -o 0 -g 0 /dev/null "$M$2"
	tr -d '\r' < "$OV$2" > "$M$2"
	chmod "$1" "$M$2"
}
inst 755 /usr/local/bin/nx-to-android
inst 644 /usr/share/applications/nx-to-android.desktop
inst 755 /usr/local/sbin/nx-phone-power

echo "== checks"
python3 -m py_compile $M/usr/local/bin/nx-to-android && rm -rf $M/usr/local/bin/__pycache__
sh -n $M/usr/local/sbin/nx-phone-power
grep -q reboot-param $M/usr/local/sbin/nx-phone-power
grep -q '^Exec=/usr/local/bin/nx-to-android$' $M/usr/share/applications/nx-to-android.desktop
# what the scripts rely on: python3 + Gio introspection, systemctl, logind reboot parameter
[ -x $M/usr/bin/python3 ] && [ -d $M/usr/lib/python3/dist-packages/gi ] && [ -x $M/usr/bin/systemctl ]
ls $M/usr/lib/aarch64-linux-gnu/girepository-1.0/Gio-2.0.typelib >/dev/null
grep -q set-reboot-parameter $M/usr/share/polkit-1/actions/org.freedesktop.login1.policy
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
ls -la $M/usr/local/bin/nx-to-android $M/usr/share/applications/nx-to-android.desktop
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
