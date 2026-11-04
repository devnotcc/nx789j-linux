# Install agent. Since 2026-11-03 (one kernel for Android and Linux) the PC installer runs it right
# after the upload, as root through KernelSU (su):
#   su -c "NX_BB=/data/local/tmp/nx-install/busybox-arm64 NX_ROOT= /data/local/tmp/nx-install/busybox-arm64 sh /data/local/tmp/nx-install/nx-agent.sh"
# Always under busybox's shell: Android's (mksh) computes in 32 bits, and the image sizes and the
# free space here do not fit - it refused a 32 GiB image as "smaller than the image" (2026-11-03).
# (The kernel-2 init_boot used to run it from nx-helper.sh, chrooted in its tmpfs, with the
# defaults below.) It installs a finished upload in /data/local/tmp/nx-install:
#   manifest   what to install, one item per line:
#                nx-install 1                          (first line, format)
#                file <name> <bytes> <sha256>          a file of the upload
#                grow rootfs.ext4 <bytes>              make the image this big (sparse; Linux
#                                                      grows its filesystem on the next start)
#                replace rootfs.ext4                   allow replacing an installed image
#   READY      written last by the installer: the upload is complete
# Only the names in ALLOW are ever installed, each must match its size and SHA-256, and nothing is
# installed unless everything checks out. The result goes to nx-install/STATUS for adb to read:
# "ok" or "error <reason>" on the first line. The upload is consumed either way, so a bad one is
# not retried on every boot.
#
# /data/local/tmp belongs to the adb shell user, so everything in it is untrusted: the whole
# directory is first moved into a root-only directory (a rename keeps the files themselves and
# takes them out of the shell user's reach), and only then checked. Symlinks, hard links and
# anything that is not a plain file are refused.
BB=${NX_BB:-/busybox}
P=${NX_ROOT-/proc/1/root}
IN=$P/data/local/tmp/nx-install
D=$P/data/nx-linux
S=$D/.install
ALLOW="rootfs.ext4 nx-linux.sh nx-linux-boot.sh nx-systemd.sh backend_conf.xml nx-accel busybox-arm64 firstboot.conf bootmode"
# space the Android side keeps on /data after the image has been grown
RESERVE=$((2 * 1024 * 1024 * 1024))

alog() { echo "$($BB cut -d' ' -f1 /proc/uptime) agent: $*"; echo "nx-agent: $*" >/dev/kmsg 2>/dev/null; }

status() {
	# STATUS is built in our own directory and renamed into place: a rename replaces whatever
	# the shell user may have put at that name (a symlink is replaced, never followed)
	$BB mkdir -p $IN 2>/dev/null
	if [ -L $IN ] || [ ! -d $IN ]; then alog "cannot report: $IN is not a directory"; return; fi
	$BB chown 2000:2000 $IN; $BB chmod 771 $IN
	echo "$1" > $D/.status.new
	[ -f $S/report ] && $BB cat $S/report >> $D/.status.new
	$BB chown 2000:2000 $D/.status.new; $BB chmod 644 $D/.status.new
	$BB mv -f $D/.status.new $IN/STATUS
	$BB sync
}

fail() {
	alog "error: $*"
	status "error $*"
	$BB rm -rf $S
	exit 1
}

# (sh has no local variables: the loop must not reuse a name the manifest parser uses)
allowed() { for _ok in $ALLOW; do [ "$1" = "$_ok" ] && return 0; done; return 1; }
number() { case $1 in '' | *[!0-9]*) return 1 ;; esac; [ ${#1} -le 15 ]; }
hex64() { case $1 in *[!0-9a-f]*) return 1 ;; esac; [ ${#1} = 64 ]; }

alog "upload found, installing"
[ -L $D ] && fail "/data/nx-linux is a symlink"
$BB mkdir -p $D || fail "cannot create /data/nx-linux"
$BB chown 0:0 $D; $BB chmod 755 $D
$BB rm -rf $S; $BB mkdir -m 700 $S || fail "cannot create the staging directory"
# (the busybox running this script may itself be part of the upload: copy it out first)
case $BB in $IN/*) $BB cp $BB $S/busybox && BB=$S/busybox ;; esac
$BB mv $IN $S/in || fail "cannot take over the upload"
if [ -L $S/in ] || [ ! -d $S/in ]; then fail "nx-install is not a plain directory"; fi
U=$S/in

M=$U/manifest
if [ -L $M ] || [ ! -f $M ]; then fail "no manifest"; fi
[ "$($BB stat -c %s $M)" -le 4096 ] || fail "manifest too large"
[ "$($BB head -n 1 $M | $BB tr -d '\r')" = "nx-install 1" ] || fail "unknown manifest format"

# parse into checked lists first; nothing is moved while the manifest is being read
: > $S/files; grow=; replace=0; n=0
while read -r kw a b c extra; do
	n=$((n + 1)); [ $n = 1 ] && continue
	c=${c%$(printf '\r')}; b=${b%$(printf '\r')}; a=${a%$(printf '\r')}; kw=${kw%$(printf '\r')}
	[ -z "$kw" ] && continue
	[ -z "$extra" ] || fail "manifest line $n has extra fields"
	case $kw in
	file)
		allowed "$a" || fail "file name not allowed: $a"
		number "$b" || fail "bad size for $a"
		hex64 "$c" || fail "bad sha256 for $a"
		$BB grep -q "^$a " $S/files && fail "$a listed twice"
		echo "$a $b $c" >> $S/files ;;
	grow)
		[ "$a" = rootfs.ext4 ] || fail "only rootfs.ext4 can be grown"
		number "$b" || fail "bad grow size"
		[ $((b % 4096)) = 0 ] || fail "grow size is not a multiple of 4096"
		grow=$b ;;
	replace)
		[ "$a" = rootfs.ext4 ] || fail "only rootfs.ext4 can be replaced"
		replace=1 ;;
	*) fail "unknown manifest line $n: $kw" ;;
	esac
	[ $n -le 32 ] || fail "manifest too long"
done < $M
[ -s $S/files ] || [ -n "$grow" ] || fail "manifest lists nothing to do"

# check every file
while read -r name size sha; do
	f=$U/$name
	if [ -L $f ] || [ ! -f $f ]; then fail "$name is missing or not a plain file"; fi
	[ "$($BB stat -c %h $f)" = 1 ] || fail "$name has other hard links"
	[ "$($BB stat -c %s $f)" = "$size" ] || fail "$name has the wrong size"
	$BB chown 0:0 $f; $BB chmod 600 $f
	alog "checking $name ($size bytes)"
	got=$($BB sha256sum $f | $BB cut -d' ' -f1)
	[ "$got" = "$sha" ] || fail "$name does not match its sha256"
done < $S/files

if $BB grep -q "^bootmode " $S/files; then
	case "$($BB head -n 1 $U/bootmode | $BB tr -d '\r')" in android | linux | linux-once) ;; *) fail "bad bootmode" ;; esac
fi
if $BB grep -q "^rootfs.ext4 " $S/files && [ -e $D/rootfs.ext4 ] && [ $replace = 0 ]; then
	fail "Linux is already installed (rootfs.ext4 exists) and the upload does not say to replace it"
fi
img=$D/rootfs.ext4; $BB grep -q "^rootfs.ext4 " $S/files && img=$U/rootfs.ext4
if [ -n "$grow" ]; then
	[ -f $img ] || fail "no rootfs.ext4 to grow"
	cur=$($BB stat -c %s $img)
	[ "$grow" -ge "$cur" ] || fail "grow size is smaller than the image"
	# room: free space now, plus what an image being replaced gives back
	# (statfs of the path itself: df would look the mount up in this namespace, which has no /data)
	avail=$($BB stat -f -c '%a %S' $P/data/. | $BB awk '{printf "%.0f", $1 * $2}')
	number "$avail" || fail "cannot read the free space of /data"
	if [ "$img" != "$D/rootfs.ext4" ] && [ -f $D/rootfs.ext4 ]; then
		avail=$((avail + $($BB stat -c %b $D/rootfs.ext4) * $($BB stat -c %B $D/rootfs.ext4)))
	fi
	[ $((grow - cur)) -le $((avail - RESERVE)) ] || fail "not enough free space on /data to grow the image to $grow bytes"
fi

# everything checked: install
while read -r name size sha; do
	case $name in rootfs.ext4 | firstboot.conf) mode=600 ;; busybox-arm64 | nx-accel) mode=755 ;; *) mode=644 ;; esac
	$BB chmod $mode $U/$name
	$BB mv -f $U/$name $D/$name || fail "could not install $name"
	echo "installed $name" >> $S/report
	alog "installed $name"
done < $S/files
if $BB grep -q "^rootfs.ext4 " $S/files; then
	# a new image starts with a clean boot counter
	$BB rm -f $D/attempts
fi
if [ -n "$grow" ]; then
	$BB truncate -s $grow $D/rootfs.ext4 || fail "could not grow rootfs.ext4"
	echo "rootfs.ext4 size $grow" >> $S/report
	alog "rootfs.ext4 grown to $grow bytes"
fi
# files moved out of /data/local/tmp keep its SELinux label (shell_data_file); give them the
# label of their new home, so the boot hook (enforcing Android) can use them
if [ -x $P/system/bin/chcon ]; then
	$BB chroot ${P:-/} /system/bin/chcon -R u:object_r:system_data_root_file:s0 /data/nx-linux 2>/dev/null ||
		alog "could not relabel /data/nx-linux"
fi
# the boot hook: KernelSU runs /data/adb/post-fs-data.d/*.sh early in every boot, as root; the
# launcher decides Android or Linux from /data/nx-linux/bootmode
if [ -f $D/nx-linux-boot.sh ] && [ -d $P/data/adb ]; then
	H=$P/data/adb/post-fs-data.d
	$BB mkdir -p $H && $BB cp $D/nx-linux-boot.sh $H/nx-linux-boot.sh.new && $BB chmod 755 $H/nx-linux-boot.sh.new &&
		$BB mv -f $H/nx-linux-boot.sh.new $H/nx-linux-boot.sh || fail "could not install the boot hook"
	echo "installed boot hook" >> $S/report
fi
$BB sync
status ok
alog "done"
# (last: $BB may be the copy in $S)
$BB rm -rf $S
exit 0
