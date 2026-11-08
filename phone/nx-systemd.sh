#!/system/bin/sh
# Start Debian with real systemd as PID 1 of its own PID / mount / UTS / IPC namespaces
# (kernel 2 only: needs CONFIG_PID_NS and devtmpfs). Run as root on the Android side, after
# the image is mounted at /data/nx-linux/root (nx-linux.sh mount does that).
#   nx-systemd.sh start     launch (returns immediately; systemd keeps running detached)
#   nx-systemd.sh stop      ask systemd to shut down, then kill what is left
#   nx-systemd.sh pid       print the host PID of the namespace's init
# Inside, the old Android root is visible at /android (so /android/vendor, /android/data and
# /android/dev keep working exactly as in the chroot setup).
B=/data/nx-linux; R=$B/root; BB=$B/busybox-arm64
CG=/sys/fs/cgroup/nx-linux
case "$1" in
start)
	mountpoint -q $R || { echo "image not mounted"; exit 1; }
	[ -x $BB ] || { echo "no $BB"; exit 1; }
	# a pid file left by an unclean shutdown can point at an unrelated process: check the name
	[ -f $B/systemd.pid ] && [ "$(cat /proc/$(cat $B/systemd.pid)/comm 2>/dev/null)" = systemd ] && { echo "already running"; exit 0; }
	rm -f $B/systemd.pid
	# USB audio offload off: snd_usb_audio_qmi lets Android's audio HAL hand a USB sound card to
	# the DSP (xhci_sideband). Android's side keeps running under Linux and still probes a USB
	# card on plug-in; with PipeWire using the same card the USB controller faulted in the IOMMU
	# and the kernel panicked (2026-11-08, arm-smmu BUG, a600000.dwc3). Without the module both
	# use the plain USB audio driver: tested with a DS4 controller (playback, unplug, replug).
	# It is loaded again on the next boot (a restart into Android).
	grep -q '^snd_usb_audio_qmi ' /proc/modules && { rmmod snd_usb_audio_qmi && echo "USB audio offload unloaded" || echo "USB audio offload could not be unloaded"; }
	# systemd needs a cgroup of its own to manage; it finds it through /proc/1/cgroup
	# (left-over child groups of an earlier run, e.g. after a power-off from inside, would make
	# the kernel refuse new processes in it: remove the empty tree first)
	[ -d $CG ] && find $CG -depth -type d -exec rmdir {} \; 2>/dev/null
	mkdir -p $CG
	setsid $BB unshare -m -p -u -i -f --propagation private $BB sh $B/nx-systemd.sh _inside </dev/null >$B/systemd-start.log 2>&1 &
	sleep 3
	# the namespace's init is the child of the unshare process
	for p in $(cat $CG/cgroup.procs $CG/init.scope/cgroup.procs 2>/dev/null); do [ "$(cat /proc/$p/comm 2>/dev/null)" = systemd ] && { echo $p > $B/systemd.pid; break; }; done
	if [ -f $B/systemd.pid ]; then echo "systemd host pid: $(cat $B/systemd.pid)"
	else echo "systemd did not start:"; cat $B/systemd-start.log; exit 1; fi ;;
_inside)
	# PID 1 of the new PID namespace, private mount namespace, still on Android's root
	# only the namespace's init goes into the cgroup (the unshare parent must stay outside:
	# cgroup v2 does not allow processes in a cgroup whose children use controllers)
	echo $$ > $CG/cgroup.procs
	cd $R || exit 1
	$BB mkdir -p $R/android
	$BB pivot_root . android || { echo "pivot_root failed"; exit 1; }
	cd /
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
	mount -t proc proc /proc
	mount -t sysfs sysfs /sys
	mount -t devtmpfs devtmpfs /dev
	mkdir -p /dev/pts /dev/shm
	mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts
	[ -e /dev/ptmx ] || ln -s pts/ptmx /dev/ptmx
	mount -t tmpfs -o mode=1777 tmpfs /dev/shm
	mount -t tmpfs -o mode=755,size=128m tmpfs /run
	mount -t tmpfs -o mode=1777,size=1g tmpfs /tmp
	mount -t cgroup2 cgroup2 /sys/fs/cgroup
	hostname nx789j
	# "container" makes systemd use the cgroup it was started in and leave /dev and the
	# kernel command line alone. SELinux is not mounted in here, so systemd treats it as off.
	exec /usr/bin/env -i container=nx-android PATH=$PATH /sbin/init --log-target=journal-or-kmsg ;;
stop)
	p=$(cat $B/systemd.pid 2>/dev/null); [ -n "$p" ] && kill -0 $p 2>/dev/null || { echo "not running"; exit 0; }
	kill -37 $p           # SIGRTMIN+3 = halt (no signal names in Android sh): stops the Linux side only;
	                      # a power-off (-38) would turn the whole phone off (system-shutdown/nx-power)
	i=0; while [ $i -lt 40 ] && kill -0 $p 2>/dev/null; do i=$((i + 1)); sleep 1; done
	kill -9 $p 2>/dev/null; for q in $(cat $CG/cgroup.procs 2>/dev/null); do kill -9 $q 2>/dev/null; done
	rm -f $B/systemd.pid; echo stopped ;;
pid) cat $B/systemd.pid 2>/dev/null ;;
*) echo "usage: $0 start|stop|pid" ;;
esac
