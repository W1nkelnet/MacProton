/*
 * Direct3D 12 check of GPU-counted indirect draws, as Unreal's distance field shadows cull objects
 * into tiles: each frame clears a typed UAV of draw arguments, a compute shader counts instances into
 * it with InterlockedAdd, and ExecuteIndirect draws that many cubes without render targets, whose
 * pixel shader counts pixels with another atomic. The counts must be the same in every frame.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 d3d12-uavcount.c -o d3d12-uavcount.exe -ld3d12 -ld3dcompiler -luuid
 * usage: d3d12-uavcount.exe [frames] [skip]
 * skip is a mask of steps to leave out, to narrow down failures: 1 clears, 2 the compute shader,
 * 4 ExecuteIndirect (drawing 128 instances directly instead), 8 the draw, 16 the pixel shader atomic,
 * 32 drawing without render target (using one), 64 the index buffer (drawing non-indexed directly).
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(hr, what) do { if (FAILED(hr)) { printf("FAIL: %s (0x%08lx)\n", what, (unsigned long)(hr)); exit(1); } } while (0)

static ID3D12Device *device;
static ID3D12CommandQueue *queue;
static ID3D12CommandAllocator *allocator;
static ID3D12GraphicsCommandList *list;
static ID3D12Fence *fence;
static UINT64 fence_value;
static HANDLE fence_event;

static void submit(void)
{
    CHECK(ID3D12GraphicsCommandList_Close(list), "Close");
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
    CHECK(ID3D12CommandQueue_Signal(queue, fence, ++fence_value), "Signal");
    if (ID3D12Fence_GetCompletedValue(fence) < fence_value)
    {
        ID3D12Fence_SetEventOnCompletion(fence, fence_value, fence_event);
        if (WaitForSingleObject(fence_event, 10000) != WAIT_OBJECT_0)
        {
            printf("FAIL: GPU did not finish\n");
            exit(1);
        }
    }
    ID3D12CommandAllocator_Reset(allocator);
    ID3D12GraphicsCommandList_Reset(list, allocator, NULL);
}

static void transition(ID3D12Resource *res, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

static void uav_barrier(ID3D12Resource *res)
{
    D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_UAV };
    b.UAV.pResource = res;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

static ID3D12Resource *create_buffer(D3D12_HEAP_TYPE heap_type, UINT64 size, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state)
{
    D3D12_HEAP_PROPERTIES heap = { heap_type };
    D3D12_RESOURCE_DESC desc = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, size, 1, 1, 1, DXGI_FORMAT_UNKNOWN,
                                 { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, flags };
    ID3D12Resource *res;
    CHECK(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &desc, state, NULL,
                                               &IID_ID3D12Resource, (void **)&res), "CreateCommittedResource");
    return res;
}

static const char shader[] =
    "RWBuffer<uint> args : register(u0);\n"
    "RWBuffer<uint> pixels : register(u1);\n"
    "[numthreads(64, 1, 1)] void cs(uint id : SV_DispatchThreadID) {\n"
    "    if (id == 0) args[0] = 36;\n"
    "    uint old;\n"
    "    InterlockedAdd(args[1], 1, old);\n"
    "}\n"
    "float4 vs(uint v : SV_VertexID, uint i : SV_InstanceID) : SV_Position {\n"
    "    float3 p = float3(v & 1, (v >> 1) & 1, (v >> 2) & 1) * 2 - 1;\n"
    "    return float4(p.xy * 0.02 + float2(i % 16, i / 16) * 0.1 - 0.8, 0.5, 1);\n"
    "}\n"
    "void ps() { uint old; InterlockedAdd(pixels[0], 1, old); }\n"
    "float4 ps_plain() : SV_Target { return 1; }\n";

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob, *errors = NULL;
    if (FAILED(D3DCompile(shader, sizeof(shader) - 1, NULL, NULL, NULL, entry, target, 0, 0, &blob, &errors)))
    {
        printf("FAIL: compile %s: %s\n", entry, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "?");
        exit(1);
    }
    return blob;
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 10, skip = argc > 2 ? atoi(argv[2]) : 0, failures = 0, f;
    D3D12_COMMAND_QUEUE_DESC queue_desc = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE };
    D3D12_DESCRIPTOR_HEAP_DESC cpu_heap_desc = { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2, D3D12_DESCRIPTOR_HEAP_FLAG_NONE };
    D3D12_DESCRIPTOR_RANGE range = { D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 2, 0, 0, 0 };
    D3D12_ROOT_PARAMETER param = { D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE };
    D3D12_ROOT_SIGNATURE_DESC rs_desc = { 1, &param, 0, NULL, D3D12_ROOT_SIGNATURE_FLAG_NONE };
    D3D12_INDIRECT_ARGUMENT_DESC arg_desc = { D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED };
    D3D12_COMMAND_SIGNATURE_DESC sig_desc = { sizeof(D3D12_DRAW_INDEXED_ARGUMENTS), 1, &arg_desc };
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav = { DXGI_FORMAT_R32_UINT, D3D12_UAV_DIMENSION_BUFFER };
    D3D12_COMPUTE_PIPELINE_STATE_DESC cs_desc = { 0 };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gfx_desc = { 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE gpu_heap_cpu, cpu_heap_cpu, h;
    D3D12_GPU_DESCRIPTOR_HANDLE gpu_heap_gpu, g;
    ID3D12DescriptorHeap *heap, *cpu_heap;
    ID3D12RootSignature *root;
    ID3D12CommandSignature *signature;
    ID3D12PipelineState *cs_pso, *gfx_pso;
    ID3D12Resource *args, *pixels, *indices, *readback, *target = NULL;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = { 0 };
    ID3DBlob *blob, *cs, *vs, *ps;
    D3D12_INDEX_BUFFER_VIEW ibv;
    D3D12_VIEWPORT viewport = { 0, 0, 64, 64, 0, 1 };
    D3D12_RECT scissor = { 0, 0, 64, 64 };
    static const UINT clear_zero[4] = { 0 };
    static const UINT16 cube[36] = { 0,1,2, 2,1,3, 4,6,5, 5,6,7, 0,2,4, 4,2,6, 1,5,3, 3,5,7, 0,4,1, 1,4,5, 2,3,6, 6,3,7 };
    UINT inc, *data, first_pixels = 0;
    D3D12_RANGE read_range = { 0, 32 };
    void *map;

    CHECK(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device), "D3D12CreateDevice");
    CHECK(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue), "CreateCommandQueue");
    CHECK(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&allocator), "CreateCommandAllocator");
    CHECK(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list), "CreateCommandList");
    CHECK(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence), "CreateFence");
    fence_event = CreateEventA(NULL, FALSE, FALSE, NULL);

    CHECK(ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&heap), "CreateDescriptorHeap");
    CHECK(ID3D12Device_CreateDescriptorHeap(device, &cpu_heap_desc, &IID_ID3D12DescriptorHeap, (void **)&cpu_heap), "CreateDescriptorHeap");
    gpu_heap_cpu = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    gpu_heap_gpu = ID3D12DescriptorHeap_GetGPUDescriptorHandleForHeapStart(heap);
    cpu_heap_cpu = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(cpu_heap);
    inc = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

    args = create_buffer(D3D12_HEAP_TYPE_DEFAULT, 256, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    pixels = create_buffer(D3D12_HEAP_TYPE_DEFAULT, 256, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    indices = create_buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof(cube), D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_GENERIC_READ);
    readback = create_buffer(D3D12_HEAP_TYPE_READBACK, 64, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    CHECK(ID3D12Resource_Map(indices, 0, NULL, &map), "Map");
    memcpy(map, cube, sizeof(cube));
    ID3D12Resource_Unmap(indices, 0, NULL);
    ibv.BufferLocation = ID3D12Resource_GetGPUVirtualAddress(indices);
    ibv.SizeInBytes = sizeof(cube);
    ibv.Format = DXGI_FORMAT_R16_UINT;

    uav.Buffer.NumElements = 64;
    for (int i = 0; i < 2; i++)
    {
        h.ptr = gpu_heap_cpu.ptr + i * inc;
        ID3D12Device_CreateUnorderedAccessView(device, i ? pixels : args, NULL, &uav, h);
        h.ptr = cpu_heap_cpu.ptr + i * inc;
        ID3D12Device_CreateUnorderedAccessView(device, i ? pixels : args, NULL, &uav, h);
    }

    param.DescriptorTable.NumDescriptorRanges = 1;
    param.DescriptorTable.pDescriptorRanges = &range;
    param.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    CHECK(D3D12SerializeRootSignature(&rs_desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, NULL), "D3D12SerializeRootSignature");
    CHECK(ID3D12Device_CreateRootSignature(device, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob),
                                           &IID_ID3D12RootSignature, (void **)&root), "CreateRootSignature");
    CHECK(ID3D12Device_CreateCommandSignature(device, &sig_desc, NULL, &IID_ID3D12CommandSignature, (void **)&signature), "CreateCommandSignature");

    cs = compile("cs", "cs_5_0");
    vs = compile("vs", "vs_5_0");
    ps = compile(skip & 16 ? "ps_plain" : "ps", "ps_5_0");
    cs_desc.pRootSignature = root;
    cs_desc.CS.pShaderBytecode = ID3D10Blob_GetBufferPointer(cs);
    cs_desc.CS.BytecodeLength = ID3D10Blob_GetBufferSize(cs);
    CHECK(ID3D12Device_CreateComputePipelineState(device, &cs_desc, &IID_ID3D12PipelineState, (void **)&cs_pso), "CreateComputePipelineState");
    gfx_desc.pRootSignature = root;
    gfx_desc.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
    gfx_desc.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
    gfx_desc.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(ps);
    gfx_desc.PS.BytecodeLength = ID3D10Blob_GetBufferSize(ps);
    gfx_desc.SampleMask = ~0u;
    gfx_desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gfx_desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gfx_desc.RasterizerState.DepthClipEnable = TRUE;
    gfx_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gfx_desc.NumRenderTargets = skip & 32 ? 1 : 0;
    gfx_desc.RTVFormats[0] = skip & 32 ? DXGI_FORMAT_R8G8B8A8_UNORM : DXGI_FORMAT_UNKNOWN;
    gfx_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    if (skip & 32)
    {
        D3D12_HEAP_PROPERTIES rt_heap = { D3D12_HEAP_TYPE_DEFAULT };
        D3D12_RESOURCE_DESC rt_desc = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, 64, 64, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM,
                                        { 1, 0 }, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET };
        D3D12_DESCRIPTOR_HEAP_DESC rtv_desc = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1 };
        ID3D12DescriptorHeap *rtv_heap;
        CHECK(ID3D12Device_CreateCommittedResource(device, &rt_heap, D3D12_HEAP_FLAG_NONE, &rt_desc, D3D12_RESOURCE_STATE_RENDER_TARGET,
                                                   NULL, &IID_ID3D12Resource, (void **)&target), "CreateCommittedResource");
        CHECK(ID3D12Device_CreateDescriptorHeap(device, &rtv_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap), "CreateDescriptorHeap");
        rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);
        ID3D12Device_CreateRenderTargetView(device, target, NULL, rtv);
    }
    gfx_desc.SampleDesc.Count = 1;
    CHECK(ID3D12Device_CreateGraphicsPipelineState(device, &gfx_desc, &IID_ID3D12PipelineState, (void **)&gfx_pso), "CreateGraphicsPipelineState");

    for (f = 0; f < frames; f++)
    {
        ID3D12GraphicsCommandList_SetDescriptorHeaps(list, 1, &heap);
        g = gpu_heap_gpu;
        h = cpu_heap_cpu;
        if (!(skip & 1))
        {
            ID3D12GraphicsCommandList_ClearUnorderedAccessViewUint(list, g, h, args, clear_zero, 0, NULL);
            g.ptr += inc;
            h.ptr += inc;
            ID3D12GraphicsCommandList_ClearUnorderedAccessViewUint(list, g, h, pixels, clear_zero, 0, NULL);
        }
        uav_barrier(args);
        uav_barrier(pixels);

        ID3D12GraphicsCommandList_SetPipelineState(list, cs_pso);
        ID3D12GraphicsCommandList_SetComputeRootSignature(list, root);
        ID3D12GraphicsCommandList_SetComputeRootDescriptorTable(list, 0, gpu_heap_gpu);
        if (!(skip & 2))
            ID3D12GraphicsCommandList_Dispatch(list, 2, 1, 1);
        transition(args, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT);

        ID3D12GraphicsCommandList_SetPipelineState(list, gfx_pso);
        ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, root);
        ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(list, 0, gpu_heap_gpu);
        if (target)
            ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
        else
            ID3D12GraphicsCommandList_OMSetRenderTargets(list, 0, NULL, FALSE, NULL);
        ID3D12GraphicsCommandList_RSSetViewports(list, 1, &viewport);
        ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &scissor);
        ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D12GraphicsCommandList_IASetIndexBuffer(list, &ibv);
        if (skip & 8)
            ;
        else if (skip & 64)
            ID3D12GraphicsCommandList_DrawInstanced(list, 36, 128, 0, 0);
        else if (skip & 4)
            ID3D12GraphicsCommandList_DrawIndexedInstanced(list, 36, 128, 0, 0, 0);
        else
            ID3D12GraphicsCommandList_ExecuteIndirect(list, signature, 1, args, 0, NULL, 0);
        transition(args, D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT, D3D12_RESOURCE_STATE_COPY_SOURCE);
        transition(pixels, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
        ID3D12GraphicsCommandList_CopyBufferRegion(list, readback, 0, args, 0, 20);
        ID3D12GraphicsCommandList_CopyBufferRegion(list, readback, 32, pixels, 0, 4);
        transition(args, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        transition(pixels, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        submit();

        read_range.End = 64;
        CHECK(ID3D12Resource_Map(readback, 0, &read_range, (void **)&data), "Map");
        if (!f) first_pixels = data[8];
        printf("frame %d: args %u %u %u %u %u, pixels %u\n", f, data[0], data[1], data[2], data[3], data[4], data[8]);
        if (data[0] != 36 || data[1] != 128 || !data[8] || data[8] != first_pixels) failures++;
        ID3D12Resource_Unmap(readback, 0, NULL);
    }
    printf(failures ? "FAIL: %d frames differ\n" : "ok\n", failures);
    return failures != 0;
}
