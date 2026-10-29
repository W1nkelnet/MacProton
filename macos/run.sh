#!/bin/bash
# Run a Windows game from Steam with Proton for macOS. Steam must be
# running and logged in; lsteamclient bridges the game to it.
#
# usage: run.sh APPID GAME_DIR GAME_EXE [ARGS...]
#        run.sh --prepare APPID   (only create/update the prefix)
#        run.sh --exec APPID PROGRAM [ARGS...]
#                                 (run a Windows program in the prefix and wait
#                                 for it, e.g. an installer the game ships)
#
# Environment:
#   WINEPREFIX  prefix to use (default: one per app id under
#               ~/Library/Application Support/MacProton/prefixes)
#   MACPROTON_DIST  dist directory with files/ (default: next to this script)

set -eu

prepare_only= program=
if [ "${1-}" = "--prepare" ] && [ $# -eq 2 ]; then
    prepare_only=1 appid=$2
    shift 2
elif [ "${1-}" = "--exec" ] && [ $# -ge 3 ]; then
    prepare_only=1 appid=$2 program=$3
    shift 3
elif [ $# -ge 3 ]; then
    appid=$1 game_dir=$2 game_exe=$3
    shift 3
else
    sed -n '2,15p' "$0"
    exit 1
fi

dist=${MACPROTON_DIST:-$(cd "$(dirname "$0")" && pwd)}/files
wine=$dist/bin/wine
wineserver=$dist/bin/wineserver
steam_macos="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"

if [ ! -x "$wine" ]; then
    echo "Proton build not found in $dist" >&2
    exit 1
fi
if [ -z "$prepare_only" ] && ! pgrep -q steam_osx; then
    echo "Steam is not running, start and log in to Steam first." >&2
    exit 1
fi

export WINEPREFIX="${WINEPREFIX:-$HOME/Library/Application Support/MacProton/prefixes/$appid}"
export DYLD_FALLBACK_LIBRARY_PATH="$dist/lib"
# MACPROTON_VULKAN_DRIVER=kosmickrisp runs Vulkan, and so DXVK and vkd3d, on
# Mesa's KosmicKrisp instead of MoltenVK. Zink needs it too: MoltenVK lacks
# null descriptors.
if { [ "${MACPROTON_VULKAN_DRIVER-}" = kosmickrisp ] || [ "${MACPROTON_OPENGL-}" = zink ]; } &&
    [ -f "$dist/lib/kosmickrisp/libMoltenVK.dylib" ]; then
    export DYLD_LIBRARY_PATH="$dist/lib/kosmickrisp${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    # The pixel-exact scaling the app sets for MoltenVK
    if [ "${MVK_CONFIG_SWAPCHAIN_MIN_MAG_FILTER_USE_NEAREST-}" = 1 ]; then
        export MESA_WSI_METAL_FILTER=${MESA_WSI_METAL_FILTER-nearest}
    fi
fi
export WINEDLLOVERRIDES="steam.exe=b;mshtml=;d3d8,d3d9,d3d10core,d3d11,dxgi,d3d12,d3d12core=n,b;${WINEDLLOVERRIDES-}"
export SteamAppId=$appid SteamGameId=$appid SteamOverlayGameId=$appid
# Keep resources alive that bound descriptor sets still reference after the
# game destroyed them; Metal otherwise loses the device ("Invalid Resource")
export MVK_CONFIG_LIVE_CHECK_ALL_RESOURCES=${MVK_CONFIG_LIVE_CHECK_ALL_RESOURCES-1}
# MoltenVK keeps its SPIR-V to MSL conversions in the prefix, so later starts
# skip them (MoltenVK patch 0010)
export MVK_CONFIG_SHADER_CACHE_DIR="${MVK_CONFIG_SHADER_CACHE_DIR-$WINEPREFIX/moltenvk-cache}"
# .NET games load ICU for globalization; Wine's icu.dll forwards to an ICU
# build this runtime does not ship, so .NET would fail fast
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=${DOTNET_SYSTEM_GLOBALIZATION_INVARIANT-1}
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_macos"
# Steam's overlay for macOS games hooks Metal and AppKit in the game
# process, which works for Windows games too: Shift+Tab, and the store and
# profile pages games open. MACPROTON_STEAM_OVERLAY=0 turns it off.
overlay="$steam_macos/gameoverlayrenderer.dylib"
if [ "${MACPROTON_STEAM_OVERLAY-1}" != 0 ] && [ -f "$overlay" ]; then
    export DYLD_INSERT_LIBRARIES="$overlay${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
fi

# Create or update the prefix here rather than letting Wine update it on
# the next start, with mscoree and mshtml disabled so that wineboot does
# not wait on the Mono/Gecko install dialog. Games need mscoree, though:
# Wine loads .NET Core assemblies through it.
windows="$WINEPREFIX/drive_c/windows"

# wineboot copies every builtin DLL into the prefix, some 600 MB; share the
# ones equal to the runtime's with it as APFS clones (cp -c), which keep
# their own content once either side is written
share_with_runtime() {
    local src dst
    for src in "$dist/lib/wine/x86_64-windows"/* "$dist/lib/wine/i386-windows"/*; do
        case $src in */x86_64-windows/*) dst="$windows/system32/${src##*/}" ;; *) dst="$windows/syswow64/${src##*/}" ;; esac
        [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst" &&
            cp -c -p "$src" "$dst.clone" 2>/dev/null && mv -f "$dst.clone" "$dst"
    done
    rm -f "$windows"/system32/*.clone "$windows"/syswow64/*.clone
}

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    mkdir -p "$WINEPREFIX"
    echo "Creating prefix in $WINEPREFIX" >&2
    WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" "$wine" wineboot -i
    "$wineserver" -w
    share_with_runtime
elif [ "$dist/share/wine/wine.inf" -nt "$WINEPREFIX/.update-timestamp" ]; then
    echo "Updating prefix in $WINEPREFIX" >&2
    WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" "$wine" wineboot -u
    "$wineserver" -w
    share_with_runtime
fi

# Clones where the file system allows, copies otherwise
install_dlls() {
    cp -c -f "$@" 2>/dev/null || cp -f "$@"
}
install_dlls "$dist/lib/wine/dxvk/x86_64-windows/"*.dll "$windows/system32/"
install_dlls "$dist/lib/wine/dxvk/i386-windows/"*.dll "$windows/syswow64/"
# Direct3D 12 through vkd3d-proton, 64-bit only; its shader cache stays in
# the prefix instead of the game's working directory
if [ -d "$dist/lib/wine/vkd3d-proton/x86_64-windows" ]; then
    install_dlls "$dist/lib/wine/vkd3d-proton/x86_64-windows/"*.dll "$windows/system32/"
fi
export VKD3D_SHADER_CACHE_PATH="${VKD3D_SHADER_CACHE_PATH-$WINEPREFIX}"
# MACPROTON_OPENGL=zink runs OpenGL on Vulkan through Mesa's Zink instead of
# macOS' OpenGL, which stops at 4.1; otherwise Wine's own opengl32 stays
zink="$dist/lib/wine/zink"
if [ "${MACPROTON_OPENGL-}" = zink ] && [ -d "$zink/x86_64-windows" ]; then
    install_dlls "$zink/x86_64-windows/"*.dll "$windows/system32/"
    if [ -d "$zink/i386-windows" ]; then
        install_dlls "$zink/i386-windows/"*.dll "$windows/syswow64/"
    fi
    export WINEDLLOVERRIDES="opengl32=n;$WINEDLLOVERRIDES"
    # Metal has no RGB32 texel buffers, which alone hold Zink at OpenGL 3.3;
    # games hardly use them
    export MESA_EXTENSION_OVERRIDE="${MESA_EXTENSION_OVERRIDE-GL_ARB_texture_buffer_object_rgb32}"
else
    cmp -s "$dist/lib/wine/x86_64-windows/opengl32.dll" "$windows/system32/opengl32.dll" ||
        install_dlls "$dist/lib/wine/x86_64-windows/opengl32.dll" "$windows/system32/"
    cmp -s "$dist/lib/wine/i386-windows/opengl32.dll" "$windows/syswow64/opengl32.dll" ||
        install_dlls "$dist/lib/wine/i386-windows/opengl32.dll" "$windows/syswow64/"
fi

# The game's steam_api loads steamclient(64).dll from SteamPath; Wine's
# loader redirects their exports to lsteamclient. macOS Steam ships no
# Windows versions. Valve's from the Steamworks SDK Redist (app 1007),
# which MacProton downloads, also satisfy Steam's DRM; without them, stub
# DLLs exporting the same names do for steam_api. Copies of lsteamclient
# itself do not work: Wine then takes the copy for the lsteamclient module
# and redirects to itself.
steam_dir="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
redist=${MACPROTON_STEAM_REDIST:-$HOME/Library/Application Support/MacProton/steamworks-redist}
mkdir -p "$steam_dir"
if [ -f "$redist/steamclient64.dll" ] && [ -f "$redist/steamclient.dll" ]; then
    cp -f "$redist/steamclient64.dll" "$redist/steamclient.dll" "$steam_dir/"
else
    cp -f "$dist/lib/wine/steamclient/x86_64-windows/steamclient64.dll" "$steam_dir/"
    cp -f "$dist/lib/wine/steamclient/i386-windows/steamclient.dll" "$steam_dir/"
fi

# wine returns once the program is done; "wineserver -w" would also wait
# for anything else running in the prefix, such as the game itself
if [ -n "$program" ]; then
    case "$program" in
        *.[cC][mM][dD]|*.[bB][aA][tT]) exec "$wine" cmd /c "$program" "$@" ;;
        *) exec "$wine" "$program" "$@" ;;
    esac
fi
if [ -n "$prepare_only" ]; then
    "$wineserver" -w
    exit 0
fi

# steam.exe needs a full Windows path to the game, like Proton passes it
game_dir=$(cd "$game_dir" && pwd)
game_path="Z:${game_dir//\//\\}\\$game_exe"

cd "$game_dir"
exec "$wine" "$dist/lib/wine/x86_64-windows/steam.exe" "$game_path" "$@"
