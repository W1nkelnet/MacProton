/* Report which DXVK-required Vulkan features MoltenVK exposes. */
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define F(s, f) printf("%-4s %s\n", (s).f ? "ja" : "NEIN", #f)

int main(void)
{
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "mvkcheck", 1, NULL, 0, VK_API_VERSION_1_3 };
    const char *inst_ext[] = { "VK_KHR_get_physical_device_properties2" };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL,
                                 0, &app, 0, NULL, 1, inst_ext };
    VkInstance inst;
    VkPhysicalDevice dev;
    uint32_t n = 1, i, ext_count = 0;
    VkPhysicalDeviceProperties props;
    VkExtensionProperties exts[512];

    if (vkCreateInstance( &ici, NULL, &inst ) != VK_SUCCESS) { puts("vkCreateInstance fehlgeschlagen"); return 1; }
    vkEnumeratePhysicalDevices( inst, &n, &dev );
    vkGetPhysicalDeviceProperties( dev, &props );
    printf("Geraet: %s, Vulkan %u.%u.%u\n\n", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
           VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion));

    VkPhysicalDeviceRobustness2FeaturesEXT rob2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    VkPhysicalDeviceMaintenance5FeaturesKHR m5 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR, &rob2 };
    VkPhysicalDeviceMaintenance6FeaturesKHR m6 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR, &m5 };
    VkPhysicalDeviceDepthClipEnableFeaturesEXT dce = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT, &m6 };
    VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT, &dce };
    VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &xfb };
    VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &v13 };
    VkPhysicalDeviceVulkan11Features v11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &v12 };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v11 };
    vkGetPhysicalDeviceFeatures2( dev, &f2 );
    VkPhysicalDeviceFeatures f = f2.features;

    puts("== Vulkan 1.0 (D3D9/10/11-Basis)");
    F(f, robustBufferAccess); F(f, geometryShader); F(f, imageCubeArray); F(f, depthClamp);
    F(f, depthBiasClamp); F(f, fillModeNonSolid); F(f, sampleRateShading); F(f, shaderClipDistance);
    F(f, shaderCullDistance); F(f, textureCompressionBC); F(f, occlusionQueryPrecise); F(f, independentBlend);
    F(f, fullDrawIndexUint32); F(f, shaderImageGatherExtended); F(f, shaderSampledImageArrayDynamicIndexing);
    F(f, tessellationShader); F(f, multiViewport); F(f, logicOp); F(f, dualSrcBlend);
    puts("== Vulkan 1.1/1.2");
    F(v11, multiview); F(v12, uniformBufferStandardLayout); F(v12, subgroupBroadcastDynamicId);
    F(v12, imagelessFramebuffer); F(v12, separateDepthStencilLayouts); F(v12, hostQueryReset);
    F(v12, timelineSemaphore); F(v12, shaderSubgroupExtendedTypes); F(v12, vulkanMemoryModel);
    F(v12, vulkanMemoryModelDeviceScope); F(v12, bufferDeviceAddress); F(v12, descriptorIndexing);
    F(v12, runtimeDescriptorArray); F(v12, descriptorBindingPartiallyBound); F(v12, samplerMirrorClampToEdge);
    puts("== Vulkan 1.3");
    F(v13, robustImageAccess); F(v13, shaderTerminateInvocation); F(v13, shaderZeroInitializeWorkgroupMemory);
    F(v13, synchronization2); F(v13, shaderIntegerDotProduct); F(v13, maintenance4);
    F(v13, pipelineCreationCacheControl); F(v13, subgroupSizeControl); F(v13, computeFullSubgroups);
    F(v13, shaderDemoteToHelperInvocation); F(v13, inlineUniformBlock); F(v13, dynamicRendering);
    puts("== Erweiterungen");
    F(rob2, nullDescriptor); F(rob2, robustBufferAccess2); F(m5, maintenance5); F(m6, maintenance6);
    F(dce, depthClipEnable); F(xfb, transformFeedback); F(xfb, geometryStreams);

    vkEnumerateDeviceExtensionProperties( dev, NULL, &ext_count, NULL );
    if (ext_count > 512) ext_count = 512;
    vkEnumerateDeviceExtensionProperties( dev, NULL, &ext_count, exts );
    const char *want[] = { "VK_KHR_maintenance5", "VK_KHR_maintenance6", "VK_EXT_depth_clip_enable",
                           "VK_EXT_robustness2", "VK_EXT_transform_feedback", "VK_KHR_swapchain" };
    puts("== Pflicht-Erweiterungen vorhanden?");
    for (unsigned int w = 0; w < sizeof(want) / sizeof(*want); w++)
    {
        int found = 0;
        for (i = 0; i < ext_count; i++) if (!strcmp( exts[i].extensionName, want[w] )) found = 1;
        printf("%-4s %s\n", found ? "ja" : "NEIN", want[w]);
    }
    vkDestroyInstance( inst, NULL );
    return 0;
}
