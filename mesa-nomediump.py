# Mesa patch (run in the Mesa source tree, see build-mesa.sh SRC): zink no longer decorates
# mediump/lowp GLSL values as RelaxedPrecision unless NX_ZINK_MEDIUMP=1.
#
# Turnip always lowers RelaxedPrecision maths to 16-bit floats (tu_shader.cc mediump_16bit_alu,
# not affected by IR3_SHADER_DEBUG=nofp16). A half float has 11 significant bits, so a mediump
# texture coordinate cannot address single pixels beyond ~1024 px: in every GLES program whose
# shaders use "precision mediump float" (wlroots compositors, Xwayland's glamor, CEF/ANGLE) the
# right half of a wide window lost or doubled pixel columns - thin letters broke up (Steam at
# 1x on a 1920 px monitor; fine in the left half, pixelated in the right half).
import re

p = "src/gallium/drivers/zink/nir_to_spirv/nir_to_spirv.c"
s = open(p).read()
if "nx_relaxed_precision" not in s:
    n = s.count("SpvDecorationRelaxedPrecision")
    assert n >= 1, "no RelaxedPrecision decorations found"
    # every spirv_builder_emit_decoration(..., SpvDecorationRelaxedPrecision) call becomes conditional
    s, k = re.subn(r"(spirv_builder_emit_decoration\([^;]*?SpvDecorationRelaxedPrecision\);)",
                   r"if (nx_relaxed_precision()) \1", s, flags=re.S)
    assert k == n, (k, n)
    helper = '''
/* nx789j: see tools/linux/mesa-nomediump.py */
static bool
nx_relaxed_precision(void)
{
   static int v = -1;
   if (v < 0)
      v = debug_get_bool_option("NX_ZINK_MEDIUMP", false);
   return v;
}
'''
    i = s.index("\n", s.rindex("#include")) + 1
    s = s[:i] + '#include "util/u_debug.h"\n' + helper + s[i:]
    open(p, "w").write(s)
    print("patched", k, "decorations")
else:
    print("already patched")

# Second route to the same thing: with the fp16 shader cap the GLSL compiler itself turns mediump
# floats into 16-bit float types (lower_precision), before zink ever sees a precision qualifier.
p = "src/gallium/drivers/zink/zink_screen.c"
s = open(p).read()
if "NX_ZINK_MEDIUMP" not in s:
    old = """      caps->fp16 =
         screen->info.feats12.shaderFloat16 ||
         (screen->info.have_KHR_shader_float16_int8 &&
          screen->info.shader_float16_int8_feats.shaderFloat16);
"""
    assert old in s
    s = s.replace(old, old + """      /* nx789j: see tools/linux/mesa-nomediump.py */
      if (!debug_get_bool_option("NX_ZINK_MEDIUMP", false))
         caps->fp16 = false;
""")
    open(p, "w").write(s)
    print("patched fp16 cap")
