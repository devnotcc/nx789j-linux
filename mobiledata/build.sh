#!/bin/bash
# Builds nx-radio.dex (run in WSL). Needs the EvoX tree for the JDK, d8, android.jar and the
# radio AIDL Java stubs (copied to lib/).
set -e
cd "$(dirname "$(readlink -f "$0")")"
E=$HOME/evox; J=$E/prebuilts/jdk/jdk21/linux-x86/bin; D8=$E/out/host/linux-x86/bin/d8
SDK=$(ls $E/prebuilts/sdk/*/public/android.jar 2>/dev/null | sort -V | tail -1)
LIB=$(ls lib/*.jar | tr '\n' :)
$J/javap -public -cp $LIB android.hardware.radio.data.IRadioDataResponse android.hardware.radio.data.IRadioDataIndication \
  android.hardware.radio.modem.IRadioModemResponse android.hardware.radio.modem.IRadioModemIndication \
  android.hardware.radio.network.IRadioNetworkResponse android.hardware.radio.network.IRadioNetworkIndication \
  android.hardware.radio.config.IRadioConfigResponse android.hardware.radio.config.IRadioConfigIndication android.hardware.radio.sim.IRadioSimResponse android.hardware.radio.sim.IRadioSimIndication > /tmp/nx-radio-javap.txt
rm -rf gen cls; mkdir gen cls
(cd gen && python3 ../gen-stubs.py /tmp/nx-radio-javap.txt)
$J/javac --release 11 -nowarn -cp "$SDK:$LIB" -d cls src/*.java gen/*.java
$D8 --min-api 30 --output . cls/*.class lib/*.jar 2>&1 | grep -v "^Warning" || true
mv classes.dex nx-radio.dex; ls -la nx-radio.dex
