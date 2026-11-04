#!/bin/bash
# Cross-build Mesa for the phone's Debian (arm64, trixie) in WSL: Turnip (Vulkan) on the
# downstream KGSL kernel driver + Zink (OpenGL on top of Vulkan). Source: the Mesa tree already
# on this PC (~dev/wingpu/mesa, 26.3-devel, has Adreno 8xx support). Compiler: host clang with
# the Debian rootfs as sysroot (only apt inside the sysroot runs under qemu).
# Output: /root/nx-mesa/out/nx-mesa.tar.zst  (installs under /opt/nx-mesa on the phone)
set -euo pipefail
SR=/root/nx789j-linux/rootfs
ORIG=/home/dev/wingpu/mesa
SRC=/root/nx-mesa/src
W=/root/nx-mesa; mkdir -p $W/out
TRIPLE=aarch64-linux-gnu

echo "== sysroot dev packages"
# the image's resolv.conf points at systemd-resolved, which does not exist in this build chroot
rm -f $SR/etc/resolv.conf; echo "nameserver 1.1.1.1" > $SR/etc/resolv.conf
chroot $SR /bin/sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -q 2>&1 | tail -1; apt-get install -y -q --no-install-recommends \
	libc6-dev libgcc-14-dev libstdc++-14-dev linux-libc-dev libdrm-dev libwayland-dev wayland-protocols libwayland-egl-backend-dev \
	libexpat1-dev zlib1g-dev libzstd-dev libelf-dev libudev-dev libxkbcommon-dev libvulkan-dev libdisplay-info-dev libxml2-dev \
	libx11-dev libxext-dev libxfixes-dev libxcb1-dev libxcb-glx0-dev libxcb-shm0-dev libx11-xcb-dev libxcb-dri2-0-dev libxcb-dri3-dev \
	libxcb-present-dev libxcb-sync-dev libxcb-randr0-dev libxcb-xfixes0-dev libxcb-keysyms1-dev libxshmfence-dev libxxf86vm-dev \
	libxrandr-dev x11proto-dev 2>&1 | tail -2'
# absolute symlinks inside the sysroot would point at the host; make them relative
find $SR/usr/lib/$TRIPLE $SR/lib/$TRIPLE -maxdepth 1 -type l 2>/dev/null | while read -r l; do
	t=$(readlink "$l"); case "$t" in /*) ln -sfn "$(realpath -m --relative-to="$(dirname "$l")" "$SR$t")" "$l" ;; esac
done

cat > $W/cross.ini <<EOF
[binaries]
c = ['clang', '--target=$TRIPLE', '--sysroot=$SR']
cpp = ['clang++', '--target=$TRIPLE', '--sysroot=$SR']
c_ld = 'lld'
cpp_ld = 'lld'
ar = 'llvm-ar-18'
strip = 'llvm-strip-18'
pkg-config = 'pkg-config'
[properties]
sys_root = '$SR'
pkg_config_libdir = '$SR/usr/lib/$TRIPLE/pkgconfig:$SR/usr/share/pkgconfig:$SR/usr/lib/pkgconfig'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

# Mesa wants a wayland-scanner on the build machine that matches the target's libwayland
# (1.23.1); Ubuntu 24.04 ships 1.22, so build just the scanner from source once.
if [ ! -x /opt/wl-host/bin/wayland-scanner ]; then
	dpkg -s libexpat1-dev >/dev/null 2>&1 || { apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q libexpat1-dev >/dev/null; }
	echo "== host wayland-scanner"
	mkdir -p $W/wl && cd $W/wl
	curl -fsSL -o wayland.tar.xz https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.23.1/downloads/wayland-1.23.1.tar.xz
	tar -xf wayland.tar.xz
	meson setup build wayland-1.23.1 -Dprefix=/opt/wl-host -Dlibraries=false -Ddocumentation=false -Dtests=false -Ddtd_validation=false >/dev/null
	ninja -C build install >/dev/null
	cd $W
fi
export PATH=/opt/wl-host/bin:$PATH PKG_CONFIG_PATH=$(dirname $(find /opt/wl-host -name wayland-scanner.pc | head -1))
wayland-scanner --version

echo "== source copy + local patch"
# Work on a copy so the original tree (used for the Windows guest drivers) stays untouched.
mkdir -p $SRC; rsync -a --delete --exclude .git $ORIG/ $SRC/
python3 /mnt/c/zte/backup/tools/linux/mesa-kgsl-display.py $SRC/src/freedreno/vulkan/tu_knl_kgsl.cc
grep -n "nx789j" $SRC/src/freedreno/vulkan/tu_knl_kgsl.cc

echo "== configure"
rm -rf $W/build
meson setup $W/build $SRC --cross-file $W/cross.ini \
	-Dprefix=/opt/nx-mesa -Dlibdir=lib -Dbuildtype=release -Db_ndebug=true \
	-Dplatforms=x11,wayland -Dvulkan-drivers=freedreno -Dgallium-drivers=zink -Dfreedreno-kmds=kgsl,msm \
	-Dllvm=disabled -Dglx=dri -Dglvnd=disabled -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dgbm=enabled \
	-Dvideo-codecs= -Dgallium-va=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
	-Dzstd=enabled -Dbuild-tests=false -Dvulkan-layers= -Dtools= 2>&1 | tail -45
echo "== build"
ninja -C $W/build -j10 2>&1 | tail -25
echo "== install + pack"
rm -rf $W/stage; DESTDIR=$W/stage ninja -C $W/build install >/dev/null
( cd $W/stage && find opt/nx-mesa -name '*.so*' -type f -exec llvm-strip-18 --strip-unneeded {} + ; tar --zstd -cf $W/out/nx-mesa.tar.zst opt 2>/dev/null || tar -czf $W/out/nx-mesa.tar.gz opt )
ls -la $W/out; find $W/stage/opt/nx-mesa -name '*.so*' -type f | sed "s#$W/stage##" | head -20
cat $W/stage/opt/nx-mesa/share/vulkan/icd.d/*.json
echo MESA-BUILD-OK
