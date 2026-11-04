#!/system/bin/sh
# Debian userspace on the phone's Android kernel, as a chroot (the stock GKI config has no
# PID namespaces, devtmpfs or fhandle, so systemd cannot run; services are started by
# /usr/local/sbin/nx-init inside the chroot instead). Run as root from adb.
#   nx-linux.sh mount        loop-mount the image and the kernel filesystems
#   nx-linux.sh sh [cmd...]  run a shell / command inside
#   nx-linux.sh up           start the Linux services (sshd on port 2222, udev, seatd ...)
#   nx-linux.sh down         stop them
#   nx-linux.sh umount       unmount everything
B=/data/nx-linux; R=$B/root; IMG=$B/rootfs.ext4
ENVV="HOME=/root TERM=${TERM:-xterm} PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8"
m() { mountpoint -q "$2" || mount $3 "$1" "$2"; }

do_mount() {
	mkdir -p $R
	# the loop driver reads the image as the "kernel" SELinux domain, which Android does not
	# allow for files in /data; add that one rule at runtime (gone again after a reboot)
	mountpoint -q $R || /data/adb/ksud sepolicy patch "allow kernel system_data_root_file file { read write getattr open }" >/dev/null 2>&1
	mountpoint -q $R || mount -t ext4 -o loop,noatime $IMG $R || exit 1
	m proc $R/proc "-t proc"
	m sysfs $R/sys "-t sysfs"
	# no devtmpfs in this kernel: a tmpfs /dev filled by nx-mkdev (inside) from /sys/dev
	m tmpfs $R/dev "-t tmpfs -o mode=755,size=8m"
	mkdir -p $R/dev/pts $R/dev/shm
	m devpts $R/dev/pts "-t devpts -o gid=5,mode=620,ptmxmode=666"
	m tmpfs $R/dev/shm "-t tmpfs -o mode=1777"
	m tmpfs $R/run "-t tmpfs -o mode=755,size=64m"
	m tmpfs $R/tmp "-t tmpfs -o mode=1777,size=512m"
	m configfs $R/sys/kernel/config "-t configfs" 2>/dev/null
	# Android side, read-only views that hold firmware, plus /data for big files (VM disks)
	mkdir -p $R/android/vendor $R/android/data $R/android/dev
	m /vendor $R/android/vendor "-o bind"
	m /data $R/android/data "-o bind"
	m /dev $R/android/dev "-o bind"
	chroot $R /usr/bin/env -i $ENVV /usr/local/sbin/nx-mkdev
}

case "$1" in
mount) do_mount; grep " $R" /proc/mounts | wc -l ;;
sh) do_mount; shift; if [ $# -gt 0 ]; then exec chroot $R /usr/bin/env -i $ENVV /bin/bash -lc "$*"; else exec chroot $R /usr/bin/env -i $ENVV /bin/bash -l; fi ;;
systemd)
	# Kernel 2: Debian under real systemd in its own namespaces (nx-systemd.sh) instead of the
	# chroot + nx-init setup. Only the image itself is mounted here; the namespace mounts the rest.
	mkdir -p $R
	# one kernel for both (2026-11-03): Android's SELinux stays enforcing and the loop driver
	# reads the image as the "kernel" domain - allow just that (runtime only, gone after reboot;
	# shell_data_file for an image installed before the agent relabelled its files)
	[ -x /data/adb/ksud ] && ! mountpoint -q $R && /data/adb/ksud sepolicy patch \
		"allow kernel { system_data_root_file shell_data_file } file { read write getattr open }" >/dev/null 2>&1
	mountpoint -q $R && echo "image already mounted" || mount -t ext4 -o loop,noatime $IMG $R || { echo "image mount failed"; exit 1; }
	sh $0 _agents
	sh $B/nx-systemd.sh start ;;
up) do_mount; chroot $R /usr/bin/env -i $ENVV /usr/local/sbin/nx-init start
	sh $0 _agents ;;
_agents)
	# agent: lets the Linux side ask Android's init for a clean reboot / power off (nx-power)
	# (pid files survive an unclean shutdown and may then name an unrelated process: check
	# the command line, not just that the pid exists)
	ours() { [ -f "$1" ] && grep -q nx-linux.sh /proc/$(cat "$1")/cmdline 2>/dev/null; }
	if ! ours $B/agent.pid; then
		rm -f $B/ctl; sh $0 _agent </dev/null >/dev/null 2>&1 &
		echo $! > $B/agent.pid
	fi
	if [ -f $B/backend_conf.xml ] && ! ours $B/audio.pid; then
		sh $0 _audio </dev/null >/dev/null 2>&1 &
		echo $! > $B/audio.pid
	fi
	# auto-rotate: the accelerometer through Android's sensors HAL, which only a Linux boot leaves
	# free (on Android the system server owns it - this script only runs on Linux boots)
	if [ -x $B/nx-accel ] && ! grep -q nx-accel /proc/$(cat $B/accel.pid 2>/dev/null)/cmdline 2>/dev/null; then
		$B/nx-accel $B/orientation </dev/null >/dev/null 2>$B/accel.log &
		echo $! > $B/accel.pid
	fi ;;
_audio)
	# Speaker bridge: the vendor AGM player reads a WAV stream from a FIFO that the Linux side
	# (nx-audio-feed) writes whenever something plays. The player needs
	# /vendor/etc/backend_conf.xml, which this vendor image lacks: put ours over /vendor/etc
	# with a RAM-backed overlay (once per boot; an overlay lower layer cannot live on /data).
	if ! [ -f /vendor/etc/backend_conf.xml ]; then
		mkdir -p /mnt/nxa; mountpoint -q /mnt/nxa || mount -t tmpfs tmpfs /mnt/nxa
		cp $B/backend_conf.xml /mnt/nxa/; chmod 644 /mnt/nxa/backend_conf.xml
		mount -t overlay overlay -o lowerdir=/mnt/nxa:/vendor/etc /vendor/etc
	fi
	[ -p $B/audio.fifo ] || { rm -f $B/audio.fifo; mkfifo $B/audio.fifo; chmod 666 $B/audio.fifo; }
	while true; do
		/vendor/bin/agmplay $B/audio.fifo -D 100 -d 100 -i MI2S-LPAIF-RX-PRIMARY -dkv 0xA2000001 >/dev/null 2>&1
		sleep 0.3
	done ;;
_agent)
	while true; do
		if [ -s $B/ctl ]; then c=$(cat $B/ctl); rm -f $B/ctl
			# under systemd, let it stop its services and unmount cleanly first
			[ -f $B/systemd.pid ] && sh $B/nx-systemd.sh stop >/dev/null 2>&1
			case "$c" in reboot) sync; reboot ;; poweroff) sync; reboot -p ;; esac
		fi
		sleep 1
	done ;;
down) chroot $R /usr/bin/env -i $ENVV /usr/local/sbin/nx-init stop ;;
android-stop)
	# Stop the Android framework and its graphics stack so Linux can own the display. Android's
	# init, adbd and the vendor daemons keep running. Undo with android-start, or cleanly with
	# a reboot (stopping the framework leaves /sdcard and the Wi-Fi routes broken until then).
	for s in zygote zygote_secondary surfaceflinger audioserver vendor.qti.hardware.display.composer; do setprop ctl.stop $s 2>/dev/null; done
	sleep 3; for s in zygote surfaceflinger vendor.qti.hardware.display.composer; do echo "$s: $(getprop init.svc.$s)"; done ;;
android-start)
	for s in vendor.qti.hardware.display.composer surfaceflinger audioserver zygote zygote_secondary; do setprop ctl.start $s 2>/dev/null; done ;;
umount)
	grep " $R" /proc/mounts | awk '{print $2}' | sort -r | while read -r p; do umount "$p" 2>/dev/null || umount -l "$p"; done
	grep -c " $R" /proc/mounts ;;
*) echo "usage: $0 mount|sh [cmd]|up|down|android-stop|android-start|umount" ;;
esac
