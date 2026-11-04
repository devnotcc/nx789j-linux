# Local Mesa patch for the NX789J build (applied to a COPY of the source tree by build-mesa.sh).
# Turnip's KGSL backend refuses to enumerate the GPU when the application enabled
# VK_KHR_display, which this build advertises because DRM support is on (needed for GBM).
# vkcube and many engines enable the extension whenever it is offered, so Vulkan apps failed
# with VK_ERROR_INITIALIZATION_FAILED. KGSL just has no displays to offer; let it load.
#   python3 mesa-kgsl-display.py <mesa>/src/freedreno/vulkan/tu_knl_kgsl.cc
import sys

p = sys.argv[1]
s = open(p).read()
start = s.find('if (instance->vk.enabled_extensions.KHR_display) {')
assert start >= 0, 'KHR_display check not found (already patched or source changed)'
end = s.find('}', start)
assert 'VK_ERROR_INITIALIZATION_FAILED' in s[start:end], 'unexpected block contents'
s = s[:start] + '/* nx789j: KHR_display is harmless here (no displays are exposed on KGSL) */' + s[end + 1:]
open(p, 'w').write(s)
print('patched', p)
