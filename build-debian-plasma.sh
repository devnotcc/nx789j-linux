#!/bin/bash
# Build the PUBLIC "Debian 13 + KDE Plasma" image for the NX789J installer (Linux userspace on
# the Android kernel, kernel 2: systemd in its own namespaces, see phone/nx-systemd.sh).
# Runs in WSL as root; arm64 programs run through qemu-user. Nothing here touches the phone.
# Output in $OUT (and copied to $PUB):
#   rootfs.ext4      4 KiB blocks, label nxroot, a little free space (the installer makes the
#                    file bigger on the phone; nx-firstboot grows the filesystem to match)
#   packages.txt     installed packages
#   SHA256SUMS
#   android/         the Android-side launcher files the installer uploads next to the image
# Differences from the phone setup of 2026-10-16 (build-rootfs.sh + overlay/): clean Plasma
# desktop only (no Steam/Proton/FEX/games/VMs, see public/exclude.txt), no SSH keys, sshd
# disabled, no Wi-Fi config, user nx locked until the installer's password arrives
# (nx-firstboot), sudo with a password, no lock-screen auto-unlock, no kernel modules/firmware.
set -euo pipefail
SUITE=trixie
MIRROR=http://deb.debian.org/debian
OUT=${OUT:-/root/nx-debian-plasma}
PUB=${PUB:-/mnt/c/zte/backup/out/linux/debian-plasma}
T=/mnt/c/zte/backup/tools/linux
OVERLAY=$T/overlay
PUBLIC=$T/public
BIN=/mnt/c/zte/backup/out/linux/phone-state-20261016/binaries.tar.gz
SLACK_MB=${SLACK_MB:-1024}
R=$OUT/rootfs
mkdir -p "$OUT"; cd "$OUT"
die() { echo "BUILD-FAILED: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
need=""; for p in mmdebstrap qemu-user-static binfmt-support e2fsprogs arch-test rsync xz-utils; do dpkg -s $p >/dev/null 2>&1 || need="$need $p"; done
[ -z "$need" ] || { apt-get update -q; apt-get install -y -q $need; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || update-binfmts --enable qemu-aarch64 || true

# Ubuntu's debian-archive-keyring predates the trixie keys: take the current one from Debian
if [ ! -s keyring/usr/share/keyrings/debian-archive-keyring.gpg ] && [ ! -s keyring/usr/share/keyrings/debian-archive-keyring.pgp ]; then
	deb=$(curl -fsSL $MIRROR/pool/main/d/debian-archive-keyring/ | grep -o 'debian-archive-keyring_[0-9.]*_all\.deb' | sort -V | tail -1)
	curl -fsSL -o keyring.deb "$MIRROR/pool/main/d/debian-archive-keyring/$deb"
	rm -rf keyring; dpkg-deb -x keyring.deb keyring; echo "keyring: $deb"
fi
KR=$OUT/$(cd $OUT && ls keyring/usr/share/keyrings/debian-archive-keyring.{gpg,pgp} 2>/dev/null | head -1 || true)

# ---- packages -------------------------------------------------------------------------------
# base system, installed without Recommends
BASE=systemd,systemd-sysv,dbus,dbus-user-session,udev,kmod,iproute2,iputils-ping,ca-certificates,curl,wget
BASE=$BASE,sudo,locales,less,nano,vim-tiny,htop,procps,psmisc,file,usbutils,pciutils,rsync,zstd,xz-utils,unzip
BASE=$BASE,e2fsprogs,util-linux,mount,fdisk,libcap2-bin,python3,iw,rfkill,openssh-server,bash-completion,man-db
# the desktop, installed WITH Recommends (that is what makes Plasma feel complete), minus BLOCK
DESK="plasma-desktop plasma-workspace kwin-wayland systemsettings kscreen libkscreen-bin powerdevil plasma-nm plasma-pa
 bluedevil bluez breeze breeze-gtk-theme kde-config-gtk-style xdg-desktop-portal-kde plasma-integration kio-extras
 kde-cli-tools qt6-wayland polkit-kde-agent-1 kinfocenter ksystemstats qdbus-qt6 maliit-keyboard maliit-framework
 dolphin konsole kate ark gwenview okular kcalc kde-spectacle plasma-systemmonitor xwayland firefox-esr
 network-manager pipewire pipewire-pulse wireplumber pipewire-alsa pulseaudio-utils libspa-0.2-bluetooth
 fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji libnotify-bin wmctrl xdotool
 libpcsclite1 libnl-3-200 libnl-genl-3-200 libnl-route-3-200 libglib2.0-0t64"
# never: a display manager (the session is nx-plasma.service), the software centre, firmware and
# kernels (Android's side loads drivers and firmware), mobile shells, indexers, and ModemManager
# (the modem belongs to Android's radio stack)
BLOCK="sddm sddm-theme-* plasma-discover* packagekit* apper firmware-* linux-image-* wireless-regdb
 plasma-mobile* plasma-welcome kdeconnect akonadi-server* baloo-kf5 tracker* gnome-software
 unattended-upgrades xserver-xorg-core xserver-xorg alsa-topology-conf
 modemmanager smartmontools"

rm -rf "$R"; mkdir "$R"
mmdebstrap --keyring="$KR" --arch=arm64 --variant=minbase --components=main,contrib,non-free-firmware \
	--aptopt='APT::Install-Recommends "false"' --include="$BASE" \
	--customize-hook='echo nx789j > "$1/etc/hostname"' \
	--customize-hook='printf "127.0.0.1 localhost\n127.0.1.1 nx789j\n::1 localhost ip6-localhost ip6-loopback\n" > "$1/etc/hosts"' \
	$SUITE "$R" $MIRROR

# sources: trixie + updates + security, and backports for libgbinder only
rm -f "$R/etc/apt/sources.list"
KRING=$(cd "$R" && ls usr/share/keyrings/debian-archive-keyring.pgp usr/share/keyrings/debian-archive-keyring.gpg 2>/dev/null | head -1 || true); KRING=/$KRING; [ "$KRING" != / ] || die "no archive keyring in the rootfs"
cat > "$R/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main contrib non-free-firmware
Signed-By: $KRING

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $SUITE-security
Components: main contrib non-free-firmware
Signed-By: $KRING
EOF
{
	for p in $BLOCK; do printf 'Package: %s\nPin: version *\nPin-Priority: -1\n\n' "$p"; done
} > "$R/etc/apt/preferences.d/90-nx-public"
printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\n' > "$R/etc/apt/apt.conf.d/90-nx-norecommends"

mounted=""
chroot_up() {
	mount -t proc proc "$R/proc"; mount -t sysfs sysfs "$R/sys"
	mount --bind /dev "$R/dev"; mount --bind /dev/pts "$R/dev/pts"
	cp /etc/resolv.conf "$R/etc/resolv.conf.nx-build" 2>/dev/null || true
	[ -e "$R/etc/resolv.conf" ] || cp /etc/resolv.conf "$R/etc/resolv.conf"
	mounted=1
}
chroot_down() {
	[ -n "$mounted" ] || return 0
	for d in dev/pts dev sys proc; do umount -l "$R/$d" 2>/dev/null || true; done
	mounted=""
}
trap chroot_down EXIT
ch() { chroot "$R" /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"; }

chroot_up
# no service may start inside the build
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 755 "$R/usr/sbin/policy-rc.d"
ch apt-get update -q
ch apt-get -y -q dist-upgrade
ch apt-get install -y -q -o APT::Install-Recommends=true $DESK
ch apt-get install -y -q -t $SUITE-backports libgbinder1
ch apt-get -y -q autoremove --purge
rm -f "$R/usr/sbin/policy-rc.d"
for p in sddm plasma-discover packagekit; do ch dpkg -s $p >/dev/null 2>&1 && die "$p got installed"; done

# ---- account --------------------------------------------------------------------------------
groups=sudo
for g in video input audio render netdev bluetooth plugdev users; do ch getent group $g >/dev/null && groups=$groups,$g; done
ch useradd -m -u 1000 -U -G "$groups" -s /bin/bash -c "NX789J" nx
ch passwd -l nx >/dev/null
ch passwd -l root >/dev/null
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' "$R/etc/locale.gen"; ch locale-gen >/dev/null

# ---- overlay: the phone's integration files, minus the private and gaming parts -------------
rsync -rlt --exclude-from="$PUBLIC/exclude.txt" "$OVERLAY"/ "$R"/
rsync -rlt "$PUBLIC/overlay"/ "$R"/
# Windows-side files: no CRLF may survive into scripts or units
crlf=$(cd "$R" && grep -rlI $'\r' usr/local etc/systemd etc/NetworkManager etc/pipewire etc/environment.d home/nx 2>/dev/null || true)
[ -z "$crlf" ] || die "CRLF line ends in: $crlf"
chown -R 0:0 "$R/usr/local" "$R/etc/systemd" "$R/etc/NetworkManager" "$R/etc/pipewire"
chmod 755 "$R"/usr/local/sbin/* "$R"/usr/local/bin/* "$R/usr/lib/systemd/system-shutdown/nx-power"
find "$R/etc/systemd/system" "$R/etc/systemd/user" -type f -exec chmod 644 {} +
# config files copied from Windows arrive executable (systemd warns about every unit drop-in)
find "$R/home/nx/.config" "$R/usr/local/share/nx789j" -type f -exec chmod 644 {} +
# auto-rotate + portrait/landscape panel layout in every Plasma session (also lays the panels
# out on the first login)
ch systemctl --global enable nx-orientation.service >/dev/null
chmod 600 "$R/etc/NetworkManager/conf.d/10-nx789j.conf" 2>/dev/null || true
# KWin effect from the overlay (pixel shift against OLED burn-in) on by default
printf '\n[Plugins]\nnx_pixelshiftEnabled=true\n' >> "$R/home/nx/.config/kwinrc"
ch chown -R nx:nx /home/nx

# public patches, each checked
P="$R/etc/systemd/system/nx-plasma.service"
sed -i '/the nx account has no password to unlock with/d; /remove this line after setting a password/d; s/loginctl unlock-sessions; //' "$P"
grep -q unlock-sessions "$P" && die "nx-plasma.service still unlocks the session"
P="$R/usr/local/bin/nx-display"
sed -i '/Steam does not follow a change of the display scale/d; /nx-steam-rescale/d' "$P"
grep -q steam "$P" && die "nx-display still calls a Steam helper"
P="$R/usr/local/sbin/nx-systemd-prep"
sed -i 's/ nx-desktop\.service//; s/ ssh\.service//' "$P"
grep -q 'enable.*nx-desktop\|enable.*ssh\.service' "$P" && die "nx-systemd-prep still enables nx-desktop/ssh"

# ---- binaries built for the phone (Mesa, patched wpa_supplicant, bluebinder, sysvsem shim) ---
X=$OUT/bin; rm -rf "$X"; mkdir -p "$X"
tar -xzf "$BIN" -C "$X" opt/nx-mesa usr/local/sbin/wpa_supplicant usr/local/sbin/bluebinder usr/local/lib/libnx-sysvsem.so
rm -f "$X"/opt/nx-mesa/lib/*.prev*
rm -rf "$R/opt/nx-mesa"; mkdir -p "$R/opt" "$R/usr/local/lib"
cp -a "$X/opt/nx-mesa" "$R/opt/"
install -m 755 "$X/usr/local/sbin/wpa_supplicant" "$X/usr/local/sbin/bluebinder" "$R/usr/local/sbin/"
install -m 644 "$X/usr/local/lib/libnx-sysvsem.so" "$R/usr/local/lib/"
chown -R 0:0 "$R/opt/nx-mesa"
ch ldconfig
# NetworkManager's wpa_supplicant = the patched build (WPA3 with this Wi-Fi driver)
x=$(grep -m1 '^ExecStart=' "$R/usr/lib/systemd/system/wpa_supplicant.service" | sed 's#^ExecStart=[^ ]*wpa_supplicant#ExecStart=/usr/local/sbin/wpa_supplicant#')
[ -n "$x" ] || die "no ExecStart in wpa_supplicant.service"
mkdir -p "$R/etc/systemd/system/wpa_supplicant.service.d"
printf '# patched build: Debian 2.10 rejects qca_cld3'"'"'s AKM in EXTERNAL_AUTH (WPA3), tools/linux/build-wpa.sh\n[Service]\nExecStart=\n%s\n' "$x" \
	> "$R/etc/systemd/system/wpa_supplicant.service.d/20-nx-wpa3.conf"
# Xwayland with GLES glamor (GPU for X11 programs), see nx-xwayland
ch dpkg-divert --local --rename --divert /usr/bin/Xwayland.real --add /usr/bin/Xwayland >/dev/null
ln -sf /usr/local/sbin/nx-xwayland "$R/usr/bin/Xwayland"

# every shipped binary must find all its libraries and symbols in this rootfs
bad=0
while read -r f; do
	o=$(ch env LD_LIBRARY_PATH=/opt/nx-mesa/lib ldd -r "$f" 2>&1 || true)
	if echo "$o" | grep -qE 'not found|undefined symbol'; then echo "ldd: $f"; echo "$o" | grep -E 'not found|undefined symbol' | head -5; bad=1; fi
done < <(cd "$R" && { find opt/nx-mesa -type f \( -name '*.so*' -o -path '*/bin/*' \); echo usr/local/sbin/wpa_supplicant; echo usr/local/sbin/bluebinder; echo usr/local/lib/libnx-sysvsem.so; } | sed 's#^#/#' | while read -r f; do file -b "$R$f" | grep -q '^ELF' && echo "$f"; done)
[ $bad = 0 ] || die "missing libraries or symbols (above)"
echo "ldd: all shipped binaries resolve"

# commands the overlay scripts and units call
miss=""
for c in kscreen-doctor qdbus6 setcap getcap chrt pgrep iw ip rfkill losetup resize2fs dumpe2fs blockdev chpasswd python3 \
	startplasma-wayland kwin_wayland plasmashell pipewire wireplumber pipewire-pulse pacat NetworkManager nmcli bluetoothd \
	Xwayland.real firefox-esr dolphin konsole systemd-run udevadm notify-send wmctrl xdotool ssh-keygen mountpoint; do
	ch sh -c "command -v $c" >/dev/null || miss="$miss $c"
done
for f in /usr/lib/systemd/systemd-udevd /usr/lib/aarch64-linux-gnu/libexec/plasma-dbus-run-session-if-needed \
	/usr/share/applications/com.github.maliit.keyboard.desktop; do [ -e "$R$f" ] || miss="$miss $f"; done
[ -z "$miss" ] || die "missing commands/files:$miss"
for s in "$R"/usr/local/sbin/* "$R"/usr/local/bin/*; do
	case "$(head -n 1 "$s" | tr -d "\000")" in '#!/bin/sh'* | '#!/bin/bash'*) bash -n "$s" || die "syntax: $s" ;; esac
done

# ---- services -------------------------------------------------------------------------------
ch /usr/local/sbin/nx-systemd-prep
ch systemctl enable nx-firstboot.service nx-plasma.service nx-tune.service nx-fan.service nx-wifi.service \
	nx-audio-feed.service nx-charge.service nx-autosleep.service nx-input-hotplug.service nx-phone-power.service \
	nx-bluetooth.service nx-bootok.timer NetworkManager.service bluetooth.service >/dev/null
ch systemctl disable ssh.service >/dev/null 2>&1 || true
ch systemctl disable ssh.socket >/dev/null 2>&1 || true
# the phone suspends through nx-autosleep; logind/Plasma must not try their own
ch systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target >/dev/null
mkdir -p "$R/var/log/journal"
cat > "$R/etc/fstab" <<'EOF'
# <device>  <mount>  <type>  <options>  <dump> <pass>
# / is the image itself, mounted by the Android side; nx-systemd.sh mounts /proc /sys /dev /run /tmp
EOF

# ---- make it generic ------------------------------------------------------------------------
ch apt-get clean
rm -rf "$R"/var/lib/apt/lists/* "$R"/var/cache/apt/*.bin "$R"/tmp/* "$R"/var/tmp/* "$R"/root/.bash_history
rm -f "$R"/etc/ssh/ssh_host_* "$R/etc/resolv.conf.nx-build"
find "$R/var/log" -type f -delete
: > "$R/etc/machine-id"; rm -f "$R/var/lib/dbus/machine-id"; ln -s /etc/machine-id "$R/var/lib/dbus/machine-id"
# resolv.conf: NetworkManager writes it
rm -f "$R/etc/resolv.conf"; ln -s /run/NetworkManager/resolv.conf "$R/etc/resolv.conf"
chroot_down

# ---- public-safety checks (any hit fails the build) -----------------------------------------
fail=""
[ -n "$(find "$R/root" "$R/home" -name authorized_keys 2>/dev/null)" ] && fail="$fail authorized_keys"
ls "$R"/etc/ssh/ssh_host_* >/dev/null 2>&1 && fail="$fail ssh-host-keys"
[ -e "$R/etc/systemd/system/multi-user.target.wants/ssh.service" ] && fail="$fail sshd-enabled"
[ -e "$R/etc/systemd/system/sockets.target.wants/ssh.socket" ] && fail="$fail ssh-socket-enabled"
grep -rqs NOPASSWD "$R/etc/sudoers" "$R/etc/sudoers.d" && fail="$fail NOPASSWD"
grep -q '^nx:!' "$R/etc/shadow" || fail="$fail nx-not-locked"
grep -q '^root:[!*]' "$R/etc/shadow" || fail="$fail root-not-locked"
grep -rqs unlock-sessions "$R/etc/systemd" "$R/usr/local" && fail="$fail unlock-sessions"
[ -e "$R/usr/local/sbin/nx-autounlock" ] && fail="$fail nx-autounlock"
[ -n "$(ls -A "$R/etc/NetworkManager/system-connections" 2>/dev/null)" ] && fail="$fail nm-profiles"
ls "$R"/etc/wpa_supplicant/*.conf >/dev/null 2>&1 && fail="$fail wpa-config"
[ -n "$(find "$R/usr/lib/modules" "$R/lib/modules" -name '*.ko*' 2>/dev/null)" ] && fail="$fail kernel-modules"
[ -n "$(find "$R/usr/lib/firmware" -type f 2>/dev/null | head -1)" ] && fail="$fail firmware"
[ -e "$R/usr/sbin/ModemManager" ] && fail="$fail ModemManager"
for n in 'nx-steam*' 'nx-proton*' 'nx-gamepad*' nx-stretch nx-xfocus 'nx-vm*' nx-w7vm.service 'nx-cage*' 'qemu-vmvga' nx-gamemode MangoHud 'nx-windows*.desktop' nx-steam.desktop; do
	[ -n "$(find "$R" -xdev -name "$n" 2>/dev/null | head -1)" ] && fail="$fail $n"
done
[ -z "$fail" ] || die "public-safety check:$fail"
echo "public-safety checks passed"

# ---- outputs --------------------------------------------------------------------------------
chroot "$R" dpkg-query -W -f '${Package} ${Version}\n' > packages.txt
used_kb=$(du -sk --apparent-size "$R" | cut -f1)
files=$(find "$R" -xdev | wc -l)
# ext4 overhead ~8 % + journal; round up to 64 MiB
mb=$(( (used_kb * 110 / 100 / 1024 + 128 + SLACK_MB + 63) / 64 * 64 ))
echo "rootfs: $((used_kb / 1024)) MiB in $files files -> image $mb MiB"
rm -f rootfs.ext4; truncate -s ${mb}M rootfs.ext4
mkfs.ext4 -q -F -b 4096 -L nxroot -N $((files * 2 + 65536)) -E lazy_itable_init=0,lazy_journal_init=0 -d "$R" rootfs.ext4
e2fsck -fn rootfs.ext4 | tail -2
dumpe2fs -h rootfs.ext4 2>/dev/null | grep -E 'features|Free blocks|Block count'
rm -rf android; mkdir android
for f in nx-linux.sh nx-linux-boot.sh nx-systemd.sh backend_conf.xml; do tr -d '\r' < $T/phone/$f > android/$f; done
# since 2026-11-03 (one kernel): the install agent the PC installer runs through KernelSU, the
# static busybox it runs with, and the accelerometer bridge for auto-rotate
# (nx-accel: tools/linux/nx-accel/build.sh, built in the EvoX tree)
tr -d '\r' < $T/initboot/nx-agent.sh > android/nx-agent.sh
cp /root/nx-busybox-arm64 android/busybox-arm64
cp /mnt/c/zte/backup/out/linux/nx-accel/nx-accel android/nx-accel || die "build nx-accel first (tools/linux/nx-accel/build.sh)"
sha256sum rootfs.ext4 packages.txt android/* | tee SHA256SUMS
mkdir -p "$PUB/android"
cp rootfs.ext4 packages.txt SHA256SUMS "$PUB/"; cp android/* "$PUB/android/"
(cd "$PUB" && sha256sum -c --quiet SHA256SUMS) || die "copy to $PUB does not verify"
echo BUILD-OK
