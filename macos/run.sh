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
export WINEDLLOVERRIDES="steam.exe=b;mscoree,mshtml=;d3d8,d3d9,d3d10core,d3d11,dxgi=n,b;${WINEDLLOVERRIDES-}"
export SteamAppId=$appid SteamGameId=$appid SteamOverlayGameId=$appid
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_macos"

# Create or update the prefix. mscoree/mshtml stay disabled above so that
# wineboot does not wait on the Mono/Gecko install dialog.
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    mkdir -p "$WINEPREFIX"
    echo "Creating prefix in $WINEPREFIX" >&2
    "$wine" wineboot -i
    "$wineserver" -w
fi

windows="$WINEPREFIX/drive_c/windows"
cp -f "$dist/lib/wine/dxvk/x86_64-windows/"*.dll "$windows/system32/"
cp -f "$dist/lib/wine/dxvk/i386-windows/"*.dll "$windows/syswow64/"

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
