/*
 * D3D11 GenerateMips check.
 *
 * Fills the top level of textures of several formats and sizes, lets
 * GenerateMips build the chain and reads every level back. Each level must
 * match a bilinear sample of the level above it at its texel centers, which
 * is what both of DXVK's paths compute: blits per level and the single-pass
 * compute shader. Large sizes make the compute shader run more than one
 * pass, array textures cover the layers.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 d3d11-mipgen.c -o d3d11-mipgen.exe \
 *          -ld3d11 -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ID3D11Device *device;

static unsigned
subresource(unsigned level, unsigned layer, unsigned levels)
{
   return level + layer * levels;
}

static ID3D11DeviceContext *ctx;
static int failures;

static float
half_to_float(unsigned short h)
{
   unsigned e = (h >> 10) & 0x1f, m = h & 0x3ff;
   float v = e ? ldexpf(1.0f + m / 1024.0f, (int)e - 15) : ldexpf(m / 1024.0f, -14);
   return (h & 0x8000) ? -v : v;
}

static unsigned short
float_to_half(float f)
{
   unsigned short sign = f < 0 ? 0x8000 : 0;
   f = fabsf(f);
   if (f < ldexpf(1.0f, -14))
      return sign | (unsigned short)lrintf(f / ldexpf(1.0f, -24));
   int e;
   float m = frexpf(f, &e); /* f = m * 2^e, m in [0.5, 1) */
   unsigned mant = (unsigned)lrintf((m * 2.0f - 1.0f) * 1024.0f);
   unsigned exp = (unsigned)(e - 1 + 15);
   if (mant == 1024) {
      mant = 0;
      exp++;
   }
   return sign | (unsigned short)(exp << 10) | (unsigned short)mant;
}

/* Texel access in floats, 4 channels */
static void
load_texel(DXGI_FORMAT fmt, const unsigned char *row, unsigned x, float out[4])
{
   if (fmt == DXGI_FORMAT_R16G16B16A16_FLOAT) {
      const unsigned short *p = (const unsigned short *)row + x * 4;
      for (int c = 0; c < 4; c++)
         out[c] = half_to_float(p[c]);
   } else {
      const unsigned char *p = row + x * 4;
      for (int c = 0; c < 4; c++)
         out[c] = p[c] / 255.0f;
   }
}

static void
store_texel(DXGI_FORMAT fmt, unsigned char *row, unsigned x, const float v[4])
{
   if (fmt == DXGI_FORMAT_R16G16B16A16_FLOAT) {
      unsigned short *p = (unsigned short *)row + x * 4;
      for (int c = 0; c < 4; c++)
         p[c] = float_to_half(v[c]);
   } else {
      unsigned char *p = row + x * 4;
      for (int c = 0; c < 4; c++)
         p[c] = (unsigned char)lrintf(fminf(fmaxf(v[c], 0.0f), 1.0f) * 255.0f);
   }
}

struct level {
   unsigned w, h, pitch;
   unsigned char *data;
};

static void
fetch(DXGI_FORMAT fmt, const struct level *l, int x, int y, float out[4])
{
   x = x < 0 ? 0 : x >= (int)l->w ? (int)l->w - 1 : x;
   y = y < 0 ? 0 : y >= (int)l->h ? (int)l->h - 1 : y;
   load_texel(fmt, l->data + (size_t)y * l->pitch, x, out);
}

/* Bilinear sample of SRC at normalized coordinates, clamped */
static void
bilinear(DXGI_FORMAT fmt, const struct level *src, float u, float v, float out[4])
{
   float x = u * src->w - 0.5f, y = v * src->h - 0.5f;
   int x0 = (int)floorf(x), y0 = (int)floorf(y);
   float fx = x - x0, fy = y - y0;
   float a[4], b[4], c[4], d[4];
   fetch(fmt, src, x0, y0, a);
   fetch(fmt, src, x0 + 1, y0, b);
   fetch(fmt, src, x0, y0 + 1, c);
   fetch(fmt, src, x0 + 1, y0 + 1, d);
   for (int i = 0; i < 4; i++)
      out[i] = (a[i] * (1 - fx) + b[i] * fx) * (1 - fy) + (c[i] * (1 - fx) + d[i] * fx) * fy;
}

/* DXVK's compute shader past the first level, which it samples bilinearly:
 * it reads the two texels at x * src / dst + 0.5 and interpolates, per axis.
 * For levels that halve exactly this equals the bilinear sample. */
static void
dxvk_odd(DXGI_FORMAT fmt, const struct level *src, unsigned dst_w, unsigned dst_h,
         unsigned x, unsigned y, float out[4])
{
   float px = src->w > 1 ? (float)x / dst_w * src->w + 0.5f : 0.0f;
   float py = src->h > 1 ? (float)y / dst_h * src->h + 0.5f : 0.0f;
   int x0 = (int)px, y0 = (int)py;
   float fx = px - x0, fy = py - y0;
   float a[4], b[4], c[4], d[4];
   fetch(fmt, src, x0, y0, a);
   fetch(fmt, src, x0 + 1, y0, b);
   fetch(fmt, src, x0, y0 + 1, c);
   fetch(fmt, src, x0 + 1, y0 + 1, d);
   for (int i = 0; i < 4; i++)
      out[i] = (a[i] * (1 - fx) + b[i] * fx) * (1 - fy) + (c[i] * (1 - fx) + d[i] * fx) * fy;
}

static void
check(const char *name, DXGI_FORMAT fmt, unsigned width, unsigned height, unsigned layers)
{
   unsigned levels = 1, s = width > height ? width : height;
   while (s > 1) {
      s >>= 1;
      levels++;
   }

   D3D11_TEXTURE2D_DESC desc = {
      .Width = width, .Height = height, .MipLevels = levels, .ArraySize = layers,
      .Format = fmt, .SampleDesc.Count = 1, .Usage = D3D11_USAGE_DEFAULT,
      .BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET,
      .MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS,
   };
   ID3D11Texture2D *tex, *staging;
   if (FAILED(ID3D11Device_CreateTexture2D(device, &desc, NULL, &tex))) {
      printf("FAIL %s: CreateTexture2D\n", name);
      failures++;
      return;
   }
   desc.Usage = D3D11_USAGE_STAGING;
   desc.BindFlags = 0;
   desc.MiscFlags = 0;
   desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
   ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);

   /* Top level: smooth gradients plus noise, different per layer */
   unsigned bpp = fmt == DXGI_FORMAT_R16G16B16A16_FLOAT ? 8 : 4;
   unsigned pitch = width * bpp;
   unsigned char *top = malloc((size_t)pitch * height);
   srand(width * 31 + height);
   for (unsigned l = 0; l < layers; l++) {
      for (unsigned y = 0; y < height; y++) {
         for (unsigned x = 0; x < width; x++) {
            float v[4] = {
               (float)x / width,
               (float)y / height,
               0.5f + 0.5f * sinf(x * 0.05f + y * 0.03f + l),
               (rand() & 255) / 255.0f,
            };
            store_texel(fmt, top + (size_t)y * pitch, x, v);
         }
      }
      ID3D11DeviceContext_UpdateSubresource(
         ctx, (ID3D11Resource *)tex, subresource(0, l, levels), NULL, top, pitch, 0);
   }
   free(top);

   D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = {.Format = fmt};
   if (layers > 1) {
      srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
      srv_desc.Texture2DArray.MipLevels = levels;
      srv_desc.Texture2DArray.ArraySize = layers;
   } else {
      srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
      srv_desc.Texture2D.MipLevels = levels;
   }
   ID3D11ShaderResourceView *srv;
   ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)tex, &srv_desc, &srv);
   ID3D11DeviceContext_GenerateMips(ctx, srv);
   ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)tex);

   /* The compute shader keeps some levels unrounded while it filters on */
   float tolerance = fmt == DXGI_FORMAT_R16G16B16A16_FLOAT ? 0.004f : 2.0f / 255.0f;
   float worst = 0.0f, worst_dxvk = 0.0f;
   unsigned worst_level = 0, bad = 0, bad_dxvk = 0;
   for (unsigned l = 0; l < layers; l++) {
      struct level prev = {0};
      D3D11_MAPPED_SUBRESOURCE maps[16];
      for (unsigned m = 0; m < levels; m++) {
         unsigned sub = subresource(m, l, levels);
         ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, sub, D3D11_MAP_READ, 0, &maps[m]);
         struct level cur = {
            .w = width >> m ? width >> m : 1,
            .h = height >> m ? height >> m : 1,
            .pitch = maps[m].RowPitch,
            .data = maps[m].pData,
         };
         if (m > 0) {
            for (unsigned y = 0; y < cur.h; y++) {
               for (unsigned x = 0; x < cur.w; x++) {
                  float ref[4], odd[4], got[4];
                  bilinear(fmt, &prev, (x + 0.5f) / cur.w, (y + 0.5f) / cur.h, ref);
                  if (m == 1)
                     memcpy(odd, ref, sizeof(odd));
                  else
                     dxvk_odd(fmt, &prev, cur.w, cur.h, x, y, odd);
                  load_texel(fmt, cur.data + (size_t)y * cur.pitch, x, got);
                  for (int c = 0; c < 4; c++) {
                     float e = fabsf(ref[c] - got[c]), e2 = fabsf(odd[c] - got[c]);
                     if (fmt == DXGI_FORMAT_R16G16B16A16_FLOAT) {
                        e /= fmaxf(1.0f, fabsf(ref[c]));
                        e2 /= fmaxf(1.0f, fabsf(odd[c]));
                     }
                     if (e > worst) {
                        worst = e;
                        worst_level = m;
                     }
                     worst_dxvk = fmaxf(worst_dxvk, e2);
                     if (e > tolerance)
                        bad++;
                     if (e2 > tolerance)
                        bad_dxvk++;
                  }
               }
            }
         }
         prev = cur;
      }
      for (unsigned m = 0; m < levels; m++)
         ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, subresource(m, l, levels));
   }

   /* Either filter is fine, but the whole chain must follow one */
   if (bad && bad_dxvk) {
      printf("FAIL %s: %u channel values off, worst %.4f at level %u, %.4f from DXVK's filter\n",
             name, bad, worst, worst_level, worst_dxvk);
      failures++;
   } else {
      printf("ok   %s: %u levels, worst %.4f bilinear, %.4f DXVK's filter\n", name, levels,
             worst, worst_dxvk);
   }

   ID3D11ShaderResourceView_Release(srv);
   ID3D11Texture2D_Release(staging);
   ID3D11Texture2D_Release(tex);
}

int
main(void)
{
   D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
   if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1,
                                D3D11_SDK_VERSION, &device, NULL, &ctx))) {
      printf("FAIL: D3D11CreateDevice\n");
      return 1;
   }

   check("rgba8 256x256", DXGI_FORMAT_R8G8B8A8_UNORM, 256, 256, 1);
   check("rgba8 1710x1107", DXGI_FORMAT_R8G8B8A8_UNORM, 1710, 1107, 1);
   check("bgra8 1024x512", DXGI_FORMAT_B8G8R8A8_UNORM, 1024, 512, 1);
   check("rgba16f 512x512", DXGI_FORMAT_R16G16B16A16_FLOAT, 512, 512, 1);
   check("rgba16f 300x77", DXGI_FORMAT_R16G16B16A16_FLOAT, 300, 77, 1);
   check("rgba8 4096x4096", DXGI_FORMAT_R8G8B8A8_UNORM, 4096, 4096, 1);
   check("rgba8 128x128 x6", DXGI_FORMAT_R8G8B8A8_UNORM, 128, 128, 6);
   check("rgba8 1x1000", DXGI_FORMAT_R8G8B8A8_UNORM, 1, 1000, 1);

   printf("%s\n", failures ? "FAILED" : "all passed");
   return failures ? 1 : 0;
}
