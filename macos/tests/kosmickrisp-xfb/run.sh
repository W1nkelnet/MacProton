#!/bin/sh
# Builds and runs the transform feedback test against KosmicKrisp in a dist.
# usage: run.sh [DIST]   (default: build-macos/dist)
set -e
here=$(cd "$(dirname "$0")" && pwd)
dist=${1:-$here/../../../../build-macos/dist}
lib=$dist/files/lib/kosmickrisp
out=$(mktemp -d)
for f in "$here"/*.vert "$here"/*.geom "$here"/*.frag "$here"/*.tesc "$here"/*.tese; do
    glslangValidator -V -o "$out/$(basename "$f").spv" "$f" >/dev/null 2>&1 || exit 1
done
clang -arch x86_64 -O1 -I"$here/../../../../build/src/mesa/include" -o "$out/xfbtest" "$here/test.c" \
    -L"$lib" -lMoltenVK -Wl,-rpath,"$lib"
cd "$out" && ./xfbtest
