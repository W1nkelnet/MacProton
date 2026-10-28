/*
 * Report which Vulkan features and limits vkd3d-proton needs for Direct3D 12
 * and whether MoltenVK exposes them.
 *
 * Build: clang -I Vulkan-Headers/include vkd3dcheck.c -o vkd3dcheck -L<MoltenVK> -lMoltenVK
 */
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define F(s, f) printf("%-4s %s\n", (s).f ? "ja" : "NEIN", #f)
#define L(v) printf("     %-55s %llu\n", #v, (unsigned long long)(v))

int main(void)
{
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkd3dcheck", 1, NULL, 0, VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL };
    VkInstance inst;
    VkPhysicalDevice dev;
    uint32_t n = 1, i, ext_count = 0;
    VkExtensionProperties exts[512];

    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) { puts("vkCreateInstance failed"); return 1; }
    vkEnumeratePhysicalDevices(inst, &n, &dev);

    VkPhysicalDeviceRobustness2FeaturesEXT rob2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    VkPhysicalDeviceMutableDescriptorTypeFeaturesEXT mut = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MUTABLE_DESCRIPTOR_TYPE_FEATURES_EXT, &rob2 };
    VkPhysicalDeviceDepthClipEnableFeaturesEXT dce = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT, &mut };
    VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &dce };
    VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &v13 };
    VkPhysicalDeviceVulkan11Features v11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &v12 };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v11 };
    vkGetPhysicalDeviceFeatures2(dev, &f2);

    VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
    VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p12 };
    vkGetPhysicalDeviceProperties2(dev, &p2);
    printf("Geraet: %s, Vulkan %u.%u\n\n", p2.properties.deviceName,
           VK_API_VERSION_MAJOR(p2.properties.apiVersion), VK_API_VERSION_MINOR(p2.properties.apiVersion));

    puts("== Von vkd3d-proton zwingend verlangt");
    F(v12, samplerMirrorClampToEdge);
    F(rob2, robustBufferAccess2);
    F(rob2, robustImageAccess2);
    F(rob2, nullDescriptor);
    F(v11, shaderDrawParameters);

    puts("\n== Descriptor-Heaps (Bindless)");
    F(v12, descriptorIndexing);
    F(v12, runtimeDescriptorArray);
    F(v12, descriptorBindingPartiallyBound);
    F(v12, descriptorBindingVariableDescriptorCount);
    F(v12, descriptorBindingSampledImageUpdateAfterBind);
    F(v12, descriptorBindingStorageImageUpdateAfterBind);
    F(v12, descriptorBindingStorageBufferUpdateAfterBind);
    F(v12, descriptorBindingUniformBufferUpdateAfterBind);
    F(v12, descriptorBindingUniformTexelBufferUpdateAfterBind);
    F(v12, descriptorBindingStorageTexelBufferUpdateAfterBind);
    F(v12, shaderSampledImageArrayNonUniformIndexing);
    F(v12, shaderStorageImageArrayNonUniformIndexing);
    F(v12, shaderStorageBufferArrayNonUniformIndexing);
    F(mut, mutableDescriptorType);
    L(p12.maxUpdateAfterBindDescriptorsInAllPools);
    L(p12.maxDescriptorSetUpdateAfterBindSampledImages);
    L(p12.maxDescriptorSetUpdateAfterBindStorageImages);
    L(p12.maxDescriptorSetUpdateAfterBindStorageBuffers);
    L(p12.maxDescriptorSetUpdateAfterBindSamplers);
    L(p12.maxPerStageDescriptorUpdateAfterBindSampledImages);
    L(p12.maxPerStageUpdateAfterBindResources);
    L(p2.properties.limits.maxBoundDescriptorSets);
    L(p2.properties.limits.maxPushConstantsSize);

    puts("\n== Shader und Rendering");
    F(f2.features, shaderInt64);
    F(f2.features, shaderInt16);
    F(v12, shaderFloat16);
    F(f2.features, shaderFloat64);
    F(v12, bufferDeviceAddress);
    F(v12, timelineSemaphore);
    F(v12, shaderInt8);
    F(v13, dynamicRendering);
    F(v13, synchronization2);
    F(v13, maintenance4);
    F(f2.features, geometryShader);
    F(f2.features, tessellationShader);
    F(f2.features, sparseBinding);
    F(f2.features, sparseResidencyImage2D);
    F(f2.features, shaderStorageImageReadWithoutFormat);
    F(f2.features, shaderStorageImageWriteWithoutFormat);
    F(f2.features, multiDrawIndirect);
    F(v12, drawIndirectCount);
    F(dce, depthClipEnable);

    puts("\n== Erweiterungen");
    vkEnumerateDeviceExtensionProperties(dev, NULL, &ext_count, NULL);
    if (ext_count > 512) ext_count = 512;
    vkEnumerateDeviceExtensionProperties(dev, NULL, &ext_count, exts);
    const char *want[] = { "VK_KHR_push_descriptor", "VK_EXT_robustness2", "VK_EXT_mutable_descriptor_type",
                           "VK_EXT_descriptor_buffer", "VK_EXT_extended_dynamic_state2", "VK_EXT_extended_dynamic_state3",
                           "VK_EXT_vertex_input_dynamic_state", "VK_KHR_fragment_shading_rate",
                           "VK_EXT_dynamic_rendering_unused_attachments", "VK_EXT_image_view_min_lod",
                           "VK_EXT_shader_stencil_export", "VK_KHR_maintenance5" };
    for (size_t w = 0; w < sizeof(want) / sizeof(*want); w++)
    {
        int found = 0;
        for (i = 0; i < ext_count; i++) if (!strcmp(exts[i].extensionName, want[w])) found = 1;
        printf("%-4s %s\n", found ? "ja" : "NEIN", want[w]);
    }
    return 0;
}
