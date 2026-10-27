#!/bin/bash
# Build Proton for macOS (x86_64 under Rosetta 2, WoW64 for 32-bit games).
#
# usage: macos/build.sh [BUILD_DIR]
#
# Produces BUILD_DIR/dist/files in the Proton layout (bin, lib, lib/wine,
# share) together with lsteamclient, steam.exe and DXVK. Steps that already
# finished are skipped; delete BUILD_DIR/stamps/<step> to redo one.
#
# Environment:
#   JOBS      parallel jobs (default: number of CPUs)
#   DEPS_SRC  directory with existing MoltenVK and freetype checkouts to
#             reuse instead of cloning them
#
# Requires Xcode and: brew install bison flex mingw-w64 autoconf automake
#   meson ninja glslang cmake pkgconf

set -euo pipefail

MOLTENVK_TAG=v1.4.2
FREETYPE_TAG=VER-2-14-3

proton=$(cd "$(dirname "$0")/.." && pwd)
build=$(mkdir -p "${1:-$proton/../build-macos}" && cd "${1:-$proton/../build-macos}" && pwd)
jobs=${JOBS:-$(sysctl -n hw.ncpu)}
deps_src=${DEPS_SRC:-$build/src}
deps=$build/deps-x86_64
dist=$build/dist/files
stamps=$build/stamps

export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"

mkdir -p "$stamps" "$deps/lib/pkgconfig" "$dist"

log() { printf '\n:: %s\n' "$*" >&2; }

# step NAME: run "do_NAME" unless its stamp exists
step() {
    if [ -e "$stamps/$1" ]; then
        log "$1 (done, skipping)"
        return
    fi
    log "$1"
    "do_$1"
    touch "$stamps/$1"
}

do_check_tools() {
    local missing=""
    for tool in xcodebuild bison flex x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc \
                autoreconf meson ninja glslangValidator cmake pkg-config git python3; do
        command -v "$tool" >/dev/null || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        echo "missing tools:$missing" >&2
        exit 1
    fi
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        echo "Rosetta 2 is required: softwareupdate --install-rosetta" >&2
        exit 1
    fi
}

do_submodules() {
    cd "$proton"
    git submodule update --init --depth 1 wine dxvk Vulkan-Headers SPIRV-Headers
    git -C dxvk submodule update --init --depth 1 --recursive
}

do_moltenvk() {
    local src=$deps_src/MoltenVK
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$MOLTENVK_TAG" https://github.com/KhronosGroup/MoltenVK.git "$src"
    fi
    (cd "$src" && ./fetchDependencies --macos && make macos)
    cp "$src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$deps/lib/"
}

do_freetype() {
    local src=$deps_src/freetype
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$FREETYPE_TAG" https://gitlab.freedesktop.org/freetype/freetype.git "$src"
    fi
    cmake -S "$src" -B "$build/freetype" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_INSTALL_NAME_DIR=@rpath \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_PNG=ON \
        -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_BZIP2=ON
    ninja -C "$build/freetype" install

    # freetype2.pc requires zlib and bzip2, which the macOS SDK provides
    # without pkg-config files
    printf 'Name: zlib\nDescription: zlib from the macOS SDK\nVersion: 1.2.12\nLibs: -lz\nCflags:\n' \
        > "$deps/lib/pkgconfig/zlib.pc"
    printf 'Name: bzip2\nDescription: bzip2 from the macOS SDK\nVersion: 1.0.8\nLibs: -lbz2\nCflags:\n' \
        > "$deps/lib/pkgconfig/bzip2.pc"
}

do_wine_source() {
    cd "$proton/wine"
    XDG_CACHE_HOME="$build/cache" python3 dlls/winevulkan/make_vulkan -x vk.xml -X video.xml
    tools/make_specfiles
    tools/make_requests
    autoreconf -fi
}

do_wine_configure() {
    mkdir -p "$build/wine"
    cd "$build/wine"
    # Set the architecture explicitly: configure would detect aarch64 on
    # Apple Silicon. Compilers run natively and target x86_64.
    PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" "$proton/wine/configure" \
        --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
        CC="clang -arch x86_64" LDFLAGS="-L$deps/lib -Wl,-rpath,$deps/lib" \
        --prefix="$dist" --enable-archs=i386,x86_64 \
        --without-x --without-wayland --without-gnutls --without-sdl --without-gstreamer \
        --without-pulse --without-alsa --without-oss --without-udev --without-dbus --without-v4l2
}

do_wine_build() {
    # sfnt2fon links freetype and runs during the build; relink it in case
    # it was built before the rpath was set (make does not track LDFLAGS)
    rm -f "$build/wine/tools/sfnt2fon/sfnt2fon"
    make -C "$build/wine" -j"$jobs"
}

do_wine_install() {
    make -C "$build/wine" install-lib
    cp "$deps/lib/libMoltenVK.dylib" "$deps"/lib/libfreetype*.dylib "$dist/lib/"

    # The build tree rpath lets build tools like sfnt2fon find freetype
    # (DYLD_* variables do not survive make's /bin/sh). Drop it from the
    # installed files; run.sh points DYLD_FALLBACK_LIBRARY_PATH at dist/lib.
    local f
    for f in "$dist"/bin/* "$dist"/lib/wine/x86_64-unix/*; do
        if otool -l "$f" 2>/dev/null | grep -q "path $deps/lib "; then
            install_name_tool -delete_rpath "$deps/lib" "$f"
        fi
    done
}

# dxvk_build ARCH CROSSFILE LIBDIR
dxvk_build() {
    meson setup --cross-file "$proton/dxvk/$2" --buildtype release \
        --prefix "$build/dxvk-install" --bindir "$3" --libdir "$3" \
        "$build/dxvk-$1" "$proton/dxvk"
    ninja -C "$build/dxvk-$1" install
    mkdir -p "$dist/lib/wine/dxvk/$3"
    cp "$build/dxvk-install/$3"/*.dll "$dist/lib/wine/dxvk/$3/"
}

do_dxvk() {
    dxvk_build x64 build-win64.txt x86_64-windows
    dxvk_build x32 build-win32.txt i386-windows
}

# wine_module NAME SRC_SUBDIR MODULE
wine_module() {
    local obj=$build/$1
    python3 "$proton/macos/makedep-module.py" "$proton/wine" "$build/wine" "$proton/$2" "$obj"
    (cd "$obj" && "$build/wine/tools/makedep" && make -j"$jobs")
    for arch in x86_64 i386; do
        cp "$obj/dlls/$2/$arch-windows/$3" "$dist/lib/wine/$arch-windows/"
    done
}

do_lsteamclient() {
    wine_module lsteamclient lsteamclient lsteamclient.dll
    cp "$build/lsteamclient/dlls/lsteamclient/lsteamclient.so" "$dist/lib/wine/x86_64-unix/"
}

do_steamexe() {
    wine_module steamexe steam_helper steam.exe
}

# Stand-ins for Steam's Windows steamclient DLLs, see steamclient-stub.py
do_steamclient_stub() {
    local obj=$build/steamclient-stub out=$dist/lib/wine/steamclient
    mkdir -p "$obj" "$out/x86_64-windows" "$out/i386-windows"
    python3 "$proton/macos/steamclient-stub.py" "$proton/lsteamclient/lsteamclient.spec" x86_64 "$obj/stub64"
    python3 "$proton/macos/steamclient-stub.py" "$proton/lsteamclient/lsteamclient.spec" i386 "$obj/stub32"
    x86_64-w64-mingw32-gcc -shared -nostdlib -nostartfiles -Wl,--entry=DllMain \
        -o "$out/x86_64-windows/steamclient64.dll" "$obj/stub64.S" "$obj/stub64.def"
    i686-w64-mingw32-gcc -shared -nostdlib -nostartfiles -Wl,--entry=_DllMain -Wl,--enable-stdcall-fixup \
        -o "$out/i386-windows/steamclient.dll" "$obj/stub32.S" "$obj/stub32.def"
}

do_dist() {
    cp "$proton/macos/run.sh" "$build/dist/run.sh"
    (cd "$proton" && git describe --always --dirty) > "$build/dist/version"
    log "done: $build/dist"
}

step check_tools
step submodules
step moltenvk
step freetype
step wine_source
step wine_configure
step wine_build
step wine_install
step dxvk
step lsteamclient
step steamexe
step steamclient_stub
rm -f "$stamps/dist"
step dist
