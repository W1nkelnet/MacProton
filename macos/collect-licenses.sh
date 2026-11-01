#!/bin/bash
# Copy the license texts of everything MacProton.app ships into macos/licenses,
# from the source trees macos/build.sh used. Run after a build that changes a
# component or its version; the result is committed and bundled by
# macos/app/build-app.sh.
#
# usage: macos/collect-licenses.sh [DEPS_SRC]
#
# DEPS_SRC holds the MoltenVK, SPIRV-Cross, Mesa, freetype, GMP, nettle,
# GnuTLS and SDL2 sources (default: ../build/src next to the Proton checkout).

set -euo pipefail

proton=$(cd "$(dirname "$0")/.." && pwd)
deps=${1:-$(cd "$proton/../build/src" && pwd)}
out=$proton/macos/licenses

eval "$(grep -E '^(MESA_COMMIT|MOLTENVK_COMMIT|FREETYPE_TAG|GMP_URL|NETTLE_URL|GNUTLS_URL|SDL2_URL)=' "$proton/macos/build.sh")"

rm -rf "$out"
mkdir -p "$out"

# copy DEST SRC...: copies the license files that exist into $out/DEST
copy() {
    local dest=$out/$1 f
    shift
    mkdir -p "$dest"
    for f in "$@"; do
        [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
        cp -R "$f" "$dest/"
    done
}

copy proton "$proton/LICENSE.proton"
copy lsteamclient "$proton/lsteamclient/LICENSE"
copy wine "$proton/wine/LICENSE" "$proton/wine/COPYING.LIB" "$proton/wine/AUTHORS"
for lib in "$proton"/wine/libs/*/; do
    name=$(basename "$lib")
    files=$(find "$lib" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' \) | sort)
    [ -n "$files" ] && copy "wine-libs/$name" $files
done
copy dxvk "$proton/dxvk/LICENSE"
for sub in "$proton"/dxvk/subprojects/*/; do
    files=$(find "$sub" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) | sort)
    [ -n "$files" ] && copy "dxvk-$(basename "$sub")" $files
done
copy vkd3d-proton "$proton/vkd3d-proton/COPYING" "$proton/vkd3d-proton/LICENSE"
copy dxil-spirv $(find "$proton/vkd3d-proton/subprojects/dxil-spirv" -maxdepth 1 -type f -iname 'LICENSE*' | sort)
copy mesa "$deps/mesa/docs/license.rst"
copy moltenvk "$deps/MoltenVK/LICENSE"
copy spirv-cross "$deps/SPIRV-Cross/LICENSE" "$deps/SPIRV-Cross/LICENSES"
copy freetype "$deps/freetype/LICENSE.TXT" "$deps/freetype/docs/FTL.TXT" "$deps/freetype/docs/GPLv2.TXT"
copy gmp "$deps/gmp-6.3.0/COPYING.LESSERv3" "$deps/gmp-6.3.0/COPYINGv2" "$deps/gmp-6.3.0/COPYINGv3"
copy nettle "$deps/nettle-4.0/COPYING.LESSERv3" "$deps/nettle-4.0/COPYINGv2" "$deps/nettle-4.0/COPYINGv3"
copy gnutls "$deps/gnutls-3.8.13/COPYING.LESSERv2" "$deps/gnutls-3.8.13/COPYING"
copy sdl2 "$deps/SDL2-2.32.10/LICENSE.txt"

rev() { git -C "$proton" ls-tree HEAD "$1" | awk '{print $3}'; }

cat > "$out/README.md" <<EOF
# Third-party software in MacProton

MacProton is not affiliated with, endorsed or sponsored by Valve Corporation.
Steam and Proton are trademarks of Valve Corporation. All other trademarks
belong to their owners.

MacProton.app ships the software below. Each directory here holds its
license texts. The complete corresponding source code of every release is the
MacProton repository at that release's tag: the components below are pinned
to the versions listed, and macos/patches holds every change MacProton makes
to them; macos/build.sh fetches, patches and builds them.

| Component | License | Version | Source |
|---|---|---|---|
| Proton, lsteamclient, steam.exe (Valve) | BSD 3-clause; lsteamclient also Steamworks SDK license | this repository | https://github.com/ValveSoftware/Proton |
| Wine (Valve's fork) | LGPL 2.1 or later; bundled libraries see wine-libs | $(rev wine) | https://github.com/ValveSoftware/wine |
| DXVK | zlib | $(rev dxvk) | https://github.com/doitsujin/dxvk |
| vkd3d-proton | LGPL 2.1 or later; dxil-spirv MIT | $(rev vkd3d-proton) | https://github.com/HansKristian-Work/vkd3d-proton |
| Mesa (KosmicKrisp, Zink) | MIT and others, see mesa/license.rst | $MESA_COMMIT | https://gitlab.freedesktop.org/mesa/mesa |
| MoltenVK | Apache 2.0 | $MOLTENVK_COMMIT | https://github.com/KhronosGroup/MoltenVK |
| SPIRV-Cross (in MoltenVK) | Apache 2.0 | as pinned by MoltenVK | https://github.com/KhronosGroup/SPIRV-Cross |
| FreeType | FreeType License (FTL) or GPL 2.0 | $FREETYPE_TAG | https://gitlab.freedesktop.org/freetype/freetype |
| GMP | LGPL 3.0 or GPL 2.0 | $(basename "$GMP_URL") | $GMP_URL |
| Nettle | LGPL 3.0 or GPL 2.0 | $(basename "$NETTLE_URL") | $NETTLE_URL |
| GnuTLS | LGPL 2.1 or later | $(basename "$GNUTLS_URL") | $GNUTLS_URL |
| SDL2 | zlib | $(basename "$SDL2_URL") | $SDL2_URL |

Portions of this software are copyright © The FreeType Project
(https://freetype.org). All rights reserved.

The LGPL libraries are separate dynamic libraries and Wine modules inside
MacProton.app/Contents/Resources; they can be replaced by versions built from
modified sources.

MacProton downloads Valve's steamcmd and the Steamworks SDK redistributables
from Valve's servers on the user's Mac when needed; it does not ship them.
EOF

echo "collected $(find "$out" -type f | wc -l | tr -d ' ') files into $out"
