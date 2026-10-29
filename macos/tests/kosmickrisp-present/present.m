/* Presents a test pattern through KosmicKrisp from a swapchain at half the
 * window's pixel size, so the driver scales it up (MESA_WSI_METAL_UPSCALING,
 * MESA_WSI_METAL_FILTER). Leaves the window open for a few seconds for a
 * screenshot and prints its window number. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

PFN_vkVoidFunction vkGetInstanceProcAddr_(VkInstance, const char *) __asm__("_vkGetInstanceProcAddr");
#define I(name) PFN_##name name = (PFN_##name)vkGetInstanceProcAddr_(inst, #name)
#define CHECK(x) do { VkResult r_ = (x); if (r_ < 0) { printf("%s failed: %d\n", #x, r_); exit(1); } } while (0)

int main(void)
{
   @autoreleasepool {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 512, 512)
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
      CAMetalLayer *layer = [CAMetalLayer layer];
      window.contentView.wantsLayer = YES;
      window.contentView.layer = layer;
      layer.contentsScale = window.backingScaleFactor;
      layer.frame = window.contentView.bounds;
      [window makeKeyAndOrderFront:nil];
      [NSApp activateIgnoringOtherApps:YES];

      VkInstance inst;
      const char *ext[] = {"VK_KHR_surface", "VK_EXT_metal_surface"};
      VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
      VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
                                  .enabledExtensionCount = 2, .ppEnabledExtensionNames = ext};
      PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)vkGetInstanceProcAddr_(NULL, "vkCreateInstance");
      CHECK(vkCreateInstance(&ici, NULL, &inst));
      I(vkCreateMetalSurfaceEXT); I(vkEnumeratePhysicalDevices); I(vkCreateDevice); I(vkGetDeviceQueue);
      I(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);

      VkMetalSurfaceCreateInfoEXT sci = {VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, .pLayer = layer};
      VkSurfaceKHR surface;
      CHECK(vkCreateMetalSurfaceEXT(inst, &sci, NULL, &surface));
      uint32_t n = 1;
      VkPhysicalDevice pdev;
      CHECK(vkEnumeratePhysicalDevices(inst, &n, &pdev));
      VkSurfaceCapabilitiesKHR caps;
      CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pdev, surface, &caps));

      float prio = 1;
      VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
      const char *dext[] = {"VK_KHR_swapchain"};
      VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                                .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext};
      VkDevice dev;
      CHECK(vkCreateDevice(pdev, &dci, NULL, &dev));
      VkQueue queue;
      vkGetDeviceQueue(dev, 0, 0, &queue);
      I(vkCreateSwapchainKHR); I(vkGetSwapchainImagesKHR); I(vkAcquireNextImageKHR); I(vkQueuePresentKHR);
      I(vkCreateCommandPool); I(vkAllocateCommandBuffers); I(vkBeginCommandBuffer); I(vkEndCommandBuffer);
      I(vkCmdPipelineBarrier); I(vkCmdClearColorImage); I(vkQueueSubmit); I(vkQueueWaitIdle);
      I(vkCreateSemaphore);

      /* A quarter of the pixels: half the width and height */
      VkExtent2D extent = {caps.currentExtent.width / 2, caps.currentExtent.height / 2};
      printf("window %ld, surface %ux%u, swapchain %ux%u\n", (long)window.windowNumber,
             caps.currentExtent.width, caps.currentExtent.height, extent.width, extent.height);
      VkSwapchainCreateInfoKHR swci = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surface,
         .minImageCount = 3, .imageFormat = VK_FORMAT_B8G8R8A8_UNORM, .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
         .imageExtent = extent, .imageArrayLayers = 1,
         .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
         .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR, .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
         .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE};
      VkSwapchainKHR swapchain;
      CHECK(vkCreateSwapchainKHR(dev, &swci, NULL, &swapchain));
      VkImage images[8];
      n = 8;
      CHECK(vkGetSwapchainImagesKHR(dev, swapchain, &n, images));

      VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};
      VkCommandPool pool;
      CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
      VkSemaphoreCreateInfo semci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};

      for (int frame = 0; frame < 120; frame++) {
         VkSemaphore acquired, done;
         CHECK(vkCreateSemaphore(dev, &semci, NULL, &acquired));
         CHECK(vkCreateSemaphore(dev, &semci, NULL, &done));
         uint32_t index;
         CHECK(vkAcquireNextImageKHR(dev, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &index));

         VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
                                             .commandBufferCount = 1};
         VkCommandBuffer cmd;
         CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
         VkCommandBufferBeginInfo cbbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
         CHECK(vkBeginCommandBuffer(cmd, &cbbi));
         VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
         VkImageMemoryBarrier to_dst = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = images[index], .subresourceRange = range};
         vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
                              1, &to_dst);
         /* Red background with alpha 0, so a transparent window shows */
         VkClearColorValue red = {{1, 0, 0, 0}};
         vkCmdClearColorImage(cmd, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &red, 1, &range);
         VkImageMemoryBarrier to_present = to_dst;
         to_present.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
         to_present.dstAccessMask = 0;
         to_present.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
         to_present.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
         vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0,
                              NULL, 1, &to_present);
         CHECK(vkEndCommandBuffer(cmd));

         VkPipelineStageFlags wait = VK_PIPELINE_STAGE_TRANSFER_BIT;
         VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acquired,
                            .pWaitDstStageMask = &wait, .commandBufferCount = 1, .pCommandBuffers = &cmd,
                            .signalSemaphoreCount = 1, .pSignalSemaphores = &done};
         CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
         VkPresentInfoKHR pi = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &done,
                                .swapchainCount = 1, .pSwapchains = &swapchain, .pImageIndices = &index};
         CHECK(vkQueuePresentKHR(queue, &pi));
         CHECK(vkQueueWaitIdle(queue));

         [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.016]];
      }
      printf("presented\n");
      fflush(stdout);
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
   }
   return 0;
}
