#!/bin/bash
# Build nx-accel in the EvoX tree (WSL). Output: /mnt/c/zte/backup/out/linux/nx-accel/nx-accel
set -e
S=/mnt/c/zte/backup/tools/linux/nx-accel
D=~/evox/vendor/nx789j-tools/nx-accel
DEST=/mnt/c/zte/backup/out/linux/nx-accel
mkdir -p $D $DEST
for f in Android.bp nx-accel.cpp; do tr -d '\r' < $S/$f > $D/$f; done
cd ~/evox
source build/envsetup.sh >/dev/null
# (not "lunch | tail": a pipe runs lunch in a subshell and its exports are lost)
lunch lineage_nx789j-bp4a-userdebug > out/lunch-nx-accel.log 2>&1
echo "lunch: $TARGET_PRODUCT $TARGET_BUILD_VARIANT"
# ~/.ccache is a stray empty file in this WSL, and every ccache compile then fails: no ccache here
export CCACHE_DISABLE=1 CCACHE_DIR=$HOME/.cache/ccache-nx; mkdir -p $CCACHE_DIR
m nx-accel 2>&1 | tail -15
B=$(find out/target/product/*/system/bin -name nx-accel | head -1)
[ -n "$B" ] || { echo "no nx-accel built"; exit 1; }
cp "$B" $DEST/nx-accel; file $DEST/nx-accel | cut -c1-120; sha256sum $DEST/nx-accel
echo NX-ACCEL-BUILT
