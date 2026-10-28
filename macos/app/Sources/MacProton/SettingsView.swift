import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var login: SteamLogin
    @AppStorage("steamAccount") private var steamAccount = ""
    @AppStorage("runtimePath") private var runtimePath = ""
    @AppStorage("syncSaves") private var syncSaves = true
    @AppStorage("metalHUD") private var metalHUD = false
    @AppStorage("autoUpdate") private var autoUpdate = false
    @AppStorage("defaultGameLocation") private var gameLocation = ""

    var body: some View {
        Form {
            Section("Steam") {
                TextField("Konto", text: $steamAccount, prompt: Text(detectSteamAccount() ?? "Steam-Kontoname"))
                Text("Leer lassen, um das zuletzt in Steam angemeldete Konto zu verwenden.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Bei Steam anmelden …") {
                    login.present(account: steamAccount.isEmpty ? (detectSteamAccount() ?? "") : steamAccount)
                }
                Text("steamcmd, mit dem MacProton Spiele lädt, braucht einmalig deine Steam-Anmeldung.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spielstände") {
                Toggle("Spielstände über Steam Cloud synchronisieren", isOn: $syncSaves)
                Text("Für Spiele, deren Windows- und Mac-Version dieselben Spielstände nutzen: Der Speicherordner im Prefix wird mit dem Mac-Ordner verknüpft, den Steam synchronisiert. Vorher werden beide gesichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speicherort für Spiele") {
                HStack {
                    TextField("Ordner", text: $gameLocation, prompt: Text(Paths.gamesDir.path))
                    Button("Wählen …") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Wählen"
                        panel.directoryURL = Paths.gameLocation
                        if panel.runModal() == .OK, let url = panel.url { gameLocation = url.path }
                    }
                    if !gameLocation.isEmpty {
                        Button("Zurücksetzen") { gameLocation = "" }
                    }
                }
                Text("Neue Spiele werden hier installiert, zum Beispiel auf einer externen Festplatte. Leer lassen für den Ordner von MacProton. Installierte Spiele bleiben, wo sie sind: Verschieben geht per Rechtsklick auf das Spiel, ein anderer Ort für ein einzelnes Spiel mit „Installieren in …“.")
                    .font(.caption).foregroundStyle(.secondary)
                if !gameLocation.isEmpty && !FileManager.default.fileExists(atPath: Paths.gameLocation.path) {
                    Label("Ordner nicht gefunden. Ist das Laufwerk angeschlossen?", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("Updates") {
                Toggle("Spiel-Updates automatisch laden", isOn: $autoUpdate)
                Text("MacProton sucht beim Start und alle vier Stunden nach Updates der installierten Windows-Spiele. Ist das aus, zeigt die Spielkarte „Update verfügbar“. Ist es an, lädt MacProton Updates selbst, wenn kein Spiel läuft. Steam verbindet sich danach kurz neu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anzeige") {
                Toggle("Metal-HUD mit FPS einblenden", isOn: $metalHUD)
                Text("Zeigt Apples Metal-Leistungsanzeige mit Bildrate und GPU-Zeit in Windows-Spielen. Gilt ab dem nächsten Spielstart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Proton-Laufzeit") {
                HStack {
                    TextField("Ordner", text: $runtimePath, prompt: Text(Paths.runtime.path))
                    Button("Wählen …") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { runtimePath = url.path }
                    }
                }
                Text("Der dist-Ordner aus macos/build.sh mit run.sh und files/.")
                    .font(.caption).foregroundStyle(.secondary)
                Label(Paths.runtimeAvailable ? "Laufzeit gefunden" : "Keine Laufzeit gefunden",
                      systemImage: Paths.runtimeAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(Paths.runtimeAvailable ? .green : .red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
