import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("steamAccount") private var steamAccount = ""
    @AppStorage("runtimePath") private var runtimePath = ""

    var body: some View {
        Form {
            Section("Steam") {
                TextField("Konto", text: $steamAccount, prompt: Text(detectSteamAccount() ?? "Steam-Kontoname"))
                Text("Leer lassen, um das zuletzt in Steam angemeldete Konto zu verwenden.")
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
