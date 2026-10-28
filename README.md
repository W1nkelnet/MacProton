# MacProton

Windows-Spiele aus deiner Steam-Bibliothek auf dem Mac spielen. MacProton
ist eine Mac-App auf Basis von Valves [Proton](README.proton.md): Wine
mit DXVK, das Direct3D auf Vulkan umsetzt, und MoltenVK, das Vulkan auf
Metal umsetzt.

## Was MacProton kann

- **Bibliothek abgleichen:** Übernimmt die Spiele deines Steam-Kontos,
  ohne dass du App-IDs eingeben musst.
- **Mac-Versionen nativ:** Gibt es ein Spiel auch für macOS, installiert
  und startet MacProton es über den Steam-Client, ganz ohne Wine.
- **Windows-Spiele:** Lädt sie mit Valves steamcmd und startet sie mit
  Wine. Unterstützt werden Direct3D 9, 10 und 11.
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
   setzt ein kostenpflichtiges Apple-Entwicklerkonto voraus. macOS
   blockiert deshalb die App und die mitgelieferte Wine-Laufzeit. Prüf
   zuerst, dass der Download unverändert ist. Der Wert muss mit der Datei
   `MacProton-….zip.sha256` aus dem Release übereinstimmen:

   ```bash
   shasum -a 256 ~/Downloads/MacProton-*.zip
   ```

   Entferne dann die Markierung „aus dem Internet geladen“ für diese App:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacProton.app
   ```

   Mach das nur, wenn du der Quelle vertraust. Der Befehl betrifft
   ausschließlich `MacProton.app`.
3. Starte MacProton. Beim ersten Start lädt die App Valves steamcmd von
   Valves Server und prüft dessen Signatur. steamcmd aktualisiert sich
   danach einmal selbst.
4. Melde dich im Anmeldefenster bei Steam an. Dein Passwort und der
   Steam-Guard-Code gehen nur an steamcmd. steamcmd merkt sich danach ein
   Anmelde-Token, das Passwort wird nicht gespeichert.
5. Klick auf „Bibliothek synchronisieren“, um deine Spiele zu übernehmen.

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
- Kein Direct3D 12.
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
Änderungen an Wine und DXVK liegen als Patches in `macos/patches`.
Details zum Port stehen in [docs/MACOS_PORT.md](docs/MACOS_PORT.md).

## Lizenzen

MacProton steht wie Proton unter mehreren Lizenzen, siehe
[LICENSE](LICENSE). Wine und GnuTLS stehen unter der LGPL 2.1, DXVK unter
der zlib-Lizenz, MoltenVK unter der Apache-Lizenz 2.0. Der Quellcode aller
mitgelieferten Teile ist über dieses Repository, seine Submodule und die
Patches in `macos/patches` verfügbar.

MacProton ist kein Produkt von Valve oder Apple. Steam und steamcmd sind
Marken bzw. Software der Valve Corporation.
