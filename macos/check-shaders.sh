#!/bin/bash
# Compile Metal shaders that MoltenVK dumped while a game ran and list the
# ones Metal rejects. Every failure is a translation bug in SPIRV-Cross or
# MoltenVK, so this finds them for all shaders a game used without having
# to reach each effect in the game.
#
# Collect the dumps by running a game with
#   MVK_CONFIG_SHADER_DUMP_DIR=DIR run.sh APPID GAME_DIR GAME_EXE
#
# usage: check-shaders.sh DIR...
#
# Environment:
#   METAL_STD  Metal language version (default: metal3.2, what MoltenVK
#              uses on macOS 15 and later)

set -eu

if [ $# -eq 0 ]; then
    sed -n '2,13p' "$0"
    exit 1
fi

std=${METAL_STD:-metal3.2}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

find "$@" -name '*.metal' -print0 |
    xargs -0 -P "$(sysctl -n hw.ncpu)" -I{} sh -c '
        err=$(xcrun -sdk macosx metal -std="$1" -w -c "$2" -o /dev/null 2>&1) ||
            printf "%s\n%s\n" "$2" "$(printf "%s\n" "$err" | grep -m1 "error:")" > "$3/$(basename "$2").fail"
    ' _ "$std" {} "$out"

total=$(find "$@" -name '*.metal' | wc -l | tr -d ' ')
failed=$(find "$out" -name '*.fail' | wc -l | tr -d ' ')
for f in "$out"/*.fail; do
    [ -e "$f" ] || continue
    sed -n 1p "$f"
    sed -n '2s/^[^:]*:[0-9]*:[0-9]*: /    /p' "$f"
done
echo "$failed of $total shaders do not compile"
[ "$failed" -eq 0 ]
