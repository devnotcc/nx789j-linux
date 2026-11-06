#!/system/bin/sh
# Android side of nx-mobiledata: runs nx-radio.dex (NxRadio) with Android's runtime. Started by
# /usr/local/sbin/nx-mobiledata through `chroot /android`, so Android paths apply here.
# Android services get these variables from init; a process started from Debian has none, and
# BOOTCLASSPATH only exists in the file derive_classpath writes at boot.
while read -r x k v; do [ "$x" = export ] && export "$k=$v"; done < /data/system/environ/classpath
export ANDROID_DATA=/data ANDROID_ROOT=/system ANDROID_ART_ROOT=/apex/com.android.art \
	ANDROID_I18N_ROOT=/apex/com.android.i18n ANDROID_TZDATA_ROOT=/apex/com.android.tzdata \
	CLASSPATH=/data/nx-linux/mobiledata/nx-radio.dex
exec /system/bin/app_process /system/bin NxRadio "$@"
