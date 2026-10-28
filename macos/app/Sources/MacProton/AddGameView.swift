import AppKit
import SwiftUI

struct AddGameView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var installer: Installer
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var info: AppInfo?
    @State private var installDir = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spiel hinzufügen").font(.title2.bold())
            Text("App-ID oder Shop-Link, z. B. store.steampowered.com/app/1313140/…").foregroundStyle(.secondary)

            HStack {
                TextField("App-ID oder Link", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(lookup)
                Button("Abrufen", action: lookup).disabled(appID == nil || loading)
            }

            if loading { ProgressView("Lade Spielinformationen …") }
            if let error { Text(error).foregroundStyle(.red) }

            if let info {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.name).font(.headline)
                        if info.executable.isEmpty {
                            Text("Keine Windows-Version gefunden.").foregroundStyle(.red)
                        } else {
                            Text("Startdatei: \(info.executable)").font(.caption)
                            if info.sizeBytes > 0 {
                                Text("Größe: \(ByteCountFormatter.string(fromByteCount: info.sizeBytes, countStyle: .file))")
                                    .font(.caption)
                            }
                            HStack {
                                Text("Ordner:").font(.caption)
                                Text(installDir).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Ändern …", action: chooseFolder).controlSize(.small)
                            }
                            ForEach(info.issues, id: \.self) { issue in
                                Label(issue.explanation, systemImage: issue.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(issue.isBlocking ? .red : .orange)
                            }
                            if alreadyInstalled {
                                Label("Bereits in diesem Ordner installiert", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(alreadyInstalled ? "Hinzufügen" : "Hinzufügen und installieren", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(info == nil || info?.executable.isEmpty == true)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Accepts "1313140" or a store link containing /app/1313140/
    private var appID: Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(text) { return id }
        guard let range = text.range(of: "/app/") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    private var alreadyInstalled: Bool {
        guard let info, !info.executable.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: (installDir as NSString).appendingPathComponent(info.executable))
    }

    private func lookup() {
        guard let appID else { return }
        loading = true; error = nil; info = nil
        Task {
            do {
                let result = try await SteamCMD.appInfo(appID)
                info = result
                let folder = result.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
                installDir = Paths.gameLocation.appendingPathComponent(folder).path
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        if panel.runModal() == .OK, let url = panel.url { installDir = url.path }
    }

    private func add() {
        guard let info else { return }
        let game = Game(info: info, installDir: installDir)
        library.upsert(game)
        if !alreadyInstalled { installer.install(game, library: library) }
        dismiss()
    }
}
