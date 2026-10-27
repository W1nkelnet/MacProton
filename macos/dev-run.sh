#!/bin/bash
# Development launcher for the macOS port: runs a Windows game through
# steam.exe with lsteamclient bridging to the running macOS Steam client.
# Stand-in for the proton script until it is ported.
#
# usage: dev-run.sh APPID GAME_DIR GAME_EXE [ARGS...]
#
# Environment: WINE_BUILD, MACPROTON (layout with lib/wine/*), DEPS
# (x86_64 dylibs), WINEPREFIX. Defaults match the development tree.

set -eu

if [ $# -lt 3 ]; then
    sed -n '2,10p' "$0"
    exit 1
fi

appid=$1 game_dir=$2 game_exe=$3
shift 3

root=$(cd "$(dirname "$0")/../.." && pwd)
: "${WINE_BUILD:=$root/build/wine64}"
: "${MACPROTON:=$root/build/macproton}"
: "${DEPS:=$root/build/deps-x86_64}"
: "${WINEPREFIX:?set WINEPREFIX}"
steam_macos="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"

if ! pgrep -q steam_osx; then
    echo "Steam is not running, start and log in to Steam first." >&2
    exit 1
fi

# lsteamclient.so links ntdll.so through @rpath next to itself
ln -sf "$WINE_BUILD/dlls/ntdll/ntdll.so" "$MACPROTON/lib/wine/x86_64-unix/ntdll.so"

export WINEPREFIX
export WINEDLLPATH="$MACPROTON/lib/wine"
export DYLD_FALLBACK_LIBRARY_PATH="$DEPS/lib"
export WINEDLLOVERRIDES="steam.exe=b;mscoree,mshtml=;${WINEDLLOVERRIDES-}"
export SteamAppId=$appid SteamGameId=$appid SteamOverlayGameId=$appid
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_macos"

# steam.exe needs a full Windows path to the game, like Proton passes it
game_dir=$(cd "$game_dir" && pwd)
game_path="Z:${game_dir//\//\\}\\$game_exe"

cd "$game_dir"
exec "$WINE_BUILD/wine" "$MACPROTON/lib/wine/x86_64-windows/steam.exe" "$game_path" "$@"
