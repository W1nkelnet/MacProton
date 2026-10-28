# MacProton

Windows-Spiele aus deiner Steam-Bibliothek auf dem Mac spielen. MacProton
ist eine Mac-App auf Basis von Valves [Proton](README.proton.md): Wine
mit DXVK und vkd3d-proton, die Direct3D auf Vulkan umsetzen, und MoltenVK,
das Vulkan auf Metal umsetzt.

## Was MacProton kann

- **Bibliothek abgleichen:** Übernimmt die Spiele deines Steam-Kontos,
  ohne dass du App-IDs eingeben musst.
- **Mac-Versionen nativ:** Gibt es ein Spiel auch für macOS, installiert
  und startet MacProton es über den Steam-Client, ganz ohne Wine.
- **Windows-Spiele:** Lädt sie mit Valves steamcmd und startet sie mit
  Wine. Unterstützt werden Direct3D 9, 10 und 11, Direct3D 12 erst in
  Teilen.
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

- 32-Bit-Windows-Spiele stürzen derzeit beim Start ab. Betroffen sind vor
  allem ältere Unity-Spiele.
- Direct3D 12 ist neu und bisher nur mit einem eigenen Test geprüft, mit
  keinem Spiel. MoltenVK fehlen dafür unter anderem Sparse-Ressourcen,
  64-Bit-Atomics auf Texturen, Geometry Shader und Stream Output.
  Unreal-Engine-5-Spiele lehnen Direct3D 12 deshalb ab und laufen weiter mit
  Direct3D 11.
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

`build.sh` lädt die Abhängigkeiten (MoltenVK, FreeType, GMP, Nettle,
GnuTLS, SDL2) aus ihren offiziellen Quellen und prüft die Prüfsummen. Die
Änderungen an Wine, DXVK, vkd3d-proton und MoltenVK liegen als Patches in
`macos/patches`.
Details zum Port stehen in [docs/MACOS_PORT.md](docs/MACOS_PORT.md).

Ein Release entsteht lokal: Commit mit `git tag -a vX.Y.Z` markieren,
Release-Notes in `macos/release-notes/vX.Y.Z.md` ablegen und dann

```bash
macos/release.sh ~/macproton-build/dist
```

ausführen. Das Skript baut die App, packt sie mit Prüfsumme und
veröffentlicht sie per `gh` als GitHub-Release.

## Lizenzen

MacProton steht wie Proton unter mehreren Lizenzen, siehe
[LICENSE](LICENSE). Wine, vkd3d-proton und GnuTLS stehen unter der
LGPL 2.1, DXVK unter der zlib-Lizenz, MoltenVK unter der Apache-Lizenz 2.0. Der Quellcode aller
mitgelieferten Teile ist über dieses Repository, seine Submodule und die
Patches in `macos/patches` verfügbar.

MacProton ist kein Produkt von Valve oder Apple. Steam und steamcmd sind
Marken bzw. Software der Valve Corporation.
