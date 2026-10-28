import AppKit
import SwiftUI

/// Gets a game's Steam Cloud saves without starting it: opens Steam's cloud
/// page for the game, then imports the files the user downloaded there.
struct CloudImportView: View {
    let game: Game
    @EnvironmentObject private var runner: Runner
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CloudImport.Item] = []
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cloud-Spielstände holen", systemImage: "icloud.and.arrow.down")
                .font(.title2.weight(.semibold))
            Text("\(game.name): Steam lädt Cloud-Spielstände für Windows-Spiele auf dem Mac nicht vor dem Start. So holst du sie vorher. Was am Ziel schon liegt, wird gesichert.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("1.").bold()
                Button("Steam-Cloud-Seite öffnen") { NSWorkspace.shared.open(CloudImport.pageURL(game.appID)) }
                Text("und dort jede Datei mit „Download“ laden.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("2.").bold()
                Button("Geladene Dateien auswählen …", action: pickFiles)
            }

            if !items.isEmpty {
                Text("3. Pfade prüfen: „Pfad“ und „Ordner“ wie auf der Steam-Seite unter „File Name“ und „Folder“.")
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($items) { $item in row($item) }
                    }
                }
                .frame(maxHeight: 260)
            }

            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if runner.isRunning(game) {
                Text("Beende zuerst das Spiel.").foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(result == nil ? "Abbrechen" : "Fertig") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Importieren", action: runImport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(items.isEmpty || runner.isRunning(game) || items.contains { destination($0) == nil })
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ item: Binding<CloudImport.Item>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.wrappedValue.source.lastPathComponent).font(.callout.weight(.semibold))
            HStack {
                TextField("Pfad", text: item.path)
                Picker("Ordner", selection: item.folder) {
                    ForEach(CloudImport.folders(for: game), id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if let target = destination(item.wrappedValue) {
                Text((FileManager.default.fileExists(atPath: target.path) ? "Ersetzt (mit Sicherung): " : "Neu: ") + target.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            } else {
                Text("Ungültiger Pfad").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func destination(_ item: CloudImport.Item) -> URL? {
        CloudImport.destination(of: item, game: game, prefix: runner.prefix(of: game))
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Wähle die Dateien, die du von der Steam-Cloud-Seite geladen hast."
        if panel.runModal() == .OK {
            items = CloudImport.items(for: panel.urls, game: game)
            result = nil
            error = nil
        }
    }

    private func runImport() {
        do {
            let outcome = try CloudImport.run(items, game: game, prefix: runner.prefix(of: game))
            runner.markCloudHandled(game)
            var text = "\(outcome.copied) Datei(en) importiert."
            if let backup = outcome.backup { text += " Sicherung der ersetzten Dateien: \(backup.path)" }
            result = text
            error = nil
        } catch {
            self.error = "Import fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
