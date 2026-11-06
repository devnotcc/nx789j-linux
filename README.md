# Debian 13 + KDE Plasma for the nubia REDMAGIC 10 Pro (NX789J)

How the "Debian 13 with KDE Plasma" package of the
[installer](https://github.com/devnotcc/nx789j-installer) is made. Debian runs on the Android
kernel ([android_kernel_nubia_nx789j](https://github.com/devnotcc/android_kernel_nubia_nx789j)):
KernelSU starts systemd in its own namespaces on an ext4 image in `/data`, nothing is written to
the phone's partitions, and Android is one reboot away.

| Path | What |
|---|---|
| `build-debian-plasma.sh` | builds `rootfs.ext4` (mmdebstrap, trixie, arm64 through qemu-user) |
| `patch-rootfs-2026110{3,4,6}.sh` | the fixes on top of the built image, one per published image (11-06: mobile data) |
| `mobiledata/` | `NxRadio` (`nx-radio.dex`): a small client of Android's radio HALs that registers on the network and sets up the data call for Linux; `overlay/usr/local/sbin/nx-mobiledata` drives it and sets routes and DNS, `org.nx789j.mobiledata` is the tray applet |
| `overlay/` | files copied into the image (`public/exclude.txt` lists what the public image leaves out) |
| `phone/` | Android side: the KernelSU boot hook, the launcher, systemd in namespaces |
| `initboot/nx-agent.sh` | the install agent the installer runs as root on the phone |
| `nx-accel/` | accelerometer reader for auto-rotate (Android binary, built in the ROM tree) |
| `build-mesa.sh`, `build-mesa-vk.sh`, `mesa-*.py`, `patches/mesa.diff` | Mesa (Turnip on KGSL + Zink) in `/opt/nx-mesa` |
| `build-wpa.sh` | `wpa_supplicant` 2.10 with the WPA3 external-auth fix for the Qualcomm Wi-Fi driver |
| `fex/` | `libnx-sysvsem.so` (System V semaphores without `CONFIG_SYSVIPC`) |
| `THIRD_PARTY.md` | where the other binaries in the image come from |

The scripts still carry the author's paths (`/mnt/c/zte/backup/...`, WSL); adjust `T=`, `OUT=`
and `BIN=` at the top.

## License

GPL-3.0-or-later for the scripts and files in this repository (see [LICENSE](LICENSE)).
Debian packages keep their own licenses; their source is at
[sources.debian.org](https://sources.debian.org).
