#!/bin/bash
# Renders with geometry shaders through MoltenVK offscreen and checks the pixels.
#
# usage: macos/tests/geometry/run.sh [MOLTENVK_DIR]
#
# MOLTENVK_DIR is a MoltenVK checkout built with `make macos`, by default the one
# macos/build.sh builds. Needs glslangValidator. Writes the images to a temp dir.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mvk=${1:-$here/../../../../build/src/MoltenVK}
lib=$mvk/Package/Release/MoltenVK/dynamic/dylib/macOS
out=$(mktemp -d)

for f in "$here"/*.vert "$here"/*.geom "$here"/*.frag; do
    glslangValidator -V "$f" -o "$out/$(basename "$f").spv" > /dev/null
done
clang++ -std=c++17 -O1 -I"$mvk/External/Vulkan-Headers/include" "$here/gstest.cpp" \
    -L"$lib" -lMoltenVK -Wl,-rpath,"$lib" -o "$out/gstest"
"$out/gstest" "$out" "$out"
echo "Images in $out"
