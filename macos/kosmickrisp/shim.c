/* Lets Wine use Mesa's KosmicKrisp like MoltenVK: Wine loads libMoltenVK.dylib
 * itself, without a Vulkan loader, and calls vkGetInstanceProcAddr, while
 * KosmicKrisp is a loader ICD. This library takes the name, negotiates the ICD
 * interface and forwards to libvulkan_kosmickrisp.dylib next to it. Wine also
 * looks up vkGetDeviceProcAddr, which the ICD only gives out per instance,
 * and vkCreateMetalSurfaceEXT to pick VK_EXT_metal_surface. */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_icdGetInstanceProcAddr)(void *instance, const char *name);
typedef int32_t (*PFN_icdNegotiate)(uint32_t *version);
typedef int32_t (*PFN_createMetalSurface)(void *instance, const void *info, const void *allocator, void *surface);
typedef PFN_vkVoidFunction (*PFN_getDeviceProcAddr)(void *device, const char *name);

static PFN_icdGetInstanceProcAddr icd_get_instance_proc_addr;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static PFN_getDeviceProcAddr icd_get_device_proc_addr;

static void load(void)
{
    Dl_info info;
    char path[4096], *slash;
    void *handle;

    if (!dladdr((void *)load, &info) || strlen(info.dli_fname) >= sizeof(path)) return;
    strcpy(path, info.dli_fname);
    if (!(slash = strrchr(path, '/'))) return;
    snprintf(slash + 1, sizeof(path) - (slash + 1 - path), "libvulkan_kosmickrisp.dylib");
    if (!(handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)))
    {
        fprintf(stderr, "kosmickrisp shim: %s\n", dlerror());
        return;
    }
    PFN_icdNegotiate negotiate = (PFN_icdNegotiate)dlsym(handle, "vk_icdNegotiateLoaderICDInterfaceVersion");
    uint32_t version = 7;
    if (negotiate) negotiate(&version);
    icd_get_instance_proc_addr = (PFN_icdGetInstanceProcAddr)dlsym(handle, "vk_icdGetInstanceProcAddr");
}

__attribute__((visibility("default")))
PFN_vkVoidFunction vkGetInstanceProcAddr(void *instance, const char *name)
{
    pthread_once(&once, load);
    if (!icd_get_instance_proc_addr) return NULL;
    if (instance && !icd_get_device_proc_addr)
        icd_get_device_proc_addr = (PFN_getDeviceProcAddr)icd_get_instance_proc_addr(instance, "vkGetDeviceProcAddr");
    return icd_get_instance_proc_addr(instance, name);
}

/* Devices only come from an instance, whose vkGetInstanceProcAddr calls set this */
__attribute__((visibility("default")))
PFN_vkVoidFunction vkGetDeviceProcAddr(void *device, const char *name)
{
    return icd_get_device_proc_addr ? icd_get_device_proc_addr(device, name) : NULL;
}

__attribute__((visibility("default")))
int32_t vkCreateMetalSurfaceEXT(void *instance, const void *info, const void *allocator, void *surface)
{
    PFN_createMetalSurface create = (PFN_createMetalSurface)vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT");
    return create ? create(instance, info, allocator, surface) : -7; /* VK_ERROR_EXTENSION_NOT_PRESENT */
}
