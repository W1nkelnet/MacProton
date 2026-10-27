/*
 * D3D11 state checks for DXVK on MoltenVK.
 *
 * Draws fullscreen triangles into a 4x4 render target and reads back the
 * result, each case isolating one piece of state that UI rendering relies
 * on: constant buffer contents, alpha blending, texture sampling with a
 * sampler object, and texture alpha used for blending.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 d3d11-blendtest.c -o d3d11-blendtest.exe \
 *          -ld3d11 -ld3dcompiler_47 -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

static const char shader_src[] =
    "Texture2D t0 : register(t0);\n"
    "SamplerState s0 : register(s0);\n"
    "cbuffer c0 : register(b0) { float4 color; float4 mode; };\n"
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "  float2 uv = float2((id << 1) & 2, id & 2);\n"
    "  return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);\n"
    "}\n"
    "float4 ps(float4 pos : SV_Position) : SV_Target {\n"
    "  if (mode.x > 0.5) return t0.Sample(s0, float2(0.5, 0.5)) * color;\n"
    "  return color;\n"
    "}\n";

static ID3D11Device *device;
static ID3D11DeviceContext *ctx;
static ID3D11Texture2D *rt, *staging;
static ID3D11RenderTargetView *rtv;
static ID3D11Buffer *cb;
static int failures;

struct constants { float color[4]; float mode[4]; };

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    if (FAILED(D3DCompile(shader_src, sizeof(shader_src) - 1, NULL, NULL, NULL,
                          entry, target, 0, 0, &blob, &errors)))
    {
        printf("FAIL: D3DCompile(%s): %s\n", entry,
               errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "");
        exit(1);
    }
    return blob;
}

static void draw(const float *clear, const float *color, float mode, ID3D11BlendState *blend)
{
    struct constants c = { { color[0], color[1], color[2], color[3] }, { mode, 0, 0, 0 } };
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)cb, 0, NULL, &c, 0, 0);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
    ID3D11DeviceContext_OMSetBlendState(ctx, blend, NULL, 0xffffffff);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
}

static void check(const char *name, const BYTE *expected)
{
    D3D11_MAPPED_SUBRESOURCE map;
    const BYTE *px;
    int i, ok = 1;

    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)rt);
    ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    px = (const BYTE *)map.pData + 2 * map.RowPitch + 2 * 4;
    for (i = 0; i < 4; i++)
        if (abs(px[i] - expected[i]) > 2) ok = 0;
    printf("%s %-34s got %3u,%3u,%3u,%3u expected %3u,%3u,%3u,%3u\n", ok ? "OK:  " : "FAIL:",
           name, px[0], px[1], px[2], px[3], expected[0], expected[1], expected[2], expected[3]);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    if (!ok) failures++;
}

int main(void)
{
    static const float blue[4] = { 0.0f, 0.0f, 1.0f, 1.0f };
    static const float red_quarter[4] = { 1.0f, 0.0f, 0.0f, 0.25f };
    static const float white[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
    static const float transparent[4] = { 1.0f, 1.0f, 1.0f, 0.0f };
    /* 2x2 texture: green with alpha 0.5 */
    static const DWORD texels[4] = { 0x8000ff00, 0x8000ff00, 0x8000ff00, 0x8000ff00 };
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    D3D11_TEXTURE2D_DESC desc = {0};
    D3D11_BUFFER_DESC cb_desc = {0};
    D3D11_BLEND_DESC blend_desc = {0};
    D3D11_SAMPLER_DESC sampler_desc = {0};
    D3D11_SUBRESOURCE_DATA init = { texels, 8, 0 };
    D3D11_VIEWPORT vp = { 0.0f, 0.0f, 4.0f, 4.0f, 0.0f, 1.0f };
    ID3D11Texture2D *tex;
    ID3D11ShaderResourceView *srv;
    ID3D11SamplerState *sampler;
    ID3D11BlendState *alpha_blend;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3DBlob *vs_blob, *ps_blob;

    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1,
                                 D3D11_SDK_VERSION, &device, NULL, &ctx)))
    {
        printf("FAIL: D3D11CreateDevice\n");
        return 1;
    }

    vs_blob = compile("vs", "vs_5_0");
    ps_blob = compile("ps", "ps_5_0");
    ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vs_blob),
                                    ID3D10Blob_GetBufferSize(vs_blob), NULL, &vs);
    ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_blob),
                                   ID3D10Blob_GetBufferSize(ps_blob), NULL, &ps);

    desc.Width = desc.Height = 4;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &rt);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)rt, NULL, &rtv);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);

    desc.Width = desc.Height = 2;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = 0;
    ID3D11Device_CreateTexture2D(device, &desc, &init, &tex);
    ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)tex, NULL, &srv);

    sampler_desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampler_desc.AddressU = sampler_desc.AddressV = sampler_desc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler_desc.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11Device_CreateSamplerState(device, &sampler_desc, &sampler);

    cb_desc.ByteWidth = sizeof(struct constants);
    cb_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    ID3D11Device_CreateBuffer(device, &cb_desc, NULL, &cb);

    blend_desc.RenderTarget[0].BlendEnable = TRUE;
    blend_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    blend_desc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend_desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    blend_desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    ID3D11Device_CreateBlendState(device, &blend_desc, &alpha_blend);

    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &sampler);

    {
        static const BYTE e1[4] = { 255, 0, 0, 64 };
        draw(blue, red_quarter, 0.0f, NULL);
        check("constant buffer color, no blend", e1);
    }
    {
        static const BYTE e2[4] = { 64, 0, 191, 64 };
        draw(blue, red_quarter, 0.0f, alpha_blend);
        check("alpha blend 25% red over blue", e2);
    }
    {
        static const BYTE e3[4] = { 0, 0, 255, 0 };
        draw(blue, transparent, 0.0f, alpha_blend);
        check("alpha blend fully transparent", e3);
    }
    {
        static const BYTE e4[4] = { 0, 255, 0, 128 };
        draw(blue, white, 1.0f, NULL);
        check("texture sample via sampler", e4);
    }
    {
        static const BYTE e5[4] = { 0, 128, 127, 128 };
        draw(blue, white, 1.0f, alpha_blend);
        check("texture alpha blended over blue", e5);
    }

    printf("%s: %d failure(s)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}
