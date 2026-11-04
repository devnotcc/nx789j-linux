#!/system/bin/sh
# Guest-memory pool for the Windows VM on a Linux boot (Android side, root).
# The gh-hugepage-reserve module used to be loaded by KernelSU at boot; kernel 2 has no
# KernelSU, so this loads it (same arguments its own load.sh computes) and sizes the pool.
#   nx-vm-pool.sh load            insmod with an idle pool (64 pages = 128 MB)
#   nx-vm-pool.sh acquire <pages> grow the pool to <pages> x 2 MB (before starting the VM)
#   nx-vm-pool.sh release         shrink it back to idle (after the VM stops)
#   nx-vm-pool.sh status
M=/data/adb/modules/gh-hugepage-reserve
P=/sys/module/gh_hugepage_reserve/parameters
V=/data/nx-linux/vm
IDLE=64
# RAM kept away from the pool: what the Linux desktop needs while the VM runs
RESERVE=$(cat $V/system-reserve-mb 2>/dev/null); [ -n "$RESERVE" ] || RESERVE=2560
case "$1" in
load)
	# udmabuf: lift the kernel's 64 MB cap on a single GPU buffer; games fail to create their
	# Direct3D device without it (built into the kernel now; older kernels: the module below)
	[ -w /sys/module/udmabuf/parameters/size_limit_mb ] && echo 4096 > /sys/module/udmabuf/parameters/size_limit_mb
	[ -d $P ] && { echo "already loaded"; exit 0; }
	OUT=$($M/kapi_check /sys/kernel/btf/vmlinux 2>/dev/null)
	DIS=$(printf '%s\n' "$OUT" | sed -n 's/^disable=//p' | head -n1)
	MC=$(printf '%s\n' "$OUT" | sed -n 's/^migrate_cma=//p' | head -n1)
	PB=$(sed -n 's/^Page block order:[[:space:]]*//p' /proc/pagetypeinfo 2>/dev/null | head -n1)
	insmod $M/gh_hugepage_reserve.ko ${DIS:+disable_kapi=$DIS} system_reserve_mb=$RESERVE \
		pool_want=$IDLE pool_target=$IDLE migrate_cma_val=${MC:--1} pageblock_order_val=${PB:--1} pool_want_with_cma=0
	rc=$?
	for k in gunyah-host-share gh-unmovable udmabuf; do
		n=$(echo $k | tr - _)
		[ -d /sys/module/$n ] || insmod $V/usr/lib/modules/android15-6.6/$k-gki-6.6.ko || echo "insmod $k failed"
	done
	echo "pool module rc=$rc, max $(cat $P/pool_size_max 2>/dev/null) pages" ;;
acquire)
	want=$2; [ -n "$want" ] || { echo "pages?"; exit 1; }
	max=$(cat $P/pool_size_max); [ "$want" -le "$max" ] || { echo "want $want > max $max (reserve ${RESERVE} MB)"; exit 1; }
	echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory
	echo $want > $P/pool_want
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
		[ "$(cat $P/pool_avail)" -ge $((want - 8)) ] && break
		echo 3 > $P/acquire 2>/dev/null; sleep 4
	done
	echo "pool $(cat $P/pool_avail) of $want pages"
	[ "$(cat $P/pool_avail)" -ge $((want - 8)) ] ;;
release)
	have=$(cat $P/pool_avail); echo $IDLE > $P/pool_want
	[ "$have" -gt $IDLE ] && echo $((have - IDLE)) > $P/manual_release
	echo "pool $(cat $P/pool_avail) pages" ;;
status|*)
	[ -d $P ] || { echo "not loaded"; exit 1; }
	echo "pool_avail=$(cat $P/pool_avail) pool_want=$(cat $P/pool_want) max=$(cat $P/pool_size_max)"
	lsmod | grep -E "^(gunyah_host_share|gh_unmovable|gh_hugepage_reserve)" | awk '{print $1}' | tr '\n' ' '; echo ;;
esac
