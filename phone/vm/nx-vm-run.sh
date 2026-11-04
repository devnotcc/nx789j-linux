#!/system/bin/sh
# Run the Windows VM on a Linux boot. Android side, root (from Debian: chroot /android ...).
# Uses the DroidVM host binaries (bionic crosvm + virglrenderer, the "wingpu" build) directly;
# the Android app that normally starts them cannot run without the framework.
#   nx-vm-run.sh            foreground; logs to /data/nx-linux/vm/run/
# Settings (files in /data/nx-linux/vm/conf, all optional):
#   mem-mb (5120)  cpus (6)  disk (disk/win11-ltsc.raw)  vram-gb (2)  vram-budget-mb
#   display (wayland|vnc)  size (1600x900)  fullscreen (0)  extra-args
V=/data/nx-linux/vm
U=$V/usr
RUN=$V/run; mkdir -p $RUN $V/conf
c() { cat $V/conf/$1 2>/dev/null || echo "$2"; }
MEM=$(c mem-mb 5120); CPUS=$(c cpus 6); DISK=$(c disk $V/disk/win11-ltsc.raw)
GB=$(c vram-gb 2); MB=$(c vram-budget-mb $((GB * 1024)))
TAP=nxvm0; MAC=02:54:c1:66:65:32
[ -f "$DISK" ] || { echo "no disk $DISK"; exit 1; }
# UEFI variable store: with the stock template the firmware crashes at start here (it did not
# under the app, cause unknown), and Windows boots fine without one. conf/vars.fd enables it.
PFLASH=""; [ -f $V/conf/vars.fd ] && PFLASH="--pflash path=$V/conf/vars.fd,block_size=262144"

# memory pool: guest RAM comes from the 2 MB page pool (RAM/2 pages plus slack for the GPU arena)
sh $V/nx-vm-pool.sh load >/dev/null
# (2 MB pages; after hours of uptime memory is fragmented and the pool may not reach the
# requested size: then the VM gets what the pool could collect, down to 4 GB, instead of failing)
reserve() {
	PAGES=$((MEM / 2 + 17))
	sh $V/nx-vm-pool.sh acquire $PAGES && return 0
	got=$(cat /sys/module/gh_hugepage_reserve/parameters/pool_avail)
	# (the rest cannot come from ordinary memory: crosvm can lend it in 1 MB chunks, but the
	# hypervisor's resource manager then refuses the guest memory, MEM_ACCEPT error 9)
	fit=$(( (got - 17) * 2 / 128 * 128 ))
	if [ $fit -ge 4096 ]; then
		echo "pool reached only $got pages: VM memory $MEM -> $fit MB"
		MEM=$fit; PAGES=$((MEM / 2 + 17)); echo $PAGES > /sys/module/gh_hugepage_reserve/parameters/pool_want
		return 0
	fi
	unreserve; return 1
}
# after the VM: keep the memory reserved for the next start (conf/pool-at-boot 1, the default:
# 2 MB blocks are hard to get back later; nx-gamemode lends them to games), else give it back
unreserve() {
	[ "$(c pool-at-boot 1)" = 1 ] || sh $V/nx-vm-pool.sh release
}

# what the DroidVM app does before every start
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
echo advise > /sys/kernel/mm/transparent_hugepage/shmem_enabled

# network: a tap device; the Linux side (nx-vm-net) gives it an address, DHCP and NAT
ip link show $TAP >/dev/null 2>&1 || ip tuntap add dev $TAP mode tap
ip link set $TAP up

# vCPU placement: 0,1 on the two prime cores, the rest on cores 2-5 (0-1 stay with the host)
AFF="0=6:1=7"; CAP="0=1024,1=1024"; i=2
while [ $i -lt $CPUS ]; do AFF="$AFF:$i=2-5"; CAP="$CAP,$i=765"; i=$((i + 1)); done

# Windows' screen size; the window can be resized freely (the picture is scaled to it)
SIZE=$(c size 1600x900); SW=${SIZE%x*}; SH=${SIZE#*x}
case "$(c display wayland)" in
vnc) DISP="--vnc-server host=127.0.0.1,port=5900,screen=gpu-0,transport-cap=gpu" ;;
# a window on the Linux desktop: the compositor's socket directory is bind-mounted to $V/xdg
wayland) DISP="--wayland-sock $V/xdg/$(cat $RUN/wl-socket 2>/dev/null || echo wayland-0) --display-window-keyboard --display-window-mouse"; export XDG_RUNTIME_DIR=$V/xdg CROSVM_NO_WL_DEVICE=1
	export CROSVM_WL_TOUCH_SIZE=$SIZE CROSVM_WL_TITLE="Windows 11" CROSVM_WL_APP_ID=nx-windows-vm
	# inside the nx-cage window the resolution follows the window (nx-vm-resize) and nx-cage
	# rescales input itself; crosvm's own small-mode centring offset must stay out of it
	[ -s $RUN/wl-socket ] && export CROSVM_WL_TOUCH_SIZE=1x1
	[ "$(c fullscreen 0)" = 1 ] && export CROSVM_WL_FULLSCREEN=1 ;;
*) DISP="" ;;
esac

export LD_LIBRARY_PATH=$U/lib
export NCTX_VA_SLICE_GB=$GB
# optional extra environment for crosvm / the GPU renderer (debug switches), one VAR=value per line
[ -f $V/conf/env ] && while read -r kv; do case "$kv" in ''|\#*) ;; *) export "$kv" ;; esac; done < $V/conf/env
# mouse: relative motion for games comes from nx-vm-mouse on the Linux side through a socket
MOUSE=; for i in 1 2 3 4 5 6; do [ -S $RUN/mouse.sock ] && { MOUSE="--input mouse[path=$RUN/mouse.sock]"; break; }; sleep 1; done
# pointer of the windowed VM as an absolute mouse, from the nx-cage window (nx-vm-window)
[ -S $V/xdg/nx-vm-tablet.sock ] && MOUSE="$MOUSE --input absolute-mouse[path=$V/xdg/nx-vm-tablet.sock,width=32768,height=32768,name=NX-Tablet]"
export HOME=$RUN TMPDIR=$RUN
rm -f $RUN/vm.sock
# sound: the "file" backend of the patched crosvm also streams into this FIFO (nx-vm-audio reads it)
mkdir -p $RUN/snd; rm -f $RUN/snd/*; [ -p $RUN/snd.pipe ] || { rm -f $RUN/snd.pipe; mkfifo $RUN/snd.pipe; }; chmod 644 $RUN/snd.pipe
export CROSVM_SND_PIPE=$RUN/snd.pipe
# never the kernel's first choice when memory runs out (it would take the whole VM down)
echo -800 > /proc/self/oom_score_adj
# every GPU buffer the guest creates is a file descriptor on the host
ulimit -n 1048576 2>/dev/null || ulimit -n 65536
cd $RUN
echo "$(date) starting: mem=$MEM cpus=$CPUS disk=$DISK vram=${GB}G/${MB}M" > $RUN/crosvm.log
# crosvm exits when the guest reboots (status 32 with --extended-status); start it again, as
# the DroidVM app does. Any other status ends the run.
trap 'kill $PID 2>/dev/null' TERM INT
while true; do
reserve >> $RUN/crosvm.log 2>&1 || { echo "could not reserve guest memory" >> $RUN/crosvm.log; rc=1; break; }
$U/libexec/crosvm --extended-status run --name nx-windows \
	--mem $MEM --cpus $CPUS --cpu-affinity $AFF --cpu-capacity $CAP \
	--cpu-cluster 2-$((CPUS - 1)) --cpu-cluster 0-1 \
	--hypervisor gunyah --pre-alloc drm-host-mb=64 \
	--protected-vm-pseudo-unprotected --no-balloon --disable-sandbox --hugepages \
	--prepare-lend-mthp-mode chunked --boost-uclamp \
	--socket $RUN/vm.sock --smbios "processor-version=Qualcomm Snapdragon 8 Elite" \
	--block "$DISK,lock=false" \
	--net tap-name=$TAP,mac=$MAC \
	--gpu "virglrenderer,displays=[[mode=windowed[$SW,$SH],refresh-rate=120,dpi=[160,160]]],context-types=drm,vulkan=false,egl=true,gles=true,udmabuf=true,pci-bar-size=4294967296,vram-mb=$MB" \
	$DISP $MOUSE \
	--virtio-snd backend=file,playback_path=$RUN/snd,playback_size=4194304 \
	--serial type=file,hardware=serial,num=1,path=$RUN/serial1.log \
	--serial type=sink,hardware=serial,num=2 --serial type=sink,hardware=serial,num=3 \
	--serial type=sink,hardware=serial,num=4 \
	--serial type=file,hardware=sbsa,num=1,path=$RUN/sbsa.log,console,earlycon \
	$(c extra-args "") \
	$U/share/droidvm/edk2-gunyah.fd $PFLASH \
	>>$RUN/crosvm.log 2>&1 &
PID=$!; echo $PID > $RUN/crosvm.pid
# Windows restarting itself = crosvm sees a "system reset event" and should exit with 32, but it
# can hang in its own teardown instead (seen 2026-10-15; the VM is then gone and nothing comes
# back). Watch the new part of the log: reset seen and crosvm still there 15 s later -> kill it
# and restart as for a normal guest reboot.
rm -f $RUN/reset-killed
# crosvm switches the small multi-size THP (16 KB .. 1 MB) to "always" system-wide while it
# prepares the guest memory ("GH: Phase 1: enabled mTHP at intermediate sizes"); left on, a
# failing 32 KB allocation in the Windows 7 QEMU sent the kernel to the OOM killer, which took
# KWin and plasmashell (2026-10-15). It only needs them for that (four rounds, all before the
# guest starts): switch back off once it hands over to the guest.
( off=$(stat -c %s $RUN/crosvm.log)
  for i in $(seq 1 90); do
	sleep 1
	tail -c +$((off + 1)) $RUN/crosvm.log 2>/dev/null | grep -q "handing over to the payload" && break
  done
  for d in /sys/kernel/mm/transparent_hugepage/hugepages-*kB; do
	case $d in *-2048kB) ;; *) echo never > $d/enabled 2>/dev/null ;; esac
  done ) &
( off=$(stat -c %s $RUN/crosvm.log)
  while kill -0 $PID 2>/dev/null; do
	sleep 3
	tail -c +$((off + 1)) $RUN/crosvm.log 2>/dev/null | grep -q "system reset event" || continue
	sleep 15
	kill -0 $PID 2>/dev/null || break
	echo "$(date) crosvm hung after the guest reset: killed, restarting" >> $RUN/crosvm.log
	touch $RUN/reset-killed; kill -9 $PID
	break
  done ) &
WD=$!
wait $PID; rc=$?
kill $WD 2>/dev/null
[ -f $RUN/reset-killed ] && { rm -f $RUN/reset-killed; rc=32; }
echo "$(date) crosvm exited with status $rc" >> $RUN/crosvm.log
[ $rc = 32 ] || break
sleep 2
done
rm -f $RUN/crosvm.pid
unreserve >> $RUN/crosvm.log 2>&1
exit $rc
