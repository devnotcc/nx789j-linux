# Mesa patch (run in the Mesa source tree, see build-mesa.sh SRC): MESA_NO_SWAP_THROTTLE=1 skips the
# wait for the previous frame's fence in dri_flush() at SwapBuffers. With zink on turnip that wait
# covered the whole frame (CPU and GPU never overlapped): Superposition 1080p Medium 19.4 -> 24.6 fps.
p = "src/gallium/frontends/dri/dri_screen.c"
s = open(p).read()
old = "   screen->throttle = pscreen->caps.throttle;"
new = """   /* nx789j: MESA_NO_SWAP_THROTTLE=1 skips the wait for the previous frame at SwapBuffers
    * (with zink on turnip that wait covers the whole frame, so CPU and GPU never overlap) */
   screen->throttle = pscreen->caps.throttle &&
                      !debug_get_bool_option("MESA_NO_SWAP_THROTTLE", false);"""
if new not in s:
    assert old in s
    open(p, "w").write(s.replace(old, new))
