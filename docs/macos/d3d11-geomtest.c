/*
 * D3D11 geometry checks for DXVK on MoltenVK.
 *
 * Covers what engines like Unity use beyond d3d11-blendtest: vertex buffers
 * with an input layout (float3 position, unorm8 color), 16-bit index buffers,
 * and depth testing with reversed Z (clear to 0, GREATER_EQUAL) on common
 * depth formats. Each case draws into a 4x4 target and reads back a pixel.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 d3d11-geomtest.c -o d3d11-geomtest.exe \
 *          -ld3d11 -ld3dcompiler_47 -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

static const char shader_src[] =
    "struct vsin { float3 pos : POSITION; float4 color : COLOR; };\n"
    "struct vsout { float4 pos : SV_Position; float4 color : COLOR; };\n"
    "vsout vs(vsin i) { vsout o; o.pos = float4(i.pos, 1); o.color = i.color; return o; }\n"
    "float4 ps(vsout i) : SV_Target { return i.color; }\n";

struct vertex { float pos[3]; DWORD color; };

static ID3D11Device *device;
static ID3D11DeviceContext *ctx;
static ID3D11Texture2D *rt, *staging;
static ID3D11RenderTargetView *rtv;
static int failures;

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

static ID3D11Buffer *create_buffer(UINT bind, const void *data, UINT size)
{
    D3D11_BUFFER_DESC desc = { size, D3D11_USAGE_DEFAULT, bind };
    D3D11_SUBRESOURCE_DATA init = { data };
    ID3D11Buffer *buffer;
    ID3D11Device_CreateBuffer(device, &desc, &init, &buffer);
    return buffer;
}

/* Fullscreen triangle at the given depth, ABGR color */
static ID3D11Buffer *fullscreen_vb(float z, DWORD color)
{
    struct vertex v[3] =
    {
        { { -1.0f,  3.0f, z }, color },
        { {  3.0f, -1.0f, z }, color },
        { { -1.0f, -1.0f, z }, color },
    };
    return create_buffer(D3D11_BIND_VERTEX_BUFFER, v, sizeof(v));
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
    printf("%s %-40s got %3u,%3u,%3u,%3u expected %3u,%3u,%3u,%3u\n", ok ? "OK:  " : "FAIL:",
           name, px[0], px[1], px[2], px[3], expected[0], expected[1], expected[2], expected[3]);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    if (!ok) failures++;
}

static void depth_case(DXGI_FORMAT format, const char *name)
{
    static const float blue[4] = { 0.0f, 0.0f, 1.0f, 1.0f };
    static const BYTE green[4] = { 0, 255, 0, 255 };
    D3D11_TEXTURE2D_DESC desc = {0};
    D3D11_DEPTH_STENCIL_DESC ds_desc = {0};
    ID3D11Texture2D *depth;
    ID3D11DepthStencilView *dsv;
    ID3D11DepthStencilState *ds_state;
    ID3D11Buffer *near_vb = fullscreen_vb(0.75f, 0xff00ff00), *far_vb = fullscreen_vb(0.25f, 0xff0000ff);
    UINT stride = sizeof(struct vertex), offset = 0;
    char label[64];

    desc.Width = desc.Height = 4;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    if (FAILED(ID3D11Device_CreateTexture2D(device, &desc, NULL, &depth)))
    {
        printf("FAIL: create depth %s\n", name);
        failures++;
        return;
    }
    ID3D11Device_CreateDepthStencilView(device, (ID3D11Resource *)depth, NULL, &dsv);

    /* Reversed Z: larger is closer */
    ds_desc.DepthEnable = TRUE;
    ds_desc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    ds_desc.DepthFunc = D3D11_COMPARISON_GREATER_EQUAL;
    ID3D11Device_CreateDepthStencilState(device, &ds_desc, &ds_state);

    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, blue);
    ID3D11DeviceContext_ClearDepthStencilView(ctx, dsv, D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 0.0f, 0);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, dsv);
    ID3D11DeviceContext_OMSetDepthStencilState(ctx, ds_state, 0);
    /* green near triangle first, red far triangle must then fail the test */
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &near_vb, &stride, &offset);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &far_vb, &stride, &offset);
    ID3D11DeviceContext_Draw(ctx, 3, 0);

    snprintf(label, sizeof(label), "reversed Z depth test (%s)", name);
    check(label, green);

    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_OMSetDepthStencilState(ctx, NULL, 0);
}

int main(void)
{
    static const float blue[4] = { 0.0f, 0.0f, 1.0f, 1.0f };
    static const D3D11_INPUT_ELEMENT_DESC layout[] =
    {
        { "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0,  D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "COLOR",    0, DXGI_FORMAT_R8G8B8A8_UNORM,  0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    static const WORD indices[] = { 0, 0, 1, 2 };
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    D3D11_TEXTURE2D_DESC desc = {0};
    D3D11_VIEWPORT vp = { 0.0f, 0.0f, 4.0f, 4.0f, 0.0f, 1.0f };
    ID3D11InputLayout *input_layout;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3D11Buffer *vb, *ib;
    ID3DBlob *vs_blob, *ps_blob;
    UINT stride = sizeof(struct vertex), offset = 0;

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
    ID3D11Device_CreateInputLayout(device, layout, 2, ID3D10Blob_GetBufferPointer(vs_blob),
                                   ID3D10Blob_GetBufferSize(vs_blob), &input_layout);

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

    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(ctx, input_layout);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);

    vb = fullscreen_vb(0.5f, 0x80ff8040); /* ABGR: r=0x40 g=0x80 b=0xff a=0x80 */
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb, &stride, &offset);
    {
        static const BYTE e[4] = { 0x40, 0x80, 0xff, 0x80 };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, blue);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        check("vertex buffer + input layout", e);
    }
    {
        static const BYTE e[4] = { 0x40, 0x80, 0xff, 0x80 };
        /* index buffer at a 2-byte offset, as engines do with packed buffers */
        ib = create_buffer(D3D11_BIND_INDEX_BUFFER, indices, sizeof(indices));
        ID3D11DeviceContext_IASetIndexBuffer(ctx, ib, DXGI_FORMAT_R16_UINT, 2);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, blue);
        ID3D11DeviceContext_DrawIndexed(ctx, 3, 0, 0);
        check("16-bit index buffer at offset 2", e);
    }
    {
        static const BYTE e[4] = { 0x40, 0x80, 0xff, 0x80 };
        /* vertex buffer bound at a non-zero offset */
        struct vertex padded[4] = { { { 0 } } };
        ID3D11Buffer *vb2;
        UINT off2 = sizeof(struct vertex);
        padded[1] = (struct vertex){ { -1.0f,  3.0f, 0.5f }, 0x80ff8040 };
        padded[2] = (struct vertex){ {  3.0f, -1.0f, 0.5f }, 0x80ff8040 };
        padded[3] = (struct vertex){ { -1.0f, -1.0f, 0.5f }, 0x80ff8040 };
        vb2 = create_buffer(D3D11_BIND_VERTEX_BUFFER, padded, sizeof(padded));
        ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb2, &stride, &off2);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, blue);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        check("vertex buffer at offset 16", e);
    }

    depth_case(DXGI_FORMAT_D24_UNORM_S8_UINT, "D24S8");
    depth_case(DXGI_FORMAT_D32_FLOAT, "D32");
    depth_case(DXGI_FORMAT_D32_FLOAT_S8X24_UINT, "D32S8");
    depth_case(DXGI_FORMAT_D16_UNORM, "D16");

    printf("%s: %d failure(s)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}
