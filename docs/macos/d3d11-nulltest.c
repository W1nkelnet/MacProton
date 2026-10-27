/*
 * Minimal D3D11 check for DXVK on MoltenVK.
 *
 * Renders a fullscreen triangle whose pixel shader reads from an unbound
 * texture and an unbound constant buffer. D3D requires both to read as
 * zero, which on MoltenVK depends on DxvkNullResources. The result is read
 * back and compared, then a swapchain presents a few frames (default 120,
 * or the number given as first argument).
 *
 * Build: x86_64-w64-mingw32-gcc -O2 d3d11-nulltest.c -o d3d11-nulltest.exe \
 *          -ld3d11 -ldxgi -ld3dcompiler_47 -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>

static const char shader_src[] =
    "Texture2D t0 : register(t0);\n"
    "cbuffer c0 : register(b0) { float4 k; };\n"
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "  float2 uv = float2((id << 1) & 2, id & 2);\n"
    "  return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);\n"
    "}\n"
    "float4 ps(float4 pos : SV_Position) : SV_Target {\n"
    "  return t0.Load(int3(0, 0, 0)) + k + float4(0.25, 0.5, 0.75, 1.0);\n"
    "}\n";

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(shader_src, sizeof(shader_src) - 1, NULL, NULL, NULL,
                            entry, target, 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("FAIL: D3DCompile(%s) hr %#lx: %s\n", entry, hr,
               errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "");
        return NULL;
    }
    return blob;
}

int main(int argc, char **argv)
{
    DXGI_SWAP_CHAIN_DESC sc_desc = {0};
    D3D11_TEXTURE2D_DESC tex_desc = {0};
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0, got_level;
    ID3D11Device *device;
    ID3D11DeviceContext *ctx;
    IDXGISwapChain *swapchain;
    ID3D11Texture2D *rt, *staging, *backbuffer;
    ID3D11RenderTargetView *rtv, *bb_rtv;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3DBlob *vs_blob, *ps_blob;
    D3D11_VIEWPORT vp = { 0.0f, 0.0f, 64.0f, 64.0f, 0.0f, 1.0f };
    D3D11_MAPPED_SUBRESOURCE map;
    const float clear[4] = { 1.0f, 0.0f, 1.0f, 1.0f };
    const BYTE expected[4] = { 64, 128, 191, 255 };
    BYTE *px;
    HWND window;
    HRESULT hr;
    int i, ok = 1, frames = argc > 1 ? atoi(argv[1]) : 120;

    window = CreateWindowA("static", "DXVK on MoltenVK", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                           100, 100, 320, 240, NULL, NULL, NULL, NULL);

    sc_desc.BufferDesc.Width = 320;
    sc_desc.BufferDesc.Height = 240;
    sc_desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sc_desc.SampleDesc.Count = 1;
    sc_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sc_desc.BufferCount = 2;
    sc_desc.OutputWindow = window;
    sc_desc.Windowed = TRUE;
    sc_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1,
                                       D3D11_SDK_VERSION, &sc_desc, &swapchain, &device,
                                       &got_level, &ctx);
    if (FAILED(hr))
    {
        printf("FAIL: D3D11CreateDeviceAndSwapChain hr %#lx\n", hr);
        return 1;
    }
    printf("OK:   Device created, feature level %#x\n", got_level);

    if (!(vs_blob = compile("vs", "vs_5_0")) || !(ps_blob = compile("ps", "ps_5_0")))
        return 1;
    ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vs_blob),
                                    ID3D10Blob_GetBufferSize(vs_blob), NULL, &vs);
    ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_blob),
                                   ID3D10Blob_GetBufferSize(ps_blob), NULL, &ps);

    tex_desc.Width = 64;
    tex_desc.Height = 64;
    tex_desc.MipLevels = 1;
    tex_desc.ArraySize = 1;
    tex_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    tex_desc.SampleDesc.Count = 1;
    tex_desc.Usage = D3D11_USAGE_DEFAULT;
    tex_desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Device_CreateTexture2D(device, &tex_desc, NULL, &rt);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)rt, NULL, &rtv);

    tex_desc.Usage = D3D11_USAGE_STAGING;
    tex_desc.BindFlags = 0;
    tex_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(device, &tex_desc, NULL, &staging);

    /* Draw with t0 and b0 deliberately left unbound */
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)rt);

    hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr))
    {
        printf("FAIL: Map hr %#lx\n", hr);
        return 1;
    }
    px = (BYTE *)map.pData + 32 * map.RowPitch + 32 * 4;
    for (i = 0; i < 4; i++)
        if (abs(px[i] - expected[i]) > 1) ok = 0;
    printf("%s Unbound texture/cbuffer read: pixel %u,%u,%u,%u, expected %u,%u,%u,%u\n",
           ok ? "OK:  " : "FAIL:", px[0], px[1], px[2], px[3],
           expected[0], expected[1], expected[2], expected[3]);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);

    /* Present a few frames through the swapchain */
    IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &bb_rtv);
    vp.Width = 320.0f;
    vp.Height = 240.0f;
    for (i = 0; i < frames; i++)
    {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, bb_rtv, clear);
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &bb_rtv, NULL);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        if (FAILED(hr = IDXGISwapChain_Present(swapchain, 1, 0)))
        {
            printf("FAIL: Present hr %#lx in frame %d\n", hr, i);
            return 1;
        }
    }
    printf("OK:   Presented %d frames\n", frames);

    IDXGISwapChain_Release(swapchain);
    ID3D11DeviceContext_Release(ctx);
    ID3D11Device_Release(device);
    DestroyWindow(window);
    return ok ? 0 : 1;
}
