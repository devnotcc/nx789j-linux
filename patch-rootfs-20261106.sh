#!/bin/bash
# 2026-11-06: mobile data on Linux boots, on top of the 2026-11-04 image (no full rebuild).
#  - nx-mobiledata (+ nx-radio.dex/.sh: NxRadio, a client of Android's radio HALs, source
#    tools/linux/mobiledata) and nx-mobiledata.service, enabled
#  - nx-mobiledata-on/-off/-slot@/-unlock@.service + polkit rule: the desktop user switches data
#    and the data SIM and enters a SIM PIN (never stored) without a password
#  - nx-resolv (+ .path/.service): /etc/resolv.conf = NetworkManager's servers + carrier DNS;
#    NetworkManager rc-manager=unmanaged
#  - "Mobile Data" tray applet (org.nx789j.mobiledata, EnabledByDefault -> shown in the tray)
#  - nx-tray-add helper
# Run in WSL as root. Writes a NEW image on D:; the 11-04 image is not touched.
set -euo pipefail
SRC=/mnt/d/nx789j-build/debian-plasma/rootfs-20261104.ext4
NEW=/mnt/d/nx789j-build/debian-plasma/rootfs-20261106.ext4
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
inst 755 /usr/local/sbin/nx-mobiledata
inst 755 /usr/local/sbin/nx-resolv
inst 755 /usr/local/sbin/nx-tray-add
inst 644 /usr/local/lib/nx-mobiledata/nx-radio.sh
install -D -m 644 -o 0 -g 0 $OV/usr/local/lib/nx-mobiledata/nx-radio.dex $M/usr/local/lib/nx-mobiledata/nx-radio.dex
inst 644 /etc/nx-mobiledata.conf
for u in nx-mobiledata.service nx-mobiledata-on.service nx-mobiledata-off.service nx-mobiledata-slot@.service nx-mobiledata-unlock@.service nx-resolv.service nx-resolv.path; do
	inst 644 /etc/systemd/system/$u
done
inst 644 /etc/polkit-1/rules.d/50-nx-mobiledata.rules
inst 644 /etc/NetworkManager/conf.d/10-nx789j.conf
inst 644 /usr/share/plasma/plasmoids/org.nx789j.mobiledata/metadata.json
inst 644 /usr/share/plasma/plasmoids/org.nx789j.mobiledata/contents/ui/main.qml

echo "== enable units (what systemctl enable would link)"
W=$M/etc/systemd/system/multi-user.target.wants
mkdir -p $W
for u in nx-mobiledata.service nx-resolv.service nx-resolv.path; do ln -sfn /etc/systemd/system/$u $W/$u; done

echo "== resolv.conf -> nx-resolv's file"
rm -f $M/etc/resolv.conf; ln -s /run/nx/resolv.conf $M/etc/resolv.conf

# an existing tray config (not in a fresh image) gets the applet through knownItems/EnabledByDefault
for f in $M/home/*/.config/plasma-org.kde.plasma.desktop-appletsrc; do
	[ -f "$f" ] || continue
	grep -q org.nx789j.mobiledata "$f" || sed -i -E "s/^(extraItems=.+)$/\1,org.nx789j.mobiledata/; s/^(knownItems=.+)$/\1,org.nx789j.mobiledata/" "$f"
	echo "tray: $f"
done

echo "== checks"
python3 -m py_compile $M/usr/local/sbin/nx-mobiledata && rm -rf $M/usr/local/sbin/__pycache__
sh -n $M/usr/local/sbin/nx-resolv; sh -n $M/usr/local/sbin/nx-tray-add; sh -n $M/usr/local/lib/nx-mobiledata/nx-radio.sh
python3 -c "import json,sys; json.load(open(sys.argv[1]))" $M/usr/share/plasma/plasmoids/org.nx789j.mobiledata/metadata.json
unzip -l $M/usr/local/lib/nx-mobiledata/nx-radio.dex >/dev/null 2>&1 || head -c 4 $M/usr/local/lib/nx-mobiledata/nx-radio.dex | grep -q dex
grep -q '^rc-manager=unmanaged' $M/etc/NetworkManager/conf.d/10-nx789j.conf
# what the scripts rely on in the image
for b in python3 ip nmcli chroot systemctl runuser; do chroot $M /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin which $b >/dev/null || { echo "missing $b"; exit 1; }; done
ls $M/usr/lib/aarch64-linux-gnu/qt6/qml/org/kde/plasma/plasma5support >/dev/null
[ -d $M/usr/share/polkit-1 ] && [ -x $M/usr/lib/polkit-1/polkitd ]
# nothing private may be in the image
[ ! -s $M/etc/shadow ] || ! grep -q '^nx:\$' $M/etc/shadow || { echo "nx has a password in the image"; exit 1; }
! ls $M/etc/NetworkManager/system-connections/* >/dev/null 2>&1 || { echo "Wi-Fi profiles in the image"; exit 1; }
[ ! -e $M/run/nx/mobile-dns ]
ls -la $W/nx-mobiledata.service $M/etc/resolv.conf
umount $M; trap - EXIT
sha256sum $NEW
echo "### PATCH OK"
