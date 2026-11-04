#!/bin/sh
# Build the patched wpa_supplicant ON THE PHONE (run as root inside Debian).
# Debian trixie's wpa_supplicant 2.10 ignores the vendor Wi-Fi driver's WPA3 "external auth"
# request: the driver (qca_cld3) reports the key-management suite in host byte order, 2.10 only
# accepts network order (2.11 accepts both). Result without the patch: every WPA3/SAE attempt
# ends in "Authentication ... timed out", and NetworkManager always offers SAE on WPA2/WPA3
# mixed networks. The patched binary goes to /usr/local/sbin; the systemd drop-in
# /etc/systemd/system/wpa_supplicant.service.d/10-nx789j.conf points the service at it.
set -e
echo "deb-src http://deb.debian.org/debian trixie main" > /etc/apt/sources.list.d/nx-src.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc make pkg-config libnl-3-dev libnl-genl-3-dev \
	libnl-route-3-dev libssl-dev libdbus-1-dev libpcsclite-dev libreadline-dev dpkg-dev patch
mkdir -p /root/build && cd /root/build && rm -rf wpa-*
apt-get source -qq wpa
rm -f /etc/apt/sources.list.d/nx-src.list
cd wpa-2.10/wpa_supplicant
python3 - <<'EOF'
p = "sme.c"; s = open(p).read()
old = """	if (RSN_SELECTOR_GET(&data->external_auth.key_mgmt_suite) !=
	    RSN_AUTH_KEY_MGMT_SAE)
		return;
"""
new = """	/* nx789j: the vendor Wi-Fi driver reports the suite in host byte order (as
	 * wpa_supplicant 2.11 also accepts); without this WPA3 never starts */
	if (RSN_SELECTOR_GET(&data->external_auth.key_mgmt_suite) !=
	    RSN_AUTH_KEY_MGMT_SAE &&
	    data->external_auth.key_mgmt_suite != RSN_AUTH_KEY_MGMT_SAE)
		return;
"""
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
EOF
cp ../debian/config/wpasupplicant/linux .config
make -j8 wpa_supplicant
strip -o /usr/local/sbin/wpa_supplicant wpa_supplicant
chmod 755 /usr/local/sbin/wpa_supplicant
mkdir -p /etc/systemd/system/wpa_supplicant.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/local/sbin/wpa_supplicant -u -s -O "DIR=/run/wpa_supplicant GROUP=netdev"\n' \
	> /etc/systemd/system/wpa_supplicant.service.d/10-nx789j.conf
systemctl daemon-reload
echo "installed: $(/usr/local/sbin/wpa_supplicant -v | head -1)"
