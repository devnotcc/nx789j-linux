# FEX: also build the Vulkan guest thunk for 32-bit guests (upstream builds it for 64-bit only,
# although the host side already has 32-bit support). Run in the FEX checkout.
p = "ThunkLibs/GuestLibs/CMakeLists.txt"
s = open(p).read()
blk = '''  generate(libvulkan ${CMAKE_CURRENT_SOURCE_DIR}/../libvulkan/libvulkan_interface.cpp)
  target_include_directories(libvulkan-guest-deps INTERFACE ${FEX_PROJECT_SOURCE_DIR}/External/Vulkan-Headers/include/)
  target_include_directories_from_pkgconfig(libvulkan-guest-deps "xcb;x11;xrandr;xrender")
  add_guest_lib(vulkan "libvulkan.so.1")

'''
assert s.count(blk) == 1
s = s.replace(blk, "")
anchor = "# These thunks only support 64-bit\n"
assert s.count(anchor) == 1
s = s.replace(anchor, "# nx789j: Vulkan for 32-bit guests too\n" + blk.replace("\n  ", "\n")[2:] + anchor)
open(p, "w").write(s)
print("patched")
