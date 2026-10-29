#!/bin/sh
# Presents a test pattern through KosmicKrisp in a dist, at half the window's
# pixels, so the driver scales it up. Pass e.g. MESA_WSI_METAL_UPSCALING=metalfx
# or MESA_WSI_METAL_FILTER=nearest in the environment.
# usage: run.sh [DIST]   (default: build-macos/dist)
set -e
here=$(cd "$(dirname "$0")" && pwd)
dist=${1:-$here/../../../../build-macos/dist}
lib=$dist/files/lib/kosmickrisp
out=$(mktemp -d)
clang -arch x86_64 -O1 -fobjc-arc -I"$here/../../../../build/src/mesa/include" -DVK_USE_PLATFORM_METAL_EXT \
    -framework Cocoa -framework QuartzCore -o "$out/present" "$here/present.m" -L"$lib" -lMoltenVK -Wl,-rpath,"$lib"
"$out/present"
