# Proton auf macOS – Portierungs-Roadmap

Branch: `macos-port` (abgezweigt von `proton_11.0`)

## Zielbild

Windows-Spiele aus Steam auf Apple-Silicon-Macs starten, mit derselben
Struktur wie Proton unter Linux: Wine + Übersetzungsschichten für DirectX +
Brücke zum nativen Steam-Client + `proton`-Startskript.

## Architekturentscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| CPU-Architektur | Wine als **x86_64**, läuft unter **Rosetta 2**; 32-Bit über **WoW64** (`--enable-archs=i386,x86_64`) | Windows-Spiele sind x86-Code. Natives arm64-Wine auf macOS wird upstream nicht unterstützt (16K-Seiten, ABI). So machen es auch CrossOver und GPTK. |
| Emulator | FEX entfällt | Rosetta 2 übernimmt die Rolle. |
| Fenster/Eingabe | `winemac.drv` statt `winex11.drv`/`winewayland.drv` | Ist im Wine-Baum bereits vorhanden. |
| D3D9–11 | DXVK über **MoltenVK** | Einzige quelloffene Option. Lücken: Geometry Shader, Transform Feedback, einige Formate. |
| D3D12 | offen (siehe Phase 4) | vkd3d-proton braucht Vulkan-Features, die MoltenVK fehlen. |
| Sync-Primitive | fsync/ntsync auf macOS deaktiviert, Fallback auf wineserver-Sync; später msync-artige Lösung über Mach-Semaphoren | fsync basiert auf Linux-`futex_waitv`, ntsync auf einem Linux-Kernelmodul. |
| Build | nativer Build auf macOS statt Docker/Steam-Runtime-Container | Der Linux-Container erzeugt keine Mach-O-Binärdateien. |

## Phasen

### Phase 1 – Wine baut und läuft (in Arbeit)
- [x] Kern-Submodule geholt (`wine`, `dxvk`, `vkd3d-proton`, `vkd3d`, Header, `glslang`)
- [x] Generierte Quellen (`make_vulkan`, `make_specfiles`) und `configure` erzeugt
- [x] Protons Wine konfiguriert sich für macOS x86_64 + WoW64 (minimale Abhängigkeiten)
- [x] Wine kompiliert vollständig (x86_64-Unix + i386/x86_64-PE, ~22 min auf Apple Silicon)
- [x] Prefix anlegen, 64-Bit- und 32-Bit-(WoW64-)Programme laufen unter Rosetta, `notepad` öffnet über `winemac.drv`
- [ ] `WINEDLLOVERRIDES="mscoree,mshtml="` ist Pflicht beim Anlegen des Prefix, sonst hängt `wineboot` am Mono/Gecko-Dialog → ins `proton`-Skript übernehmen (macht Proton unter Linux ebenso)

Bisherige Wine-Anpassungen für macOS (alle per `#ifdef` bzw. configure, Linux-Verhalten unverändert):

| Datei | Änderung |
|---|---|
| `server/fsync.c`, `dlls/ntdll/unix/fsync.c` | Futex-Syscalls nur unter Linux, sonst `ENOSYS` (fsync wird auf macOS nie aktiviert) |
| `server/inproc_sync.c`, `dlls/ntdll/unix/sync.c` | `ntsync_tmp.h` nur unter Linux → vorhandener Fallback greift |
| `dlls/ntdll/unix/loader.c` | `malloc.h`/`mallopt(M_PERTURB)` nur mit glibc |
| `dlls/ntdll/unix/signal_x86_64.c` | `set_thread_teb` nur unter Linux (macOS setzt %gs in `init_syscall_frame`); `jmp *%rcx` statt `jmp %rcx` |
| `dlls/ntdll/unix/system.c` | sysfs-Helfer für `WINE_CPU_TOPOLOGY` außerhalb Linux als Stubs |
| `dlls/amd_ags_x64/unixlib.c` | libdrm/amdgpu optional, sonst `STATUS_NOT_SUPPORTED` |
| `dlls/win32u/opengl.c` | fshack-Framebuffer-Surfaces ohne EGL als inaktive Stubs |
| `dlls/winegstreamer/media-converter/media-converter.h` | fehlendes `#include <pthread.h>` |
| `configure.ac` | `loader64` auf Darwin deaktiviert |
| `server/token.c` | Benutzer-SID aus Hardware-UUID (`gethostuuid`) statt `/etc/machine-id` |
| `include/wine/server_protocol.h` u. a. | per `tools/make_requests` neu erzeugt |
- [ ] x86_64-Abhängigkeiten nachziehen (FreeType, GnuTLS, MoltenVK, SDL2), z. B. über ein x86_64-Homebrew unter `/usr/local` oder eigene Builds

### Phase 2 – Build-System
- [ ] `configure.sh` / `Makefile.in`: Ziel `darwin` ergänzen, Docker-Pfad umgehen
- [ ] Komponenten, die nur unter Linux Sinn ergeben, abschaltbar machen (FEX, gstreamer-Teile, kaldi/vosk/piper, wineopenxr, vrclient)
- [ ] `install_name_tool`/rpath-Behandlung statt `LD_LIBRARY_PATH`
- [ ] Ausgabe als portabler Ordner bzw. `.app`-Bundle

### Phase 3 – Grafik D3D9–11

Gemessen (Apple M3, MoltenVK 1.4.2, Vulkan 1.3.357): MoltenVK erfüllt
Vulkan 1.3 fast vollständig, für **DXVK 2.7.1** fehlen aber Pflicht-Features –
DXVK lehnt das Gerät damit komplett ab:

| Fehlt in MoltenVK | Verwendung in DXVK | Pflicht ab |
|---|---|---|
| `geometryShader` | Geometry Shader | D3D9-Baseline |
| `shaderCullDistance` | Cull Distances | D3D9-Baseline |
| `nullDescriptor`, `robustBufferAccess2` | ungebundene Ressourcen | D3D9-Baseline |
| `VK_EXT_depth_clip_enable` | Depth Clipping | alle |
| `transformFeedback` | Stream Output | D3D11 |

Prüfprogramme: `docs/macos/mvkcheck.c` (Features), `docs/macos/d3d11-nulltest.c` (ungebundene Ressourcen, Swapchain), `docs/macos/d3d11-blendtest.c` (Blending, Texturen, Sampler, Constant Buffer), `docs/macos/d3d11-geomtest.c` (Vertex-/Index-Buffer, Reversed-Z auf D16/D24S8/D32/D32S8).

**DXVK-Anpassungen** (aktiv nur auf Portability-Geräten: `VK_KHR_portability_subset`
oder Treiber-ID `VK_DRIVER_ID_MOLTENVK` – Wine reicht die Erweiterung nicht an
Windows-Programme durch; auf Linux bleibt DXVK unverändert streng):

| Feature | Ersatzlösung |
|---|---|
| `geometryShader`, `shaderCullDistance` | optional; nur Shader, die sie nutzen, schlagen fehl |
| `depthClipEnable` | Näherung über `depthClampEnable = !depthClip` (wie DXVK 1.x) |
| `nullDescriptor`, `robustBufferAccess2` | `DxvkNullResources`: null-initialisierte Platzhalter (Puffer, Texel-Views, 1D/2D/3D/Cube-Bilder) pro Kontext, initialisiert im Init-Kommandopuffer |
| `transformFeedback` | war in D3D11 schon optional |

Ergebnis (Apple M3): DXVK erzeugt ein D3D11-Gerät mit **Feature Level 11_0**
(11_1 scheitert an `logicOp`, das Metal nicht hat). Testprogramm
`docs/macos/d3d11-nulltest.c`: ungebundene Textur/Constant Buffer lesen exakt 0,
120 Frames über die Swapchain – alles bestanden.

**wined3d** (Wines eigene D3D-Übersetzung über Apples OpenGL 4.1):
D3D9-Visual-Tests 211.215 Prüfungen mit 47 (64 Bit) bzw. 48 (32 Bit) Fehlern,
D3D11-Tests 4.006 Prüfungen mit 15 Fehlern. **Feature Level 11_0 erreicht
wined3d auf macOS nicht** – für D3D11-Spiele ist DXVK nötig.

Wines eigene D3D11-Testsuite ist für DXVK nicht aussagekräftig: Sie stürzt im
D3D10-Interop-Pfad (`ID3D10Texture3D_GetDevice`) ab – unabhängig von MoltenVK.

- [ ] winevulkan → MoltenVK (x86_64-Build von MoltenVK nötig)
- [ ] DXVK mit MinGW für macOS bauen, MoltenVK-Fehlstellen per Konfiguration abfangen
- [ ] Testspiele aus DX9, DX10, DX11 festlegen und Kompatibilität protokollieren

### Phase 4 – D3D12
Optionen, zu bewerten:
1. vkd3d-proton auf MoltenVK mit fehlenden Features als Workarounds (hoher Aufwand, unsicherer Ausgang)
2. Apples D3DMetal aus dem Game Porting Toolkit als optionale Laufzeitkomponente einbinden (nicht quelloffen, Lizenz prüfen, nicht weitergebbar)
3. eigener D3D12→Metal-Übersetzer (sehr hoher Aufwand)

### Phase 5 – Steam-Integration
- [x] `lsteamclient`: Es gibt schon einen `__APPLE__`-Zweig in `lsteamclient/unixlib.cpp`, der `steamclient.dylib` lädt. Geprüft: Der macOS-Steam-Client liefert `steamclient.dylib` als Universal Binary (x86_64 + arm64), der Rosetta-Wineprozess kann sie also laden.
- [x] `Steam_IsKnownInterface` und `Steam_NotifyMissingInterface` fehlen in der macOS-dylib → auf macOS optional geladen (Fallback: `false` bzw. nichts tun), damit `steamclient_init` nicht abbricht
- [x] lsteamclient und steam_helper (`steam.exe`) für macOS bauen – `macos/makedep-module.py` ersetzt die GNU-sed-basierten Makedep-Regeln
- [x] `steamclient64.dll`/`steamclient.dll` im Prefix sind Kopien von `lsteamclient.dll`: Mac-Steam liefert keine Windows-Versionen, Wines Loader leitet sie per Trampolin auf lsteamclient um
- [x] **Cult of the Lamb** (Unity, D3D11) läuft mit Steamworks über den laufenden Mac-Steam-Client bis ins Hauptmenü, 60 FPS (Apple M3) – Start über `macos/dev-run.sh`

Anpassungen dafür:

| Datei | Änderung |
|---|---|
| `lsteamclient/unix_private.h` | `stdlib.h`/`wchar.h` vor `winbase.h`, das `wcsncpy` & Co. mit `__WINESRC__` sperrt (macOS-SDK lädt `wchar.h` später als glibc) |
| `lsteamclient/unixlib.cpp` | `(std::max)` gegen Wines `max()`-Makro |
| `lsteamclient/unix_steam_input_manual.cpp` | VK→macOS-Tastencodes (`kVK_*`) für ISteamHTMLSurface |
| `dxvk/src/dxvk/dxvk_presenter.cpp` | MoltenVK: `VK_PRESENT_SCALING_STRETCH` anfordern, sonst `VK_SUBOPTIMAL_KHR` bei jedem Present und Swapchain-Neuerzeugung in Dauerschleife (Flackern) |
| `wine/dlls/win32u/{vulkan,opengl}.c` | Protons Fullscreen-Hack auf macOS standardmäßig aus (`WINE_DISABLE_FULLSCREEN_HACK=0` schaltet ihn ein): mit ihm erreicht das Bild das Fenster nicht, sichtbar war nur die Hintergrundfarbe |
- [ ] Steam für macOS bietet keine Kompatibilitätstools an → Starten über eigenes Startprogramm oder Windows-Steam im Prefix als Notlösung
- [ ] `vrclient_x64`, `wineopenxr`: auf macOS weglassen

### Phase 6 – `proton`-Startskript
Linux-Annahmen im Skript `proton`:
- `LD_LIBRARY_PATH` (Zeile ~48) → `DYLD_FALLBACK_LIBRARY_PATH`
- `libdl.so.2`, `libGLX_nvidia.so.0` (~415–460) → auf macOS überspringen
- `/proc/modules`, `/proc/sys/vm/max_map_count` (~1421, ~2012) → überspringen
- `WINEFSYNC`/ntsync-Logik (~1766–1784) → auf macOS aus
- Steam-Runtime/pressure-vessel-Annahmen entfernen

### Phase 7 – Verteilung über GitHub
Ziel: Nutzer laden ein Release von GitHub herunter, entpacken es und starten
– ohne Xcode, Homebrew oder eigenen Build.

- [ ] **GitHub Actions** auf macOS-Runnern (`macos-14`/Apple Silicon) bauen
      das Paket reproduzierbar; Ergebnis als Asset an **GitHub Releases**
- [ ] **Keine Laufzeit-Abhängigkeit von Homebrew**: alle x86_64-dylibs
      (FreeType, GnuTLS, MoltenVK, SDL2 …) ins Paket legen, Pfade per
      `install_name_tool` auf `@rpath`/`@loader_path` umbiegen
- [ ] Ein einziges, selbsttragendes Paket (`.app` bzw. `.tar.xz` mit festem
      Ordnerlayout), das dem Linux-Proton-Layout (`files/bin`, `files/lib`,
      `files/share`) folgt
- [ ] **Code-Signierung + Notarisierung** (Developer-ID); ohne das blockiert
      Gatekeeper die heruntergeladenen Binärdateien. Fallback für unsignierte
      Testbuilds: dokumentiertes `xattr -dr com.apple.quarantine`
- [ ] Rosetta-Prüfung beim ersten Start (`softwareupdate --install-rosetta` vorschlagen)
- [ ] Versionierung und Prüfsummen (`SHA256SUMS`) je Release
- [ ] Lizenzen: Wine (LGPL), DXVK/vkd3d-proton (zlib/LGPL), MoltenVK
      (Apache-2.0) beilegen. **D3DMetal darf nicht mitgeliefert werden** –
      falls genutzt, nur als optionaler Import aus der lokalen GPTK-Installation
- [ ] Installationsskript, das das Paket an einen festen Ort legt
      (z. B. `~/Library/Application Support/MacProton/<version>`)

## Speicherplatz

Auf dem Entwicklungs-Mac sind nur rund 37 GB frei. Ein vollständiger
Proton-Build (alle Submodule, alle Architekturen) braucht deutlich mehr. Bis
mehr Platz da ist, werden nur die Kernkomponenten geholt und gebaut.

## Build (Stand Phase 1)

```bash
# einmalig
brew install bison flex mingw-w64 autoconf automake molten-vk vulkan-loader gnutls
git submodule update --init --depth 1 wine dxvk vkd3d-proton vkd3d Vulkan-Headers SPIRV-Headers glslang
cd wine && python3 dlls/winevulkan/make_vulkan -x vk.xml -X video.xml && tools/make_specfiles \
  && tools/make_requests && autoreconf -fi && cd ..

# Konfigurieren und bauen (außerhalb des Quellbaums)
mkdir -p ../build/wine64 && cd ../build/wine64
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
# Architektur explizit setzen: ohne --build/--host erkennt configure auf
# Apple Silicon "aarch64" (z. B. bei config.status --recheck)
../../Proton/wine/configure --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
  CC="clang -arch x86_64" --enable-archs=i386,x86_64 \
  --without-x --without-wayland --without-freetype --without-gnutls --without-vulkan \
  --without-sdl --without-gstreamer --without-pulse --without-alsa --without-oss \
  --without-udev --without-dbus --without-v4l2
# nativ bauen – NICHT mit "arch -x86_64", sonst laufen Compiler unter Rosetta
make -j"$(sysctl -n hw.ncpu)"
```
