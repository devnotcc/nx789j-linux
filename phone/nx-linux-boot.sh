#!/system/bin/sh
# Installed as /data/adb/post-fs-data.d/nx-linux-boot.sh (run by KernelSU early in every boot).
# Decides whether this boot goes to Android or to the Linux desktop:
#   /data/nx-linux/bootmode = android      normal Android boot (also when the file is missing)
#                           = linux-once   Linux this boot only; the file is reset to "android"
#                                          BEFORE anything else, so a broken Linux boot falls
#                                          back to Android on the next power cycle
#                           = linux        Linux every boot, except when /data/nx-linux/android-once
#                                          exists (removed, and that one boot is Android)
# For Linux, Android's native side boots as usual (drivers, firmware, vendor daemons, adb) but
# the framework is stopped the moment init starts it, then the Debian chroot takes the screen.
# This script itself returns immediately; the work happens in a detached worker.
B=/data/nx-linux
# trace of the launcher part (a few lines; shows why a boot silently stayed in Android)
[ "$1" = _worker ] || { exec 2>$B/boot-trace.log; echo "$(cut -d' ' -f1 /proc/uptime) launcher start, pid $$, args: $*" >&2; set -x; }
case "$1" in
_worker) ;;
*)
	mode=$(cat $B/bootmode 2>/dev/null)
	case "$mode" in
	linux-once) echo android > $B/bootmode; sync ;;
	linux) if [ -e $B/android-once ]; then rm -f $B/android-once; sync; exit 0; fi ;;
	*) exit 0 ;;
	esac
	[ -f $B/rootfs.ext4 ] && [ -f $B/nx-linux.sh ] || exit 0
	setsid sh $0 _worker </dev/null >$B/boot.log 2>&1 &
	exit 0 ;;
esac

# ---- worker ----
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*"; }
log "linux boot requested"
# Boot guard: count Linux boots that did not stay up. The Linux side sets this back to 0 once it
# has run for a few minutes (nx-bootok.timer); from the 3rd failed boot in a row it leaves Wi-Fi
# and Bluetooth off (nx-bootguard), because a radio that fails to power up makes the kernel
# reset the whole phone - which was an endless boot loop (2026-10-09).
n=$(cat $B/attempts 2>/dev/null); echo $(( ${n:-0} + 1 )) > $B/attempts; sync
log "boot attempt $(cat $B/attempts) since the last good one"
FW="zygote zygote_secondary surfaceflinger audioserver bootanim vendor.qti.hardware.display.composer"
# Phase 1: keep the framework down. init starts these around "zygote-start"/"boot"; stop each
# one as soon as it shows up, and keep watching for a while because init starts some of them
# more than once during boot.
i=0
while [ $i -lt 600 ]; do
	for s in $FW; do
		[ "$(getprop init.svc.$s)" = running ] && { setprop ctl.stop $s; log "stopped $s"; }
	done
	# done with the fast phase once the vendor drivers are all loaded and adb is up
	if [ $i -gt 100 ] && [ "$(getprop vendor.all.modules.ready)" = 1 ] && [ "$(getprop init.svc.adbd)" = running ]; then break; fi
	i=$((i + 1)); sleep 0.1
done
log "framework held down after $i ticks; modules.ready=$(getprop vendor.all.modules.ready) adbd=$(getprop init.svc.adbd)"
# keep guarding in the background (slow) in case something restarts them later
( while true; do for s in $FW; do [ "$(getprop init.svc.$s)" = running ] && setprop ctl.stop $s; done; sleep 2; done ) &

# Trim Android daemons that do nothing on a Linux boot (about 280 MB): the barebones ROM's
# "lean" triggers stop camera, casting, mobile radio, GPS and NFC (so no mobile data or calls
# while in Linux); the list below adds media/DRM/statistics helpers. These properties are not
# persistent, so an Android boot is unaffected.
setprop sys.nubia.lean_base 1; setprop sys.nubia.lean_radio 1
for s in mediaserver media.swcodec mediaextractor mediametrics drm statsd installd storaged gatekeeperd credstore vendor.drm-widevine-hal vendor.drm-clearkey-service vendor-qti-media-c2audio-hal-1-0 vendor.cas-default mdnsd; do
	[ "$(getprop init.svc.$s)" = running ] && setprop ctl.stop $s
done
log "lean: $(getprop | grep 'init.svc\.' | grep -c running) Android services left running"

# The VM memory pool is reserved at boot (8 GB); a desktop boot has no VM, so give it back.
P=/sys/module/gh_hugepage_reserve/parameters
if [ -d $P ]; then
	for n in 1 2 3 4 5 6; do [ "$(cat $P/pool_avail)" -gt 64 ] && break; sleep 2; done
	have=$(cat $P/pool_avail); echo 64 > $P/pool_want
	[ "$have" -gt 64 ] && echo $((have - 64)) > $P/manual_release
	log "pool: $have -> $(cat $P/pool_avail) pages"
fi

# Windows VM (nx-vm): the hypervisor takes guest RAM only in 2 MB blocks, and those are plentiful
# only right after boot (after days of uptime: ~2.6 GB). So reserve the VM's memory now, in the
# background; nx-gamemode lends it to a game while the VM is off. vm/conf/pool-at-boot 0 = don't.
VM=$B/vm
if [ -f $VM/nx-vm-pool.sh ] && [ "$(cat $VM/conf/pool-at-boot 2>/dev/null || echo 1)" = 1 ]; then
	mem=$(cat $VM/conf/mem-mb 2>/dev/null || echo 5120)
	( sh $VM/nx-vm-pool.sh load >/dev/null 2>&1; log "vm $(sh $VM/nx-vm-pool.sh acquire $((mem / 2 + 17)) 2>&1 | tail -1)" ) &
fi

# wait for the panel driver
for n in $(seq 1 60); do [ -e /sys/class/drm/card0-DSI-1 ] && break; sleep 0.5; done
sleep 2
if [ -e /proc/self/ns/pid ] && [ -f $B/nx-systemd.sh ] && [ -x $B/busybox-arm64 ] && [ ! -e $B/no-systemd ]; then
	# kernel 2: real systemd in its own namespaces; its units start the desktop, Wi-Fi, fan...
	log "starting Linux (systemd)"
	sh $B/nx-linux.sh systemd
	log "systemd launched: $(cat $B/systemd.pid 2>/dev/null)"
else
	# kernel 1 (no PID namespaces), or /data/nx-linux/no-systemd: the chroot + script setup
	log "starting Linux (chroot)"
	sh $B/nx-linux.sh up
	chroot $B/root /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/local/sbin/nx-session
	log "nx-session returned $?"
fi
