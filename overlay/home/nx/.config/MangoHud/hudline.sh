#!/bin/sh
# One line for the MangoHud overlay: the Adreno GPU's load, clock and temperature and the
# battery temperature (MangoHud does not know this GPU; values from the kernel driver).
K=/sys/class/kgsl/kgsl-3d0
read b rest < $K/gpu_busy_percentage
# (MangoHud 0.7 draws this line starting left of the box: the first three characters are padding)
echo "::: GPU ${b}% $(( $(cat $K/gpuclk) / 1000000 )) MHz $(( $(cat $K/temp) / 1000 ))C bat $(( $(cat /sys/class/power_supply/battery/temp) / 10 ))C"
