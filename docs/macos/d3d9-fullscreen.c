/*
 * Direct3D 9 full-screen check, as old games start: a full-screen device at
 * 640x480, 60 presents, GetFrontBufferData. Writes each step to
 * d3d9-fullscreen.txt, so a hang shows where it stopped. Set WINDOWED to
 * create a windowed device instead.
 *
 * Build: i686-w64-mingw32-gcc -O2 d3d9-fullscreen.c -o d3d9-fullscreen.exe -ld3d9
 *        (x86_64-w64-mingw32-gcc for 64 bit)
 * usage: run.sh --exec APPID d3d9-fullscreen.exe
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *f;
#define LOG(...) do { fprintf(f, __VA_ARGS__); fflush(f); } while (0)

int main(void)
{
    D3DPRESENT_PARAMETERS pp = {0};
    IDirect3DDevice9 *dev = NULL;
    IDirect3DSurface9 *surf = NULL;
    IDirect3D9 *d3d;
    HWND w;
    HRESULT hr;
    int i;

    f = fopen("d3d9-fullscreen.txt", "w");
    w = CreateWindowA("static", "d3d9-fullscreen", WS_POPUP | WS_VISIBLE, 0, 0, 640, 480, 0, 0, 0, 0);
    d3d = Direct3DCreate9(D3D_SDK_VERSION);

    pp.BackBufferWidth = 640;
    pp.BackBufferHeight = 480;
    pp.BackBufferFormat = D3DFMT_A8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = w;
    pp.Windowed = getenv("WINDOWED") != NULL;
    pp.EnableAutoDepthStencil = TRUE;
    pp.AutoDepthStencilFormat = D3DFMT_D24S8;

    LOG("creating device\n");
    hr = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, w, D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    LOG("CreateDevice hr %#lx\n", hr);
    if (FAILED(hr)) return 1;

    for (i = 0; i < 60; i++)
    {
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, 0xff00ff00 + i, 1.0f, 0);
        hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        if (i % 20 == 0) LOG("present %d hr %#lx\n", i, hr);
    }

    hr = IDirect3DDevice9_CreateOffscreenPlainSurface(dev, 640, 480, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &surf, NULL);
    LOG("CreateOffscreenPlainSurface hr %#lx\n", hr);
    hr = IDirect3DDevice9_GetFrontBufferData(dev, 0, surf);
    LOG("GetFrontBufferData hr %#lx\n", hr);

    IDirect3DSurface9_Release(surf);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    LOG("done\n");
    return 0;
}
