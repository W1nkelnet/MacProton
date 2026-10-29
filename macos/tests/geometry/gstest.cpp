// gstest: renders with geometry shaders through MoltenVK offscreen and checks pixels.
// Each test draws with emulated geometry shaders and compares pixels with what they emit.
// usage: gstest SHADERDIR OUTDIR
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static const uint32_t W = 256, H = 256;
static VkDevice dev;
static VkPhysicalDevice phys;
static std::string shaderDir, outDir;

static std::vector<char> readFile(const std::string& p) {
	std::ifstream f(p, std::ios::binary);
	if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(1); }
	return std::vector<char>((std::istreambuf_iterator<char>(f)), {});
}

static VkShaderModule shader(const char* name) {
	auto code = readFile(shaderDir + "/" + name);
	VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
	ci.codeSize = code.size();
	ci.pCode = (const uint32_t*)code.data();
	VkShaderModule m;
	CHECK(vkCreateShaderModule(dev, &ci, nullptr, &m));
	return m;
}

static uint32_t memType(uint32_t bits, VkMemoryPropertyFlags props) {
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(phys, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & props) == props) { return i; }
	}
	fprintf(stderr, "no memory type\n");
	exit(1);
}

struct Buffer { VkBuffer buf; VkDeviceMemory mem; void* map; };
static Buffer buffer(VkDeviceSize size, VkBufferUsageFlags usage) {
	Buffer b;
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
	ci.size = size;
	ci.usage = usage;
	CHECK(vkCreateBuffer(dev, &ci, nullptr, &b.buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, b.buf, &req);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
	ai.allocationSize = req.size;
	ai.memoryTypeIndex = memType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	CHECK(vkAllocateMemory(dev, &ai, nullptr, &b.mem));
	CHECK(vkBindBufferMemory(dev, b.buf, b.mem, 0));
	CHECK(vkMapMemory(dev, b.mem, 0, size, 0, &b.map));
	return b;
}

struct Pipe { VkPipeline pipe; };

static VkPipeline pipeline(VkRenderPass rp, VkPipelineLayout layout, VkShaderModule vs, VkShaderModule gs, VkShaderModule fs, VkPrimitiveTopology topo) {
	VkPipelineShaderStageCreateInfo stages[3] = {};
	uint32_t n = 0;
	for (auto p : { std::make_pair(VK_SHADER_STAGE_VERTEX_BIT, vs), std::make_pair(VK_SHADER_STAGE_GEOMETRY_BIT, gs), std::make_pair(VK_SHADER_STAGE_FRAGMENT_BIT, fs) }) {
		if (!p.second) { continue; }
		stages[n].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
		stages[n].stage = p.first;
		stages[n].module = p.second;
		stages[n].pName = "main";
		n++;
	}
	VkVertexInputBindingDescription bind = { 0, 24, VK_VERTEX_INPUT_RATE_VERTEX };
	VkVertexInputAttributeDescription attrs[2] = { { 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 }, { 1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 8 } };
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	vi.vertexBindingDescriptionCount = 1;
	vi.pVertexBindingDescriptions = &bind;
	vi.vertexAttributeDescriptionCount = 2;
	vi.pVertexAttributeDescriptions = attrs;
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
	ia.topology = topo;
	VkViewport vp = { 0, 0, float(W), float(H), 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
	vps.viewportCount = 1; vps.pViewports = &vp; vps.scissorCount = 1; vps.pScissors = &sc;
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
	rs.polygonMode = VK_POLYGON_MODE_FILL; rs.cullMode = VK_CULL_MODE_NONE; rs.lineWidth = 1;
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
	ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
	VkPipelineColorBlendAttachmentState cba = {};
	cba.colorWriteMask = 0xf;
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
	cb.attachmentCount = 1; cb.pAttachments = &cba;
	VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
	ci.stageCount = n; ci.pStages = stages; ci.pVertexInputState = &vi; ci.pInputAssemblyState = &ia;
	ci.pViewportState = &vps; ci.pRasterizationState = &rs; ci.pMultisampleState = &ms; ci.pColorBlendState = &cb;
	ci.layout = layout; ci.renderPass = rp;
	VkPipeline p;
	CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, nullptr, &p));
	return p;
}

struct Expect { int x, y; uint8_t r, g, b; };

int main(int argc, char** argv) {
	if (argc < 3) { fprintf(stderr, "usage: gstest SHADERDIR OUTDIR\n"); return 2; }
	shaderDir = argv[1];
	outDir = argv[2];

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
	app.apiVersion = VK_API_VERSION_1_2;
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
	ici.pApplicationInfo = &app;
	VkInstance inst;
	CHECK(vkCreateInstance(&ici, nullptr, &inst));
	uint32_t count = 1;
	vkEnumeratePhysicalDevices(inst, &count, &phys);
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
	qci.queueCount = 1; qci.pQueuePriorities = &prio;
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
	dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
	CHECK(vkCreateDevice(phys, &dci, nullptr, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	// Color target
	VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
	imci.imageType = VK_IMAGE_TYPE_2D; imci.format = VK_FORMAT_R8G8B8A8_UNORM; imci.extent = { W, H, 1 };
	imci.mipLevels = 1; imci.arrayLayers = 1; imci.samples = VK_SAMPLE_COUNT_1_BIT; imci.tiling = VK_IMAGE_TILING_OPTIMAL;
	imci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
	VkImage img;
	CHECK(vkCreateImage(dev, &imci, nullptr, &img));
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(dev, img, &req);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
	ai.allocationSize = req.size; ai.memoryTypeIndex = memType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	VkDeviceMemory imgMem;
	CHECK(vkAllocateMemory(dev, &ai, nullptr, &imgMem));
	CHECK(vkBindImageMemory(dev, img, imgMem, 0));
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
	ivci.image = img; ivci.viewType = VK_IMAGE_VIEW_TYPE_2D; ivci.format = imci.format;
	ivci.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
	VkImageView view;
	CHECK(vkCreateImageView(dev, &ivci, nullptr, &view));

	VkAttachmentDescription att = {};
	att.format = imci.format; att.samples = VK_SAMPLE_COUNT_1_BIT; att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
	att.storeOp = VK_ATTACHMENT_STORE_OP_STORE; att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
	att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE; att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	att.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription sub = {};
	sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; sub.colorAttachmentCount = 1; sub.pColorAttachments = &ref;
	VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
	rpci.attachmentCount = 1; rpci.pAttachments = &att; rpci.subpassCount = 1; rpci.pSubpasses = &sub;
	VkRenderPass rp;
	CHECK(vkCreateRenderPass(dev, &rpci, nullptr, &rp));
	VkFramebufferCreateInfo fbci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
	fbci.renderPass = rp; fbci.attachmentCount = 1; fbci.pAttachments = &view; fbci.width = W; fbci.height = H; fbci.layers = 1;
	VkFramebuffer fb;
	CHECK(vkCreateFramebuffer(dev, &fbci, nullptr, &fb));

	VkPushConstantRange pcr = { VK_SHADER_STAGE_VERTEX_BIT, 0, 4 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	plci.pushConstantRangeCount = 1; plci.pPushConstantRanges = &pcr;
	VkPipelineLayout layout;
	CHECK(vkCreatePipelineLayout(dev, &plci, nullptr, &layout));

	VkShaderModule vs = shader("sprite.vert.spv"), spriteGS = shader("sprite.geom.spv"), triGS = shader("tri.geom.spv"), fs = shader("color.frag.spv");
	VkPipeline spritePipe = pipeline(rp, layout, vs, spriteGS, fs, VK_PRIMITIVE_TOPOLOGY_POINT_LIST);
	VkPipeline triPipe = pipeline(rp, layout, vs, triGS, fs, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
	static VkPipeline restartPipe = pipeline(rp, layout, vs, shader("restart.geom.spv"), fs, VK_PRIMITIVE_TOPOLOGY_POINT_LIST);
	static VkPipeline pointsPipe = pipeline(rp, layout, vs, shader("points.geom.spv"), fs, VK_PRIMITIVE_TOPOLOGY_POINT_LIST);

	// Four sprite points, then a triangle
	float verts[][6] = {
		{ -0.5f, -0.5f, 1, 0, 0, 1 }, { 0.5f, -0.5f, 0, 1, 0, 1 }, { -0.5f, 0.5f, 0, 0, 1, 1 }, { 0.5f, 0.5f, 1, 1, 1, 1 },
		{ -0.9f, -0.9f, 1, 0, 0, 1 }, { -0.1f, -0.9f, 1, 0, 0, 1 }, { -0.9f, -0.1f, 1, 0, 0, 1 },
	};
	Buffer vb = buffer(sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
	memcpy(vb.map, verts, sizeof(verts));
	uint16_t idx[] = { 3, 2, 1, 0 };
	Buffer ib = buffer(sizeof(idx), VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
	memcpy(ib.map, idx, sizeof(idx));
	Buffer rb = buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
	// Indirect draws: four sprites; sprites 1 and 3 as two draws; indexed indices 2, 1 (points 1 and 2), instanced twice
	uint32_t ind[] = { 4, 1, 0, 0,   1, 1, 1, 0,   1, 1, 3, 0,   2, 2, 1, 0, 0,   1, 2, 2, 0 };
	Buffer indb = buffer(sizeof(ind), VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
	memcpy(indb.map, ind, sizeof(ind));
	static VkBuffer indirectBuf = indb.buf;
	uint32_t one = 1;
	Buffer cntb = buffer(sizeof(one), VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
	memcpy(cntb.map, &one, sizeof(one));
	static VkBuffer countBuf = cntb.buf;

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &cpci, nullptr, &pool));
	VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
	cbai.commandPool = pool; cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cbai.commandBufferCount = 1;
	VkCommandBuffer cmd;
	CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

	struct Test {
		const char* name;
		void (*record)(VkCommandBuffer, VkPipeline, VkPipeline, VkPipelineLayout, VkBuffer);
		std::vector<Expect> expect;
	};
	auto px = [](float ndc) { return int((ndc + 1) * 0.5f * W); };
	std::vector<Test> tests = {
		{ "direct", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			vkCmdDraw(c, 4, 1, 0, 0);
		}, { { px(-0.5f), px(-0.5f), 255, 0, 0 }, { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(-0.5f), px(0.5f), 0, 0, 255 },
		     { px(0.5f), px(0.5f), 255, 255, 255 }, { px(-0.5f) + 20, px(-0.5f), 0, 0, 0 }, { 128, 128, 0, 0, 0 } } },
		{ "indexed", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout, VkBuffer ibuf) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			vkCmdBindIndexBuffer(c, ibuf, 0, VK_INDEX_TYPE_UINT16);
			vkCmdDrawIndexed(c, 3, 1, 0, 0, 0);	// Indices 3, 2, 1
		}, { { px(-0.5f), px(-0.5f), 0, 0, 0 }, { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(-0.5f), px(0.5f), 0, 0, 255 },
		     { px(0.5f), px(0.5f), 255, 255, 255 } } },
		{ "instanced", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout l, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			float shift = 0.4f;
			vkCmdPushConstants(c, l, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &shift);
			vkCmdDraw(c, 1, 3, 2, 0);	// The blue point, three times
		}, { { px(-0.5f), px(0.5f), 0, 0, 255 }, { px(-0.1f), px(0.5f), 0, 0, 255 }, { px(0.3f), px(0.5f), 0, 0, 255 },
		     { px(0.7f), px(0.5f), 0, 0, 0 }, { px(-0.5f), px(-0.5f), 0, 0, 0 } } },
		{ "invocations", [](VkCommandBuffer c, VkPipeline, VkPipeline tp, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, tp);
			vkCmdDraw(c, 3, 1, 4, 0);
		}, { { px(-0.7f), px(-0.7f), 255, 0, 0 }, { px(0.3f), px(-0.7f), 0, 128, 128 }, { px(-0.7f), px(0.5f), 0, 0, 0 } } },
		{ "indirect", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			vkCmdDrawIndirect(c, indirectBuf, 0, 1, 16);
		}, { { px(-0.5f), px(-0.5f), 255, 0, 0 }, { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(-0.5f), px(0.5f), 0, 0, 255 },
		     { px(0.5f), px(0.5f), 255, 255, 255 } } },
		{ "multidraw", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			vkCmdDrawIndirect(c, indirectBuf, 16, 2, 16);
		}, { { px(-0.5f), px(-0.5f), 0, 0, 0 }, { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(-0.5f), px(0.5f), 0, 0, 0 },
		     { px(0.5f), px(0.5f), 255, 255, 255 } } },
		{ "indirectcount", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			vkCmdDrawIndirectCount(c, indirectBuf, 16, countBuf, 0, 2, 16);	// Of sprites 1 and 3, only the first
		}, { { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(0.5f), px(0.5f), 0, 0, 0 }, { px(-0.5f), px(-0.5f), 0, 0, 0 } } },
		{ "indexedindirect", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout l, VkBuffer ibuf) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			float shift = 0.2f;
			vkCmdPushConstants(c, l, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &shift);
			vkCmdBindIndexBuffer(c, ibuf, 0, VK_INDEX_TYPE_UINT16);
			vkCmdDrawIndexedIndirect(c, indirectBuf, 48, 1, 20);	// Indices 2, 1 from index 1, two instances
		}, { { px(-0.5f), px(-0.5f), 0, 0, 0 }, { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(0.7f), px(-0.5f), 0, 255, 0 },
		     { px(-0.5f), px(0.5f), 0, 0, 255 }, { px(-0.3f), px(0.5f), 0, 0, 255 }, { px(0.5f), px(0.5f), 0, 0, 0 } } },
		{ "indexedinstanced", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout l, VkBuffer ibuf) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			float shift = 0.2f;
			vkCmdPushConstants(c, l, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &shift);
			vkCmdBindIndexBuffer(c, ibuf, 0, VK_INDEX_TYPE_UINT16);
			vkCmdDrawIndexed(c, 2, 2, 1, 0, 0);
		}, { { px(-0.5f), px(-0.5f), 0, 0, 0 }, { px(0.5f), px(-0.5f), 0, 255, 0 }, { px(0.7f), px(-0.5f), 0, 255, 0 },
		     { px(-0.5f), px(0.5f), 0, 0, 255 }, { px(-0.3f), px(0.5f), 0, 0, 255 }, { px(0.5f), px(0.5f), 0, 0, 0 } } },
		{ "indirectinstanced", [](VkCommandBuffer c, VkPipeline sp, VkPipeline, VkPipelineLayout l, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, sp);
			float shift = 0.4f;
			vkCmdPushConstants(c, l, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &shift);
			vkCmdDrawIndirect(c, indirectBuf, 68, 1, 16);	// The blue point, twice
		}, { { px(-0.5f), px(0.5f), 0, 0, 255 }, { px(-0.1f), px(0.5f), 0, 0, 255 }, { px(0.3f), px(0.5f), 0, 0, 0 } } },
		{ "restart", [](VkCommandBuffer c, VkPipeline, VkPipeline, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, restartPipe);
			vkCmdDraw(c, 1, 1, 0, 0);	// Red point at -0.5, -0.5
		}, { { px(-0.7f), px(-0.5f), 255, 0, 0 }, { px(-0.3f), px(-0.5f), 255, 0, 0 }, { px(-0.5f), px(-0.5f), 0, 0, 0 } } },
		{ "points", [](VkCommandBuffer c, VkPipeline, VkPipeline, VkPipelineLayout, VkBuffer) {
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pointsPipe);
			vkCmdDraw(c, 2, 1, 0, 0);	// Red and green
		}, { { px(-0.5f), px(-0.3f), 255, 0, 0 }, { px(-0.5f), px(-0.7f), 255, 0, 0 }, { px(0.5f), px(-0.3f), 0, 255, 0 },
		     { px(-0.5f), px(-0.5f), 0, 0, 0 }, { 0, 0, 0, 0, 0 } } },
	};

	int failures = 0;
	for (auto& t : tests) {
		CHECK(vkResetCommandBuffer(cmd, 0));
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CHECK(vkBeginCommandBuffer(cmd, &bi));
		VkClearValue clear = {};
		VkRenderPassBeginInfo rpbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
		rpbi.renderPass = rp; rpbi.framebuffer = fb; rpbi.renderArea = { { 0, 0 }, { W, H } };
		rpbi.clearValueCount = 1; rpbi.pClearValues = &clear;
		vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
		VkDeviceSize off = 0;
		vkCmdBindVertexBuffers(cmd, 0, 1, &vb.buf, &off);
		float zero = 0;
		vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &zero);
		t.record(cmd, spritePipe, triPipe, layout, ib.buf);
		vkCmdEndRenderPass(cmd);
		VkBufferImageCopy copy = {};
		copy.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
		copy.imageExtent = { W, H, 1 };
		vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb.buf, 1, &copy);
		CHECK(vkEndCommandBuffer(cmd));
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
		si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
		CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CHECK(vkQueueWaitIdle(queue));

		const uint8_t* p = (const uint8_t*)rb.map;
		std::string ppm = outDir + "/" + t.name + ".ppm";
		FILE* f = fopen(ppm.c_str(), "wb");
		fprintf(f, "P6 %u %u 255\n", W, H);
		for (uint32_t i = 0; i < W * H; i++) { fwrite(p + i * 4, 1, 3, f); }
		fclose(f);
		int bad = 0;
		for (auto& e : t.expect) {
			const uint8_t* q = p + (e.y * W + e.x) * 4;
			bool ok = abs(q[0] - e.r) < 8 && abs(q[1] - e.g) < 8 && abs(q[2] - e.b) < 8;
			if (!ok) {
				printf("  %s: pixel %d,%d is %u,%u,%u, expected %u,%u,%u\n", t.name, e.x, e.y, q[0], q[1], q[2], e.r, e.g, e.b);
				bad++;
			}
		}
		printf("%s: %s\n", t.name, bad ? "FAIL" : "ok");
		failures += bad != 0;
	}
	vkDeviceWaitIdle(dev);
	return failures;
}
