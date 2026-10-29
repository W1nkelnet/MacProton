/* Transform feedback test for KosmicKrisp: draws points through a GS that
 * captures its output, then checks the buffer, the counter and
 * vkCmdDrawIndirectByteCountEXT. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

PFN_vkVoidFunction vkGetInstanceProcAddr_(VkInstance, const char *) __asm__("_vkGetInstanceProcAddr");
#define I(name) PFN_##name name = (PFN_##name)vkGetInstanceProcAddr_(inst, #name)
#define CHECK(x) do { VkResult r_ = (x); if (r_) { printf("%s failed: %d\n", #x, r_); exit(1); } } while (0)

static VkInstance inst;
static VkDevice dev;
static VkPhysicalDeviceMemoryProperties memprops;

static uint32_t *load(const char *path, size_t *size)
{
   FILE *f = fopen(path, "rb");
   fseek(f, 0, SEEK_END);
   *size = ftell(f);
   rewind(f);
   uint32_t *data = malloc(*size);
   fread(data, 1, *size, f);
   fclose(f);
   return data;
}

static VkShaderModule module(const char *path)
{
   I(vkCreateShaderModule);
   size_t size;
   uint32_t *code = load(path, &size);
   VkShaderModuleCreateInfo info = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = size, .pCode = code};
   VkShaderModule m;
   CHECK(vkCreateShaderModule(dev, &info, NULL, &m));
   return m;
}

static uint32_t memtype(uint32_t bits, VkMemoryPropertyFlags flags)
{
   for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
      if ((bits & (1u << i)) && (memprops.memoryTypes[i].propertyFlags & flags) == flags)
         return i;
   exit(2);
}

struct buf { VkBuffer b; VkDeviceMemory m; void *map; };

static struct buf buffer(VkDeviceSize size, VkBufferUsageFlags usage)
{
   I(vkCreateBuffer); I(vkGetBufferMemoryRequirements); I(vkAllocateMemory); I(vkBindBufferMemory); I(vkMapMemory);
   struct buf b;
   VkBufferCreateInfo info = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage};
   CHECK(vkCreateBuffer(dev, &info, NULL, &b.b));
   VkMemoryRequirements req;
   vkGetBufferMemoryRequirements(dev, b.b, &req);
   VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
      .memoryTypeIndex = memtype(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
   CHECK(vkAllocateMemory(dev, &alloc, NULL, &b.m));
   CHECK(vkBindBufferMemory(dev, b.b, b.m, 0));
   CHECK(vkMapMemory(dev, b.m, 0, size, 0, &b.map));
   memset(b.map, 0xff, size);
   return b;
}

static VkPrimitiveTopology topology = VK_PRIMITIVE_TOPOLOGY_POINT_LIST;
static VkPipelineCache cache = VK_NULL_HANDLE;

static VkPipeline pipeline(VkPipelineLayout layout, VkShaderModule vs, VkShaderModule gs, VkShaderModule fs)
{
   I(vkCreateGraphicsPipelines);
   VkPipelineShaderStageCreateInfo stages[3] = {
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_GEOMETRY_BIT, .module = gs, .pName = "main"},
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main"},
   };
   VkPipelineVertexInputStateCreateInfo vi = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
   VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = topology};
   VkViewport vp = {0, 0, 4, 4, 0, 1};
   VkRect2D sc = {{0, 0}, {4, 4}};
   VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc};
   VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .rasterizerDiscardEnable = VK_TRUE, .lineWidth = 1};
   VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
   VkPipelineColorBlendAttachmentState att = {.colorWriteMask = 0xf};
   VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att};
   VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
   VkPipelineRenderingCreateInfo ri = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt};
   if (!gs)
      stages[1] = stages[2];
   VkGraphicsPipelineCreateInfo info = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &ri, .stageCount = gs ? 3 : 2, .pStages = stages,
      .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps, .pRasterizationState = &rs,
      .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout};
   VkPipeline p;
   CHECK(vkCreateGraphicsPipelines(dev, cache, 1, &info, NULL, &p));
   return p;
}

static VkPipeline tess_pipeline(VkPipelineLayout layout, VkShaderModule vs, VkShaderModule tcs, VkShaderModule tes, VkShaderModule fs)
{
   I(vkCreateGraphicsPipelines);
   VkPipelineShaderStageCreateInfo stages[4] = {
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, .module = tcs, .pName = "main"},
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, .module = tes, .pName = "main"},
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main"},
   };
   VkPipelineVertexInputStateCreateInfo vi = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
   VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST};
   VkPipelineTessellationStateCreateInfo ts = {VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO, .patchControlPoints = 3};
   VkViewport vp = {0, 0, 4, 4, 0, 1};
   VkRect2D sc = {{0, 0}, {4, 4}};
   VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc};
   VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .rasterizerDiscardEnable = VK_TRUE, .lineWidth = 1};
   VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
   VkPipelineColorBlendAttachmentState att = {.colorWriteMask = 0xf};
   VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att};
   VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
   VkPipelineRenderingCreateInfo ri = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt};
   VkGraphicsPipelineCreateInfo info = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &ri, .stageCount = 4, .pStages = stages,
      .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pTessellationState = &ts, .pViewportState = &vps, .pRasterizationState = &rs,
      .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout};
   VkPipeline p;
   CHECK(vkCreateGraphicsPipelines(dev, cache, 1, &info, NULL, &p));
   return p;
}

static int check(const char *name, const float *v, const float (*want)[4], uint32_t n)
{
   int bad = 0;
   for (uint32_t i = 0; i < n; i++)
      if (memcmp(&v[i * 4], want[i], 16)) {
         if (bad++ < 4)
            printf("  %s[%u] = (%g %g %g %g), want (%g %g %g %g)\n", name, i, v[i * 4], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3],
                   want[i][0], want[i][1], want[i][2], want[i][3]);
      }
   printf("%s: %s\n", name, bad ? "FAIL" : "ok");
   return bad != 0;
}

int main(void)
{
   VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   const char *inst_ext[] = {"VK_KHR_portability_enumeration"};
   VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)vkGetInstanceProcAddr_(NULL, "vkCreateInstance");
   CHECK(vkCreateInstance(&ici, NULL, &inst));
   (void)inst_ext;

   I(vkEnumeratePhysicalDevices); I(vkGetPhysicalDeviceMemoryProperties); I(vkCreateDevice); I(vkGetDeviceQueue);
   I(vkGetPhysicalDeviceFeatures2);
   uint32_t n = 1;
   VkPhysicalDevice pdev;
   CHECK(vkEnumeratePhysicalDevices(inst, &n, &pdev));
   vkGetPhysicalDeviceMemoryProperties(pdev, &memprops);

   VkPhysicalDeviceTransformFeedbackFeaturesEXT xfbf = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT};
   VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &xfbf};
   vkGetPhysicalDeviceFeatures2(pdev, &f2);
   printf("transformFeedback %u geometryStreams %u geometryShader %u\n", xfbf.transformFeedback, xfbf.geometryStreams, f2.features.geometryShader);
   if (!xfbf.transformFeedback)
      return 1;

   VkPhysicalDeviceVulkan13Features v13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &xfbf, .dynamicRendering = VK_TRUE};
   VkPhysicalDeviceFeatures2 enable = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v13, .features.geometryShader = VK_TRUE};
   float prio = 1;
   VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
   const char *ext[] = {"VK_EXT_transform_feedback"};
   VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &enable, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
      .enabledExtensionCount = 1, .ppEnabledExtensionNames = ext};
   CHECK(vkCreateDevice(pdev, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   I(vkCreatePipelineLayout); I(vkCreateCommandPool); I(vkAllocateCommandBuffers); I(vkBeginCommandBuffer); I(vkEndCommandBuffer);
   I(vkQueueSubmit); I(vkQueueWaitIdle); I(vkCmdBindPipeline); I(vkCmdDraw); I(vkCmdDrawIndirect); I(vkCmdBeginRendering); I(vkCmdEndRendering);
   I(vkCmdBindTransformFeedbackBuffersEXT); I(vkCmdBeginTransformFeedbackEXT); I(vkCmdEndTransformFeedbackEXT);
   I(vkCmdDrawIndirectByteCountEXT); I(vkCreateImage); I(vkGetImageMemoryRequirements); I(vkAllocateMemory);
   I(vkBindImageMemory); I(vkCreateImageView); I(vkCmdPipelineBarrier);

   VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
   VkPipelineLayout layout;
   CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
   VkShaderModule vs = module("vs.vert.spv"), fs = module("fs.frag.spv");

   /* Build the pipelines once into a cache, then from its serialized data */
   I(vkCreatePipelineCache); I(vkGetPipelineCacheData);
   VkPipelineCacheCreateInfo pcci = {VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
   CHECK(vkCreatePipelineCache(dev, &pcci, NULL, &cache));
   pipeline(layout, vs, module("gs_dynamic.geom.spv"), fs);
   pipeline(layout, module("vs_xfb.vert.spv"), VK_NULL_HANDLE, module("fs2.frag.spv"));
   topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
   pipeline(layout, module("vs_xfb.vert.spv"), VK_NULL_HANDLE, module("fs2.frag.spv"));
   topology = VK_PRIMITIVE_TOPOLOGY_POINT_LIST;
   size_t cache_size = 0;
   CHECK(vkGetPipelineCacheData(dev, cache, &cache_size, NULL));
   void *cache_data = malloc(cache_size);
   CHECK(vkGetPipelineCacheData(dev, cache, &cache_size, cache_data));
   pcci.initialDataSize = cache_size;
   pcci.pInitialData = cache_data;
   CHECK(vkCreatePipelineCache(dev, &pcci, NULL, &cache));
   printf("pipeline cache: %zu bytes\n", cache_size);
   VkPipeline p_static = pipeline(layout, vs, module("gs_static.geom.spv"), fs);
   VkPipeline p_dynamic = pipeline(layout, vs, module("gs_dynamic.geom.spv"), fs);
   VkPipeline p_streams = pipeline(layout, vs, module("gs_streams.geom.spv"), fs);
   VkPipeline p_tess = tess_pipeline(layout, vs, module("tcs.tesc.spv"), module("tes.tese.spv"), module("fs2.frag.spv"));
   VkPipeline p_vs_points = pipeline(layout, module("vs_xfb.vert.spv"), VK_NULL_HANDLE, module("fs2.frag.spv"));
   topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
   VkPipeline p_vs_strip = pipeline(layout, module("vs_xfb.vert.spv"), VK_NULL_HANDLE, module("fs2.frag.spv"));

   VkImageCreateInfo imci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
      .extent = {4, 4, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
   VkImage img;
   CHECK(vkCreateImage(dev, &imci, NULL, &img));
   VkMemoryRequirements req;
   vkGetImageMemoryRequirements(dev, img, &req);
   VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = memtype(req.memoryTypeBits, 0)};
   VkDeviceMemory imgmem;
   CHECK(vkAllocateMemory(dev, &alloc, NULL, &imgmem));
   CHECK(vkBindImageMemory(dev, img, imgmem, 0));
   VkImageViewCreateInfo ivci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
   VkImageView view;
   CHECK(vkCreateImageView(dev, &ivci, NULL, &view));

   VkBufferUsageFlags xfb_usage = VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT;
   struct buf a = buffer(4096, xfb_usage), b = buffer(4096, xfb_usage), c = buffer(4096, xfb_usage), small = buffer(4096, xfb_usage);
   struct buf d = buffer(4096, xfb_usage), e = buffer(4096, xfb_usage), f = buffer(4096, xfb_usage);
   struct buf g = buffer(4096, xfb_usage), h = buffer(4096, xfb_usage);
   struct buf t = buffer(4096, xfb_usage);
   struct buf indirect = buffer(64, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
   struct buf counters = buffer(64, VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_COUNTER_BUFFER_BIT_EXT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);

   VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
   VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1};
   VkCommandBuffer cmd;
   CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
   VkCommandBufferBeginInfo cbbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
   CHECK(vkBeginCommandBuffer(cmd, &cbbi));

   VkRenderingAttachmentInfo color = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
      .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE};
   VkRenderingInfo rinfo = {VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = {{0, 0}, {4, 4}}, .layerCount = 1,
      .colorAttachmentCount = 1, .pColorAttachments = &color};
   vkCmdBeginRendering(cmd, &rinfo);

   VkDeviceSize zero = 0, whole = VK_WHOLE_SIZE, small_size = 5 * 48;
   VkDeviceSize ctr_offs[9] = {0, 4, 8, 12, 16, 20, 24, 28, 32};

   /* 1: static GS, 4 points, counter written at the end */
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_static);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &a.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 4, 1, 0, 0);
   /* a second draw appends */
   vkCmdDraw(cmd, 2, 1, 4, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[0]);

   /* 2: dynamic GS, 6 points with 0, 1 or 2 triangles each */
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_dynamic);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &b.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 6, 1, 0, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[1]);

   /* 3: draw as many points as buffer a holds triangles' vertices: 18
    * vertices of 16 bytes, so 18 points, 54 vertices out */
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_static);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &c.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDrawIndirectByteCountEXT(cmd, 1, 0, counters.b, 0, 0, 16);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[2]);

   /* 4: overflow, room for 5 triangles out of 8, then resume from the
    * counter and write nothing more */
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &small.b, &zero, &small_size);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 8, 1, 0, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[3]);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[3]);
   vkCmdDraw(cmd, 1, 1, 0, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[3]);

   /* 5: indirect draw of the dynamic GS, 6 points, 2 instances */
   VkDrawIndirectCommand *ind = indirect.map;
   *ind = (VkDrawIndirectCommand){6, 2, 0, 0};
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_dynamic);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &d.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDrawIndirect(cmd, indirect.b, 0, 1, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[4]);

   /* 6: two streams into two buffers, 4 points */
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_streams);
   VkBuffer two[2] = {e.b, f.b};
   VkDeviceSize zeros[2] = {0, 0}, wholes[2] = {VK_WHOLE_SIZE, VK_WHOLE_SIZE};
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 2, two, zeros, wholes);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 4, 1, 0, 0);
   VkBuffer ctr2[2] = {counters.b, counters.b};
   vkCmdEndTransformFeedbackEXT(cmd, 0, 2, ctr2, &ctr_offs[5]);

   /* 7: VS capture, 3 points and 2 instances; a strip of 5 vertices */
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_vs_points);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &g.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 3, 2, 0, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_vs_strip);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &h.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 5, 1, 0, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[7]);

   /* 8: TES capture, 2 patches */
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p_tess);
   vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 1, &t.b, &zero, &whole);
   vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
   vkCmdDraw(cmd, 6, 1, 0, 0);
   vkCmdEndTransformFeedbackEXT(cmd, 0, 1, &counters.b, &ctr_offs[8]);

   vkCmdEndRendering(cmd);
   CHECK(vkEndCommandBuffer(cmd));
   VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
   CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
   CHECK(vkQueueWaitIdle(queue));

   int fail = 0;
   uint32_t *ctr = counters.map;
   uint32_t tess_bytes = ctr[8];
   printf("counters: %u %u %u %u (want %u %u %u %u)\n", ctr[0], ctr[1], ctr[2], ctr[3], 18 * 16, 18 * 16, 54 * 16, 15 * 16);
   fail |= ctr[0] != 18 * 16 || ctr[1] != 18 * 16 || ctr[2] != 54 * 16 || ctr[3] != 15 * 16;

   float want[64][4];
   uint32_t k = 0;
   for (int p = 0; p < 6; p++)
      for (int i = 0; i < 3; i++, k++) {
         want[k][0] = p; want[k][1] = i; want[k][2] = p < 4 ? p : p - 4; want[k][3] = 1;
      }
   fail |= check("static", a.map, want, 18);

   k = 0;
   for (int p = 0; p < 6; p++)
      for (int t = 0; t < p % 3; t++)
         for (int i = 0; i < 3; i++, k++) {
            want[k][0] = p; want[k][1] = i; want[k][2] = t; want[k][3] = 2;
         }
      fail |= check("dynamic", b.map, want, 18);

   k = 0;
   for (int p = 0; p < 18; p++)
      for (int i = 0; i < 3; i++, k++) {
         want[k][0] = p; want[k][1] = i; want[k][2] = p; want[k][3] = 1;
      }
   fail |= check("byte count", c.map, want, 54);

   k = 0;
   for (int p = 0; p < 5; p++)
      for (int i = 0; i < 3; i++, k++) {
         want[k][0] = p; want[k][1] = i; want[k][2] = p; want[k][3] = 1;
      }
   fail |= check("overflow", small.map, want, 15);
   uint32_t past = ((uint32_t *)small.map)[15 * 4];
   printf("overflow: past the end %s\n", past == 0xffffffffu ? "untouched" : "WRITTEN");
   fail |= past != 0xffffffffu;

   printf("counters: %u %u %u (want %u %u %u)\n", ctr[4], ctr[5], ctr[6], 36 * 16, 4 * 16, 4 * 16);
   fail |= ctr[4] != 36 * 16 || ctr[5] != 4 * 16 || ctr[6] != 4 * 16;
   k = 0;
   for (int inst = 0; inst < 2; inst++)
      for (int p = 0; p < 6; p++)
         for (int t = 0; t < p % 3; t++)
            for (int i = 0; i < 3; i++, k++) {
               want[k][0] = p; want[k][1] = i; want[k][2] = t; want[k][3] = 2;
            }
   fail |= check("indirect instanced", d.map, want, 36);
   k = 0;
   for (int p = 0; p < 4; p++, k++) {
      want[k][0] = p; want[k][1] = 0; want[k][2] = 0; want[k][3] = 3;
   }
   fail |= check("stream 0", e.map, want, 4);
   k = 0;
   for (int p = 1; p < 4; p += 2)
      for (int i = 1; i < 3; i++, k++) {
         want[k][0] = p; want[k][1] = i; want[k][2] = 0; want[k][3] = 4;
      }
   fail |= check("stream 1", f.map, want, 4);

   k = 0;
   for (int inst = 0; inst < 2; inst++)
      for (int i = 0; i < 3; i++) {
         want[k][0] = i; want[k][1] = 7; want[k][2] = inst; want[k][3] = 1; k++;
         want[k][0] = 1; want[k][1] = 2; want[k][2] = 3; want[k][3] = i; k++;
      }
   fail |= check("VS points", g.map, want, 12);
   /* strip 0 1 2 3 4 as triangles 012, 132, 234 */
   int strip[9] = {0, 1, 2, 1, 3, 2, 2, 3, 4};
   k = 0;
   for (int i = 0; i < 9; i++) {
      want[k][0] = strip[i]; want[k][1] = 7; want[k][2] = 0; want[k][3] = 1; k++;
      want[k][0] = 1; want[k][1] = 2; want[k][2] = 3; want[k][3] = strip[i]; k++;
   }
   fail |= check("VS strip", h.map, want, 18);
   printf("VS strip counter %u (want %u)\n", ctr[7], 9 * 32);
   fail |= ctr[7] != 9 * 32;

   printf("TES counter %u (want %u)\n", tess_bytes, 6 * 16);
   fail |= tess_bytes != 6 * 16;
   for (int i = 0; i < 6; i++) {
      float *f = (float *)t.map + i * 4;
      int corner = (f[0] == 1) + (f[1] == 1) + (f[2] == 1) == 1 && f[0] + f[1] + f[2] == 1;
      printf("  tes[%d] = %g %g %g %g%s\n", i, f[0], f[1], f[2], f[3], corner && f[3] == 10 + i / 3 ? "" : "  BAD");
      fail |= !(corner && f[3] == 10 + i / 3);
   }

   printf(fail ? "FAILED\n" : "PASSED\n");
   return fail;
}
