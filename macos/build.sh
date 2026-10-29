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
#
# Downloads MoltenVK and freetype (git), GMP, nettle, GnuTLS and SDL2
# (release tarballs, checked against pinned SHA-256 sums).

set -euo pipefail

# MoltenVK main after 1.4.2, with VK_EXT_depth_clip_enable and draw indirect count
MOLTENVK_COMMIT=5189f8de86ec365860f63bf1da736815cfaea5cd
FREETYPE_TAG=VER-2-14-3
GMP_URL=https://ftpmirror.gnu.org/gmp/gmp-6.3.0.tar.xz
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
NETTLE_URL=https://ftpmirror.gnu.org/nettle/nettle-4.0.tar.gz
NETTLE_SHA256=3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094
GNUTLS_URL=https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz
GNUTLS_SHA256=ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e
# SDL publishes GPG signatures only; hash of the official release tarball
SDL2_URL=https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
SDL2_SHA256=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165

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

# The wine and dxvk submodules point to the upstream commits Proton uses;
# the macOS changes are kept as patches in macos/patches and applied here.
# apply_patches SUBMODULE [PATCH_DIR]
apply_patches() {
    local dir=$proton/$1 patch
    for patch in "$proton/macos/patches/${2:-$1}"/*.patch; do
        if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
            continue # already applied
        fi
        git -C "$dir" apply "$patch"
    done
}

do_submodules() {
    cd "$proton"
    git submodule update --init --depth 1 wine dxvk vkd3d-proton Vulkan-Headers SPIRV-Headers
    git -C dxvk submodule update --init --depth 1 --recursive
    git -C vkd3d-proton submodule update --init --depth 1 --recursive
    apply_patches wine
    apply_patches dxvk
    apply_patches dxvk/subprojects/dxbc-spirv dxbc-spirv
    apply_patches vkd3d-proton
    apply_patches vkd3d-proton/subprojects/dxil-spirv dxil-spirv
}

do_moltenvk() {
    local src=$deps_src/MoltenVK
    if [ ! -d "$src" ]; then
        git clone https://github.com/KhronosGroup/MoltenVK.git "$src"
        git -C "$src" checkout -q "$MOLTENVK_COMMIT"
    fi
    local patch
    for patch in "$proton/macos/patches/moltenvk"/*.patch; do
        git -C "$src" apply --reverse --check "$patch" 2>/dev/null || git -C "$src" apply "$patch"
    done
    # fetchDependencies resets changes in its own SPIRV-Cross checkout, so it
    # builds a patched copy at the revision MoltenVK pins instead
    local cross=$deps_src/SPIRV-Cross
    if [ ! -d "$cross" ]; then
        git clone https://github.com/KhronosGroup/SPIRV-Cross.git "$cross"
    fi
    git -C "$cross" checkout -q "$(cat "$src/ExternalRevisions/SPIRV-Cross_repo_revision")"
    for patch in "$proton/macos/patches/spirv-cross"/*.patch; do
        git -C "$cross" apply --reverse --check "$patch" 2>/dev/null || git -C "$cross" apply "$patch"
    done
    (cd "$src" && ./fetchDependencies --macos --spirv-cross-root "$cross" && make macos)
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

# fetch URL SHA256: download and unpack a release tarball into $deps_src,
# prints the source directory
fetch() {
    local url=$1 sha256=$2 file dir
    file=$deps_src/tarballs/$(basename "$url")
    dir=$deps_src/$(basename "$url" | sed -E 's/\.tar\.(gz|xz)$//')
    mkdir -p "$deps_src/tarballs"
    [ -f "$file" ] || curl -fL --retry 3 -o "$file" "$url" >&2
    if [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha256" ]; then
        echo "checksum mismatch for $file" >&2
        exit 1
    fi
    [ -d "$dir" ] || tar -xf "$file" -C "$deps_src"
    echo "$dir"
}

# autotools_build SRC OBJ [CONFIGURE_ARGS...]: x86_64 build into $deps
autotools_build() {
    local src=$1 obj=$2
    shift 2
    mkdir -p "$obj"
    (cd "$obj" && PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" "$src/configure" \
        --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
        CC="clang -arch x86_64" CPPFLAGS="-I$deps/include" LDFLAGS="-L$deps/lib -Wl,-rpath,$deps/lib" \
        --prefix="$deps" --enable-shared --disable-static "$@" \
        && make -j"$jobs" && make install)
}

# Give libraries in $deps relocatable @rpath install names; Wine dlopens
# them by leaf name and run.sh points DYLD_FALLBACK_LIBRARY_PATH at them.
# The build-time rpath to $deps (needed by configure test programs of the
# next library) is dropped again.
fix_install_names() {
    local lib dep
    for lib in "$deps"/lib/*.dylib; do
        [ -L "$lib" ] && continue
        if otool -l "$lib" | grep -q "path $deps/lib "; then
            install_name_tool -delete_rpath "$deps/lib" "$lib"
        fi
        local id
        id=$(otool -arch x86_64 -D "$lib" | tail -1)
        [[ $id == @rpath/* ]] || install_name_tool -id "@rpath/$(basename "$id")" "$lib"
        for dep in $(otool -arch x86_64 -L "$lib" | awk 'NR > 1 {print $1}' | grep "^$deps/lib/"); do
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib"
        done
        # Only libraries with @rpath dependencies need an rpath (MoltenVK has
        # none, and no header space left for one)
        if otool -arch x86_64 -L "$lib" | awk 'NR > 2 {print $1}' | grep -q "^@rpath/" \
           && ! otool -l "$lib" | grep -q "path @loader_path/ "; then
            install_name_tool -add_rpath @loader_path/ "$lib"
        fi
    done
}

do_gmp() {
    autotools_build "$(fetch "$GMP_URL" "$GMP_SHA256")" "$build/gmp" ABI=64
    fix_install_names
}

do_nettle() {
    autotools_build "$(fetch "$NETTLE_URL" "$NETTLE_SHA256")" "$build/nettle" \
        --disable-documentation --libdir="$deps/lib"
    fix_install_names
}

do_gnutls() {
    autotools_build "$(fetch "$GNUTLS_URL" "$GNUTLS_SHA256")" "$build/gnutls" \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit \
        --without-idn --without-brotli --without-zstd --without-zlib \
        --without-tpm --without-tpm2 --disable-tools --disable-doc --disable-tests \
        --disable-cxx --disable-guile --disable-nls
    fix_install_names
}

# Game controllers: winebus maps them to XInput/DirectInput through SDL
do_sdl2() {
    cmake -S "$(fetch "$SDL2_URL" "$SDL2_SHA256")" -B "$build/sdl2" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_INSTALL_NAME_DIR=@rpath \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
    ninja -C "$build/sdl2" install
    fix_install_names
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
        --without-x --without-wayland --without-gstreamer \
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
    cp -a "$deps"/lib/*.dylib "$dist/lib/"

    # The build tree rpath lets build tools like sfnt2fon find freetype
    # (DYLD_* variables do not survive make's /bin/sh). Drop it from the
    # installed files; run.sh points DYLD_FALLBACK_LIBRARY_PATH at dist/lib.
    local f
    for f in "$dist"/bin/* "$dist"/lib/wine/x86_64-unix/*; do
        if otool -l "$f" 2>/dev/null | grep -q "path $deps/lib "; then
            install_name_tool -delete_rpath "$deps/lib" "$f"
        fi
    done

    # macOS turns on Game Mode only for processes of an app bundle in the
    # games category (wine_info.plist); ntdll starts Windows programs from
    # this one, and its loader finds ntdll.so three folders up
    local bundle="$dist/lib/wine/x86_64-unix/Wine.app/Contents"
    mkdir -p "$bundle/MacOS"
    cp -f "$dist/lib/wine/x86_64-unix/wine" "$bundle/MacOS/wine"
    cp -f "$build/wine/loader/wine_info.plist" "$bundle/Info.plist"
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

# Direct3D 12; games are 64-bit only
do_vkd3d() {
    meson setup --cross-file "$proton/vkd3d-proton/build-win64.txt" --buildtype release \
        "$build/vkd3d-x64" "$proton/vkd3d-proton"
    ninja -C "$build/vkd3d-x64"
    mkdir -p "$dist/lib/wine/vkd3d-proton/x86_64-windows"
    cp "$build/vkd3d-x64/libs/d3d12/d3d12.dll" "$build/vkd3d-x64/libs/d3d12core/d3d12core.dll" \
        "$dist/lib/wine/vkd3d-proton/x86_64-windows/"
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
    install_name_tool -delete_rpath "$deps/lib" "$dist/lib/wine/x86_64-unix/lsteamclient.so" 2>/dev/null || true
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
    # Drop debug info from the shipped files; the build trees keep it
    local f
    find "$dist/lib/wine/x86_64-windows" "$dist/lib/wine/dxvk/x86_64-windows" "$dist/lib/wine/steamclient/x86_64-windows" \
        "$dist/lib/wine/vkd3d-proton/x86_64-windows" \
        -type f \( -name "*.dll" -o -name "*.exe" -o -name "*.sys" -o -name "*.drv" -o -name "*.ocx" -o -name "*.cpl" \) \
        -exec x86_64-w64-mingw32-strip --strip-debug {} +
    find "$dist/lib/wine/i386-windows" "$dist/lib/wine/dxvk/i386-windows" "$dist/lib/wine/steamclient/i386-windows" \
        -type f \( -name "*.dll" -o -name "*.exe" -o -name "*.sys" -o -name "*.drv" -o -name "*.ocx" -o -name "*.cpl" \) \
        -exec i686-w64-mingw32-strip --strip-debug {} +
    for f in "$dist"/bin/* "$dist"/lib/wine/x86_64-unix/*; do
        [ -L "$f" ] || ! file "$f" | grep -q Mach-O || strip -S "$f"
    done

    cp "$proton/macos/run.sh" "$build/dist/run.sh"
    (cd "$proton" && git describe --always --dirty) > "$build/dist/version"
    log "done: $build/dist"
}

step check_tools
step submodules
step moltenvk
step freetype
step gmp
step nettle
step gnutls
step sdl2
step wine_source
step wine_configure
step wine_build
step wine_install
step dxvk
step vkd3d
step lsteamclient
step steamexe
step steamclient_stub
rm -f "$stamps/dist"
step dist
