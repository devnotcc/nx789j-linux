#!/bin/bash
# Second Mesa build: Turnip only, KGSL only. With no DRM kernel driver enabled Mesa drops
# VK_KHR_display, and that matters: Turnip's KGSL backend fails device enumeration outright
# (VK_ERROR_INITIALIZATION_FAILED) whenever an application enables VK_KHR_display, which
# vkcube and many engines do when the driver advertises it. The first build (build-mesa.sh)
# keeps DRM because GBM/EGL for the compositor need it; this one replaces only
# libvulkan_freedreno.so. Run after build-mesa.sh (reuses its cross file and scanner).
set -euo pipefail
SRC=/home/dev/wingpu/mesa; W=/root/nx-mesa
export PATH=/opt/wl-host/bin:$PATH PKG_CONFIG_PATH=$(dirname $(find /opt/wl-host -name wayland-scanner.pc | head -1))
# glibc: major()/minor() need sys/sysmacros.h, which tu_knl.cc only gets indirectly when DRM is on
rm -rf $W/build-vk
meson setup $W/build-vk $SRC --cross-file $W/cross.ini \
	-Dprefix=/opt/nx-mesa -Dlibdir=lib -Dbuildtype=release -Db_ndebug=true \
	-Dplatforms=wayland -Dvulkan-drivers=freedreno -Dgallium-drivers= -Dfreedreno-kmds=kgsl \
	-Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dgbm=disabled \
	-Dvideo-codecs= -Dgallium-va=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
	-Dzstd=enabled -Dbuild-tests=false -Dvulkan-layers= -Dtools= '-Dcpp_args=-include sys/sysmacros.h' 2>&1 | grep -E "ERROR|Vulkan drivers|platforms|kmds" | head
ninja -C $W/build-vk -j10 2>&1 | tail -3
cp $W/build-vk/src/freedreno/vulkan/libvulkan_freedreno.so $W/out/libvulkan_freedreno.kgsl.so
llvm-strip-18 --strip-unneeded $W/out/libvulkan_freedreno.kgsl.so
ls -la $W/out/libvulkan_freedreno.kgsl.so
echo VK-BUILD-OK
