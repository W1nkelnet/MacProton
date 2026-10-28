import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var login: SteamLogin
    @AppStorage("steamAccount") private var steamAccount = ""
    @AppStorage("runtimePath") private var runtimePath = ""
    @AppStorage("syncSaves") private var syncSaves = true

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
