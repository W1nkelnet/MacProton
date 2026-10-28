/*
 * Direct3D 12 check for vkd3d-proton on MoltenVK: creates a device, clears a
 * texture, draws a triangle with compiled shaders, reads both back and
 * presents frames in a window.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 d3d12-test.c -o d3d12-test.exe -ld3d12 -ldxgi -ld3dcompiler -luuid
 * usage: d3d12-test.exe [frames]
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#define W 256
#define H 256
#define CHECK(hr, what) do { if (FAILED(hr)) { printf("FAIL: %s (0x%08lx)\n", what, (unsigned long)(hr)); exit(1); } } while (0)

static ID3D12Device *device;
static ID3D12CommandQueue *queue;
static ID3D12CommandAllocator *allocator;
static ID3D12GraphicsCommandList *list;
static ID3D12Fence *fence;
static UINT64 fence_value;
static HANDLE fence_event;

static void wait_gpu(void)
{
    CHECK(ID3D12CommandQueue_Signal(queue, fence, ++fence_value), "Signal");
    if (ID3D12Fence_GetCompletedValue(fence) < fence_value)
    {
        ID3D12Fence_SetEventOnCompletion(fence, fence_value, fence_event);
        WaitForSingleObject(fence_event, 10000);
    }
}

static void submit(void)
{
    CHECK(ID3D12GraphicsCommandList_Close(list), "Close");
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
    wait_gpu();
    ID3D12CommandAllocator_Reset(allocator);
    ID3D12GraphicsCommandList_Reset(list, allocator, NULL);
}

static void barrier(ID3D12Resource *res, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

static ID3D12Resource *create_resource(D3D12_HEAP_TYPE heap_type, const D3D12_RESOURCE_DESC *desc,
                                       D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear)
{
    D3D12_HEAP_PROPERTIES heap = { heap_type };
    ID3D12Resource *res;
    CHECK(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, desc, state, clear,
                                               &IID_ID3D12Resource, (void **)&res), "CreateCommittedResource");
    return res;
}

/* Copies the render target to a readback buffer and returns the pixel at x, y as RGBA8. */
static DWORD read_pixel(ID3D12Resource *target, int x, int y)
{
    D3D12_RESOURCE_DESC buf = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, W * H * 4, 1, 1, 1, DXGI_FORMAT_UNKNOWN,
                                { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR };
    ID3D12Resource *readback = create_resource(D3D12_HEAP_TYPE_READBACK, &buf, D3D12_RESOURCE_STATE_COPY_DEST, NULL);
    D3D12_TEXTURE_COPY_LOCATION dst = { readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT };
    D3D12_TEXTURE_COPY_LOCATION src = { target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
    D3D12_RANGE range = { 0, W * H * 4 };
    DWORD *data, pixel;

    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    dst.PlacedFootprint.Footprint.Width = W;
    dst.PlacedFootprint.Footprint.Height = H;
    dst.PlacedFootprint.Footprint.Depth = 1;
    dst.PlacedFootprint.Footprint.RowPitch = W * 4;
    barrier(target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    barrier(target, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET);
    submit();
    CHECK(ID3D12Resource_Map(readback, 0, &range, (void **)&data), "Map");
    pixel = data[y * W + x];
    ID3D12Resource_Unmap(readback, 0, NULL);
    ID3D12Resource_Release(readback);
    return pixel;
}

static const char shader[] =
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "    float2 p[3] = { float2(-1, -1), float2(0, 1), float2(1, -1) };\n"
    "    return float4(p[id], 0, 1);\n"
    "}\n"
    "float4 ps() : SV_Target { return float4(0.25, 0.5, 0.75, 1); }\n";

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
    int frames = argc > 1 ? atoi(argv[1]) : 120, i;
    D3D12_COMMAND_QUEUE_DESC qdesc = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    D3D12_FEATURE_DATA_D3D12_OPTIONS options = { 0 };
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_12_2, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0,
                                   D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { ARRAYSIZE(levels), levels };
    DWORD pixel;

    CHECK(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device), "D3D12CreateDevice");
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options));
    printf("OK:   Device created, max feature level 0x%x, resource binding tier %d, tiled resources tier %d\n",
           fl.MaxSupportedFeatureLevel, options.ResourceBindingTier, options.TiledResourcesTier);
    fflush(stdout);

    CHECK(ID3D12Device_CreateCommandQueue(device, &qdesc, &IID_ID3D12CommandQueue, (void **)&queue), "CreateCommandQueue");
    CHECK(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
                                              (void **)&allocator), "CreateCommandAllocator");
    CHECK(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                         &IID_ID3D12GraphicsCommandList, (void **)&list), "CreateCommandList");
    CHECK(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence), "CreateFence");
    fence_event = CreateEventA(NULL, FALSE, FALSE, NULL);

    /* Offscreen render target with an RTV */
    D3D12_RESOURCE_DESC tex = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, W, H, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM,
                                { 1, 0 }, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET };
    ID3D12Resource *target = create_resource(D3D12_HEAP_TYPE_DEFAULT, &tex, D3D12_RESOURCE_STATE_RENDER_TARGET, NULL);
    D3D12_DESCRIPTOR_HEAP_DESC hdesc = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 4 };
    ID3D12DescriptorHeap *rtv_heap;
    CHECK(ID3D12Device_CreateDescriptorHeap(device, &hdesc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap), "CreateDescriptorHeap");
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);
    ID3D12Device_CreateRenderTargetView(device, target, NULL, rtv);

    /* 1. Clear */
    {
        const float color[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, color, 0, NULL);
        pixel = read_pixel(target, 10, 10);
        printf("%s Clear: pixel %08lx, expected ff0000ff\n", pixel == 0xff0000ff ? "OK:  " : "FAIL:", (unsigned long)pixel);
        fflush(stdout);
    }

    /* 2. Triangle */
    {
        D3D12_ROOT_SIGNATURE_DESC rs_desc = { 0 };
        ID3DBlob *rs_blob, *vs = compile("vs", "vs_5_0"), *ps = compile("ps", "ps_5_0");
        ID3D12RootSignature *rs;
        ID3D12PipelineState *pso;
        D3D12_GRAPHICS_PIPELINE_STATE_DESC p = { 0 };
        D3D12_VIEWPORT vp = { 0, 0, W, H, 0, 1 };
        D3D12_RECT scissor = { 0, 0, W, H };
        const float black[4] = { 0, 0, 0, 1 };

        CHECK(D3D12SerializeRootSignature(&rs_desc, D3D_ROOT_SIGNATURE_VERSION_1, &rs_blob, NULL), "SerializeRootSignature");
        CHECK(ID3D12Device_CreateRootSignature(device, 0, ID3D10Blob_GetBufferPointer(rs_blob), ID3D10Blob_GetBufferSize(rs_blob),
                                               &IID_ID3D12RootSignature, (void **)&rs), "CreateRootSignature");
        p.pRootSignature = rs;
        p.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
        p.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
        p.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(ps);
        p.PS.BytecodeLength = ID3D10Blob_GetBufferSize(ps);
        p.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        p.SampleMask = ~0u;
        p.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        p.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        p.RasterizerState.DepthClipEnable = TRUE;
        p.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        p.NumRenderTargets = 1;
        p.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        p.SampleDesc.Count = 1;
        CHECK(ID3D12Device_CreateGraphicsPipelineState(device, &p, &IID_ID3D12PipelineState, (void **)&pso), "CreateGraphicsPipelineState");

        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, black, 0, NULL);
        ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
        ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rs);
        ID3D12GraphicsCommandList_SetPipelineState(list, pso);
        ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp);
        ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &scissor);
        ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
        pixel = read_pixel(target, W / 2, H / 2);
        printf("%s Triangle: pixel %08lx, expected ffbf8040\n",
               (pixel & 0xfffefefe) == (0xffbf8040 & 0xfffefefe) ? "OK:  " : "FAIL:", (unsigned long)pixel);
        fflush(stdout);
    }

    /* 3. Present */
    {
        HWND hwnd = CreateWindowA("STATIC", "d3d12-test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 480,
                                  NULL, NULL, NULL, NULL);
        IDXGIFactory4 *factory;
        IDXGISwapChain1 *swapchain1;
        IDXGISwapChain3 *swapchain;
        DXGI_SWAP_CHAIN_DESC1 sd = { 640, 480, DXGI_FORMAT_R8G8B8A8_UNORM, FALSE, { 1, 0 },
                                     DXGI_USAGE_RENDER_TARGET_OUTPUT, 3, DXGI_SCALING_STRETCH,
                                     DXGI_SWAP_EFFECT_FLIP_DISCARD };
        ID3D12Resource *buffers[3];

        CHECK(CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory), "CreateDXGIFactory1");
        CHECK(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &swapchain1),
              "CreateSwapChainForHwnd");
        IDXGISwapChain1_QueryInterface(swapchain1, &IID_IDXGISwapChain3, (void **)&swapchain);
        for (i = 0; i < 3; i++)
        {
            D3D12_CPU_DESCRIPTOR_HANDLE h = rtv;
            h.ptr += (i + 1) * ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
            IDXGISwapChain3_GetBuffer(swapchain, i, &IID_ID3D12Resource, (void **)&buffers[i]);
            ID3D12Device_CreateRenderTargetView(device, buffers[i], NULL, h);
        }
        for (i = 0; i < frames; i++)
        {
            UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(swapchain);
            D3D12_CPU_DESCRIPTOR_HANDLE h = rtv;
            float color[4] = { (i % 60) / 60.0f, 0.2f, 0.6f, 1.0f };
            MSG msg;

            while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
            h.ptr += (index + 1) * ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
            barrier(buffers[index], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
            ID3D12GraphicsCommandList_ClearRenderTargetView(list, h, color, 0, NULL);
            barrier(buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
            CHECK(ID3D12GraphicsCommandList_Close(list), "Close");
            ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
            CHECK(IDXGISwapChain3_Present(swapchain, 1, 0), "Present");
            wait_gpu();
            ID3D12CommandAllocator_Reset(allocator);
            ID3D12GraphicsCommandList_Reset(list, allocator, NULL);
        }
        printf("OK:   Presented %d frames\n", frames);
    }
    return 0;
}
