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
| MacProton (app, scripts) | BSD 3-clause | this repository | this repository |
| Proton, lsteamclient, steam.exe (Valve) | BSD 3-clause; lsteamclient also Steamworks SDK license | this repository | https://github.com/ValveSoftware/Proton |
| Wine (Valve's fork) | LGPL 2.1 or later; bundled libraries see wine-libs | 674d3cddcbef8a2c5b9f579ab5f499ca007ac331 | https://github.com/ValveSoftware/wine |
| DXVK | zlib | 0cfe0898289fb11e3d8d0e1c62cd344b825b7d57 | https://github.com/doitsujin/dxvk |
| vkd3d-proton | LGPL 2.1 or later; dxil-spirv MIT | 4522cc1a8b1347f1ab1b0f7b14a23ed9444d95d1 | https://github.com/HansKristian-Work/vkd3d-proton |
| Mesa (KosmicKrisp, Zink) | MIT and others, see mesa/license.rst | daa925c3bc78697cc214317ee330a39d1acda19f | https://gitlab.freedesktop.org/mesa/mesa |
| MoltenVK | Apache 2.0 | 5189f8de86ec365860f63bf1da736815cfaea5cd | https://github.com/KhronosGroup/MoltenVK |
| SPIRV-Cross (in MoltenVK) | Apache 2.0 | as pinned by MoltenVK | https://github.com/KhronosGroup/SPIRV-Cross |
| FreeType | FreeType License (FTL) or GPL 2.0 | VER-2-14-3 | https://gitlab.freedesktop.org/freetype/freetype |
| GMP | LGPL 3.0 or GPL 2.0 | gmp-6.3.0.tar.xz | https://ftpmirror.gnu.org/gmp/gmp-6.3.0.tar.xz |
| Nettle | LGPL 3.0 or GPL 2.0 | nettle-4.0.tar.gz | https://ftpmirror.gnu.org/nettle/nettle-4.0.tar.gz |
| GnuTLS | LGPL 2.1 or later | gnutls-3.8.13.tar.xz | https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz |
| SDL2 | zlib | SDL2-2.32.10.tar.gz | https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz |

Portions of this software are copyright © The FreeType Project
(https://freetype.org). All rights reserved.

The LGPL libraries are separate dynamic libraries and Wine modules inside
MacProton.app/Contents/Resources; they can be replaced by versions built from
modified sources.

MacProton downloads Valve's steamcmd and the Steamworks SDK redistributables
from Valve's servers on the user's Mac when needed; it does not ship them.
