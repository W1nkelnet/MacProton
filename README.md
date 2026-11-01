# MacProton

Windows-Spiele aus deiner Steam-Bibliothek auf dem Mac spielen. MacProton
ist eine Mac-App auf Basis von Valves [Proton](README.proton.md): Wine
mit DXVK und vkd3d-proton, die Direct3D auf Vulkan umsetzen, und Mesas
KosmicKrisp, das Vulkan auf Metal umsetzt. MoltenVK steht als Ausweich-Treiber
bereit.

MacProton ist ein unabhängiges Projekt. Es ist nicht mit der Valve
Corporation verbunden und wird von ihr weder unterstützt noch gesponsert.

## Was MacProton kann

- **Bibliothek abgleichen:** Übernimmt die Spiele deines Steam-Kontos,
  ohne dass du App-IDs eingeben musst.
- **Mac-Versionen nativ:** Gibt es ein Spiel auch für macOS, installiert
  und startet MacProton es über den Steam-Client, ganz ohne Wine.
- **Windows-Spiele:** Lädt sie mit Valves steamcmd und startet sie mit
  Wine. Unterstützt werden Direct3D 9, 10, 11 und 12, auch in
  32-Bit-Spielen.
- **Downloads:** Ein eigener Reiter zeigt die Warteschlange. Downloads
  lassen sich pausieren und fortsetzen, auch nach einem Neustart.
- **Speicherort:** Spiele können auf einer externen Festplatte liegen,
  per Rechtsklick „Installieren in …“ oder als Standardordner in den
  Einstellungen. „Verschieben …“ zieht installierte Spiele um.
- **Steam-Funktionen im Spiel:** Die Spiele sprechen mit dem Steam-Client,
  getestet mit Lobbys. Online-Funktionen mit TLS laufen ebenfalls.
- **Spielstände über Steam Cloud:** Für Spiele, deren Windows- und
  Mac-Version dieselben Spielstände nutzen. Vorher werden beide gesichert.
- **Controller:** Über SDL2. Getestet ist ein Xbox Wireless Controller
  per Bluetooth.
- **Hinweise:** Markiert Spiele mit Anti-Cheat, fremden Launchern oder
  Online-Pflicht.
- **Deutsch und Englisch:** Die App folgt der Sprache von macOS. Beim
  ersten Start und in den Einstellungen lässt sie sich umstellen.

## Voraussetzungen

- macOS 14 oder neuer auf einem Mac mit Apple-Chip (getestet auf M3).
  Intel-Macs sind ungetestet.
- Rosetta 2. Fehlt es, bietet MacProton die Installation an.
- Steam für Mac, angemeldet und gestartet.

## Installation

1. Lade `MacProton-….zip` unter
   [Releases](../../releases) herunter, entpacke es und zieh
   `MacProton.app` in den Ordner „Programme“.
2. **Einmal freigeben.** MacProton ist nicht von Apple notarisiert. Das
   setzt ein kostenpflichtiges Apple-Entwicklerkonto voraus. macOS fragt
   deshalb beim ersten Öffnen nach. Prüf zuerst, dass der Download
   unverändert ist. Der Wert muss mit der Datei `MacProton-….zip.sha256`
   aus dem Release übereinstimmen:

   ```bash
   shasum -a 256 ~/Downloads/MacProton-*.zip
   ```

   Erlaube dann das Öffnen im Dialog von macOS, notfalls unter
   Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“.
   Alternativ entfernst du die Markierung „aus dem Internet geladen“ für
   diese App selbst:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacProton.app
   ```

   Mach das nur, wenn du der Quelle vertraust. Der Befehl betrifft
   ausschließlich `MacProton.app`.
3. Starte MacProton. Ein Willkommensbildschirm führt durch die
   Einrichtung: Die App lädt Valves steamcmd von Valves Server, prüft
   dessen Signatur und zeigt den Fortschritt an. steamcmd aktualisiert sich
   danach einmal selbst.
4. Melde dich über „Bei Steam anmelden“ an. Dein Passwort und der
   Steam-Guard-Code gehen nur an steamcmd. steamcmd merkt sich danach ein
   Anmelde-Token, das Passwort wird nicht gespeichert.
5. Klick auf „Los geht's“. MacProton übernimmt dann deine Spiele aus Steam.

## Gut zu wissen

- **Steam ist kurz offline:** Steam erlaubt pro Mac nur eine Sitzung je
  Konto. Meldet sich steamcmd an, etwa für einen Download, verliert der
  Steam-Client seine Verbindung. MacProton startet Steam danach automatisch
  neu, damit Lobbys und Online-Funktionen wieder gehen.
- **Windows-Version eines Mac-Spiels:** Startest du sie über das
  Kontextmenü, hält Steam das Spiel bis zum nächsten Steam-Neustart für
  installiert.
- **Speicherorte:** Spiele, Wine-Prefixe, Protokolle und Sicherungen
  liegen unter `~/Library/Application Support/MacProton`.

## Bekannte Einschränkungen

- Einzelne 32-Bit-Spiele stürzen beim Start ab, etwa Rogue Tower (Unity).
- Direct3D 12 läuft mit KosmicKrisp in Rise of the Tomb Raider, Horizon Zero
  Dawn und Unreal-Engine-5-Spielen (getestet mit Town To City). Sparse-
  Ressourcen, Raytracing und Mesh Shader fehlen; die Leistung ist auf
  kleineren Macs oft knapp, und der erste Start dauert, bis die Shader
  übersetzt sind.
- Spiele, die OpenGL 4.2 oder neuer brauchen (etwa Foundation), starten
  nicht. macOS bietet höchstens OpenGL 4.1.
- Spiele mit Anti-Cheat (Easy Anti-Cheat, BattlEye) funktionieren online
  meist nicht.
- Fremde Launcher wie die EA-App oder Ubisoft Connect werden nicht
  unterstützt.
- Das Steam-Overlay fehlt.
- Direct3D 11 steht bis Feature Level 11_0 zur Verfügung, weil Metal keine
  logischen Blend-Operationen kennt.

## Selbst bauen

Du brauchst Xcode und Homebrew:

```bash
brew install bison flex mingw-w64 autoconf automake meson ninja glslang pkgconf
```

```bash
macos/build.sh ~/macproton-build
```

```bash
macos/app/build-app.sh ~/macproton-app ~/macproton-build/dist
```

`build.sh` lädt die Abhängigkeiten (Mesa, MoltenVK, FreeType, GMP, Nettle,
GnuTLS, SDL2) in festen Versionen aus ihren offiziellen Quellen und prüft
die Prüfsummen. Die Änderungen an Wine, DXVK, vkd3d-proton, Mesa und
MoltenVK liegen als Patches in `macos/patches`. Ändert sich eine
Komponente oder ihre Version, sammelt `macos/collect-licenses.sh` die
Lizenztexte neu nach `macos/licenses`, die `build-app.sh` in die App legt.
Details zum Port stehen in [docs/MACOS_PORT.md](docs/MACOS_PORT.md).

Ein Release entsteht lokal: Commit mit `git tag -a vX.Y.Z` markieren,
Release-Notes in `macos/release-notes/vX.Y.Z.md` ablegen und dann

```bash
macos/release.sh ~/macproton-build/dist
```

ausführen. Das Skript baut die App, packt sie mit Prüfsumme und
veröffentlicht sie per `gh` als GitHub-Release.

## Lizenzen und Quellcode

MacProton steht wie Proton unter mehreren Lizenzen, siehe
[LICENSE](LICENSE). Valves Proton-Code steht unter der BSD-Lizenz in
[LICENSE.proton](LICENSE.proton), MacProtons eigener Code (App, Skripte und
Doku in `macos/`) unter der BSD-Lizenz in
[LICENSE.macproton](LICENSE.macproton). Die Patches in `macos/patches`
stehen unter der Lizenz des Projekts, das sie ändern. Die App enthält
Software Dritter, unter anderem Wine, vkd3d-proton, GnuTLS, GMP und Nettle
(LGPL), Mesa (MIT), MoltenVK (Apache 2.0), DXVK und SDL2 (zlib) sowie
FreeType (FreeType License). Eine Übersicht mit Versionen und Quellen und
alle Lizenztexte liegen in [macos/licenses](macos/licenses/README.md); in der
App öffnet sie der Menüpunkt MacProton › Lizenzen …

Der vollständige Quellcode jeder Version ist dieses Repository am Tag des
Release: Alle Komponenten sind auf feste Versionen festgelegt, jede
Änderung an ihnen liegt als Patch in `macos/patches`, und `macos/build.sh`
baut daraus genau die ausgelieferte Laufzeitumgebung. Die LGPL-Bibliotheken
liegen als eigene Dateien in der App und lassen sich durch selbst gebaute
ersetzen.

## Haftung und Marken

MacProton wird ohne jede Gewährleistung bereitgestellt, siehe die
Lizenztexte. Die Nutzung erfolgt auf eigenes Risiko, auch für dein
Steam-Konto und deine Spielstände; MacProton sichert Spielstände vor jedem
Abgleich mit der Steam Cloud.

MacProton ist kein Produkt von Valve oder Apple und mit keinem der beiden
verbunden. Steam, steamcmd und Proton sind Marken bzw. Software der Valve
Corporation, Metal und macOS Marken von Apple Inc. MacProton lädt steamcmd
und die Steamworks-Laufzeitbibliotheken bei Bedarf direkt von Valves
Servern und liefert sie nicht selbst aus.
