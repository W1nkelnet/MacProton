# MacProton

Play the Windows games of your Steam library on the Mac. MacProton is a Mac
app based on Valve's [Proton](README.proton.md): Wine with DXVK and
vkd3d-proton, which translate Direct3D to Vulkan, and Mesa's KosmicKrisp,
which translates Vulkan to Metal. MoltenVK is available as a fallback driver.

MacProton is an independent project. It is not affiliated with, endorsed or
sponsored by Valve Corporation.

## What MacProton does

- **Library sync:** Imports the games of your Steam account without you
  entering app IDs.
- **Native Mac versions:** If a game also exists for macOS, MacProton
  installs and starts it through the Steam client, without Wine.
- **Windows games:** Downloads them with Valve's steamcmd and runs them with
  Wine. Direct3D 9, 10, 11 and 12 are supported, in 32-bit games too.
- **Downloads:** A tab of its own shows the queue. Downloads can be paused
  and resumed, even after a restart.
- **Location:** Games can live on an external drive, per game with a
  right-click on “Install In …” or as the default folder in Settings.
  “Move …” relocates installed games.
- **Steam features in games:** Games talk to the Steam client, tested with
  lobbies. Online features using TLS work as well.
- **Saves through the Steam Cloud:** For games whose Windows and Mac
  versions share their saves. Both are backed up first.
- **Controllers:** Through SDL2. Tested with an Xbox Wireless Controller
  over Bluetooth.
- **Warnings:** Marks games with anti-cheat, third-party launchers or an
  online requirement.
- **English and German:** The app follows the language of macOS. It can be
  changed on the first start and in Settings.

## Requirements

- macOS 14 or later on a Mac with Apple silicon (tested on an M3). Intel
  Macs are untested. KosmicKrisp, the default graphics driver and the one
  Direct3D 12 needs, requires macOS 26; on older systems MacProton uses
  MoltenVK.
- Rosetta 2. If it is missing, MacProton offers to install it.
- Steam for Mac, signed in and running.

## Installation

1. Download `MacProton-….zip` from [Releases](../../releases), unzip it and
   drag `MacProton.app` into the Applications folder.
2. **Allow it once.** MacProton is not notarized by Apple, which requires a
   paid Apple developer account, so macOS asks on the first start. First
   check that the download is unchanged. The value must match the file
   `MacProton-….zip.sha256` of the release:

   ```bash
   shasum -a 256 ~/Downloads/MacProton-*.zip
   ```

   Then allow opening it in the macOS dialog, if necessary under System
   Settings → Privacy & Security → “Open Anyway”. Alternatively remove the
   “downloaded from the internet” mark of this app yourself:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacProton.app
   ```

   Only do this if you trust the source. The command affects only
   `MacProton.app`.
3. Start MacProton. A welcome screen guides you through the setup: the app
   downloads Valve's steamcmd from Valve's servers, checks its signature and
   shows the progress. steamcmd then updates itself once.
4. Sign in with “Sign In to Steam”. Your password and the Steam Guard code
   go only to steamcmd. steamcmd then remembers a sign-in token; the
   password is not stored.
5. Click “Let's Go”. MacProton then imports your games from Steam.

## Good to know

- **Steam goes offline briefly:** Steam allows only one session per account
  on a Mac. When steamcmd signs in, for example for a download, the Steam
  client loses its connection. MacProton then restarts Steam automatically
  so that lobbies and online features work again.
- **Windows version of a Mac game:** If you start it from the context menu,
  Steam considers the game installed until Steam restarts.
- **Locations:** Games, Wine prefixes, logs and backups are in
  `~/Library/Application Support/MacProton`.

## Known limitations

- Some 32-bit games crash on start, such as Rogue Tower (Unity).
- Direct3D 12 runs with KosmicKrisp in Rise of the Tomb Raider, Horizon Zero
  Dawn and Unreal Engine 5 games (tested with Town To City). Sparse
  resources, ray tracing and mesh shaders are missing; performance is often
  tight on smaller Macs, and the first start takes a while until the shaders
  are compiled.
- Games that need OpenGL 4.2 or later (such as Foundation) do not start
  with macOS's own OpenGL, which stops at 4.1; Mesa's Zink, selectable in a
  game's launch options, offers OpenGL 4.6 on KosmicKrisp.
- Games with anti-cheat (Easy Anti-Cheat, BattlEye) mostly do not work
  online.
- Third-party launchers such as the EA app or Ubisoft Connect are not
  supported.
- Direct3D 11 is available up to feature level 11_0 on MoltenVK and 11_1 on
  KosmicKrisp, because Metal has no logic blend operations.

## Building

You need Xcode and Homebrew:

```bash
brew install bison flex mingw-w64 autoconf automake meson ninja glslang pkgconf
```

```bash
macos/build.sh ~/macproton-build
```

```bash
macos/app/build-app.sh ~/macproton-app ~/macproton-build/dist
```

`build.sh` downloads the dependencies (Mesa, MoltenVK, FreeType, GMP,
Nettle, GnuTLS, SDL2) in pinned versions from their official sources and
checks their checksums. The changes to Wine, DXVK, vkd3d-proton, Mesa and
MoltenVK are patches in `macos/patches`. When a component or its version
changes, `macos/collect-licenses.sh` collects the license texts into
`macos/licenses` again, which `build-app.sh` puts into the app. The app's
texts are German; the English ones are in `macos/app/Localization/en.py`.
Details of the port are in [docs/MACOS_PORT.md](docs/MACOS_PORT.md).

A release is made locally: tag the commit with `git tag -a vX.Y.Z`, put the
release notes into `macos/release-notes/vX.Y.Z.md` and run

```bash
macos/release.sh ~/macproton-build/dist
```

The script builds the app, zips it with a checksum and publishes it as a
GitHub release with `gh`.

## Licenses and source code

Like Proton, MacProton is covered by several licenses, see
[LICENSE](LICENSE). Valve's Proton code is under the BSD license in
[LICENSE.proton](LICENSE.proton), MacProton's own code (app, scripts and
documentation in `macos/`) under the BSD license in
[LICENSE.macproton](LICENSE.macproton). The patches in `macos/patches` are
under the license of the project they change. The app contains third-party
software, among it Wine, vkd3d-proton, GnuTLS, GMP and Nettle (LGPL), Mesa
(MIT), MoltenVK (Apache 2.0), DXVK and SDL2 (zlib) and FreeType (FreeType
License). An overview with versions and sources and all license texts are in
[macos/licenses](macos/licenses/README.md); in the app, the menu item
MacProton › Licenses … opens them.

The complete source code of every version is this repository at the
release's tag: all components are pinned to fixed versions, every change to
them is a patch in `macos/patches`, and `macos/build.sh` builds exactly the
shipped runtime from them. The LGPL libraries are separate files in the app
and can be replaced by ones you build yourself.

## Warranty and trademarks

MacProton is provided without any warranty, see the license texts. You use
it at your own risk, including for your Steam account and your saves;
MacProton backs up saves before every sync with the Steam Cloud.

MacProton is not a product of Valve or Apple and is affiliated with neither.
Steam, steamcmd and Proton are trademarks or software of Valve Corporation,
Metal and macOS are trademarks of Apple Inc. MacProton downloads steamcmd
and the Steamworks runtime libraries directly from Valve's servers when
needed and does not ship them itself.
