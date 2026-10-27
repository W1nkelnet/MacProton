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
- [x] x86_64-Abhängigkeiten selbst gebaut (Homebrew bietet keine Intel-Bottles mehr): MoltenVK, FreeType, GMP, nettle, GnuTLS – alle in `macos/build.sh`, Tarballs gegen feste SHA-256-Summen geprüft
- [x] GnuTLS: ohne es scheitern in Wine die Signaturprüfung von Zertifikaten (`bcrypt: key_asymmetric_create no encryption support`) und HTTPS über schannel. Folge im Spiel war `Curl error 60: Cert verify failed` (UnityTls nutzt den Windows-Zertifikatsspeicher und dessen Prüfung). Test: `docs/macos/tls-check.c`
- [ ] SDL2 (Controller) nachziehen

Hinweis zum Testen: `DYLD_*`-Variablen überleben den Start SIP-geschützter Programme nicht (`/bin/sh`, `/usr/bin/timeout`, `/usr/bin/env`). Sie müssen nach solchen Programmen gesetzt werden – `run.sh` tut das selbst.

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
- [x] `steamclient64.dll`/`steamclient.dll` im Prefix sind Stub-DLLs (`macos/steamclient-stub.py`), die nur die Namen aus `lsteamclient.spec` exportieren: Mac-Steam liefert keine Windows-Versionen, Wines Loader biegt die Exporte per Trampolin auf lsteamclient um. Kopien von `lsteamclient.dll` funktionieren nicht zuverlässig – Wine hält die Kopie dann selbst für lsteamclient und leitet auf sich selbst um (Endlosschleife in `CreateInterface`)
- [x] **Cult of the Lamb** (Unity, D3D11) läuft mit Steamworks über den laufenden Mac-Steam-Client bis ins Hauptmenü, 60 FPS (Apple M3) – Start über `macos/run.sh`, auch mit frischem Prefix aus `macos/build.sh`

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

### Offene Punkte (To-do)

- [ ] **Spielstand-Sync (Steam Cloud):** Spiele mit Auto-Cloud haben pro Betriebssystem eigene Speicherpfade (`ufs/rootoverrides` in den App-Infos). Mac-Steam synchronisiert nur den Mac-Pfad (z. B. `~/Library/Application Support/Massive Monster/Cult Of The Lamb/saves`), die Windows-Version speichert im Prefix (`AppData/LocalLow/...`). Plan: Gibt es eine Windows- und eine MacOS-Regel, leitet MacProton den Prefix-Ordner auf den Mac-Pfad um – vorher Backup beider Seiten. Spiele mit ISteamRemoteStorage sollten bereits über lsteamclient synchronisieren (ungetestet). Reine Windows-Spiele mit Auto-Cloud: offen.
- [ ] **Controller-Unterstützung:** SDL2 als x86_64-Abhängigkeit bauen und Wine (winebus/dinput/xinput) damit konfigurieren.
- [x] **Bibliothek-Sync** (MacProton-App): `licenses_print` → abgekürzte Pakete per `package_info_print` → `app_info_print` je App in einer interaktiven steamcmd-Sitzung (über die Kommandozeile gereihte Abfragen liefert steamcmd asynchron und gibt nur die erste aus). Filter: Typ `game` mit Windows-Startdatei; Paket 0 (Steams Werkzeuge/Server) ausgenommen. Testkonto: 312 Apps → 70 Windows-Spiele, davon 28 auch nativ für Mac, ~26 s.
- [ ] Spiele mit Anti-Cheat (EasyAntiCheat, BattlEye) und Fremd-Launchern (Ubisoft Connect, EA App) erkennen und kennzeichnen
- [ ] **Steam-Overlay:** Shop/Profil öffnen sich derzeit im Steam-Fenster.

## Speicherplatz

Auf dem Entwicklungs-Mac sind nur rund 37 GB frei. Ein vollständiger
Proton-Build (alle Submodule, alle Architekturen) braucht deutlich mehr. Bis
mehr Platz da ist, werden nur die Kernkomponenten geholt und gebaut.

## Build und Start

```bash
# einmalig
brew install bison flex mingw-w64 autoconf automake meson ninja glslang cmake pkgconf

# alles bauen (Wine, MoltenVK, FreeType, DXVK 64/32 Bit, lsteamclient, steam.exe)
macos/build.sh ../build-macos

# Spiel starten (Steam muss laufen und angemeldet sein)
../build-macos/dist/run.sh 1313140 /pfad/zu/CultOfTheLamb "Cult Of The Lamb.exe"
```

`build.sh` überspringt fertige Schritte (Stempel in `BUILD_DIR/stamps`),
`DEPS_SRC` verweist auf vorhandene MoltenVK-/FreeType-Klone. Ergebnis ist
`BUILD_DIR/dist` mit `files/` im Proton-Layout und dem Starter `run.sh`, der
pro App-ID einen Prefix unter `~/Library/Application Support/MacProton/prefixes`
anlegt, DXVK und die `steamclient`-Kopien einrichtet und das Spiel über
`steam.exe` startet.

Fallstricke, die die Skripte abfangen:
- `configure` braucht `--build/--host=x86_64-apple-darwin`, sonst erkennt es auf Apple Silicon `aarch64`
- `make` nativ ausführen, nicht mit `arch -x86_64` (sonst laufen die Compiler unter Rosetta)
- Wines generierte Dateien vorab erzeugen: `make_vulkan`, `make_specfiles`, `make_requests`, `autoreconf`
- `pkg-config` auf die x86_64-Abhängigkeiten beschränken (`PKG_CONFIG_LIBDIR`), sonst findet es arm64-Homebrew-Bibliotheken
