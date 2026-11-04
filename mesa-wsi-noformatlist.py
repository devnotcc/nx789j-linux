# Mesa patch (run in the Mesa source tree, see build-mesa.sh SRC): a swapchain created with
# VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR but without a VkImageFormatListCreateInfo made
# wsi_configure_image() read through a null pointer (the spec requires the list, Mesa "assume"s it).
# Wine/Proton does exactly that when its fullscreen hack is off: CS2 died in vkCreateSwapchainKHR
# as soon as it ran fullscreen below the screen's resolution. Without a list the images are now
# simply created mutable, with no restriction on the view formats.
p = "src/vulkan/wsi/wsi_common.c"
s = open(p).read()
old = """      assume(format_list_in && format_list_in->viewFormatCount > 0);

"""
new = """      /* nx789j: tolerate a missing format list (Wine without its fullscreen hack) */
      if (!format_list_in || format_list_in->viewFormatCount == 0)
         goto nx_no_format_list;

"""
old2 = """      __vk_append_struct(&info->create, &info->format_list);
   }

   info->usage2 ="""
new2 = """      __vk_append_struct(&info->create, &info->format_list);
   }
nx_no_format_list:

   info->usage2 ="""
if new not in s:
    assert old in s and s.count(old2) == 1
    open(p, "w").write(s.replace(old, new).replace(old2, new2))
