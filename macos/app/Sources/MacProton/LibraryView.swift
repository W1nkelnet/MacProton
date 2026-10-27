import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runner: Runner
    @EnvironmentObject private var installer: Installer
    @State private var showAdd = false
    @State private var steamRunning = Paths.steamRunning

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            banners
            if library.games.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Spiele", systemImage: "gamecontroller")
                } description: {
                    Text("Füge ein Windows-Spiel aus deiner Steam-Bibliothek über seine App-ID oder den Shop-Link hinzu.")
                } actions: {
                    Button("Spiel hinzufügen") { showAdd = true }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.games) { GameCard(game: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showAdd = true } label: { Label("Spiel hinzufügen", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddGameView() }
        .alert("Fehler", isPresented: errorBinding) {
            Button("OK") { runner.lastError = nil; installer.lastError = nil }
        } message: {
            Text(runner.lastError ?? installer.lastError ?? "")
        }
        .alert("Steam-Anmeldung nötig", isPresented: loginBinding) {
            Button("Terminal öffnen") {
                if let account = installer.loginRequired { installer.openLoginTerminal(account: account) }
                installer.loginRequired = nil
            }
            Button("Abbrechen", role: .cancel) { installer.loginRequired = nil }
        } message: {
            Text("steamcmd braucht einmalig dein Passwort und ggf. den Steam-Guard-Code für \(installer.loginRequired ?? ""). MacProton öffnet dafür ein Terminal; die App selbst sieht deine Zugangsdaten nicht. Danach den Download erneut starten.")
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            steamRunning = Paths.steamRunning
        }
    }

    @ViewBuilder private var banners: some View {
        if !Paths.runtimeAvailable {
            Banner(text: "Proton-Laufzeit nicht gefunden (\(Paths.runtime.path)). Lege den Ordner in den Einstellungen fest.",
                   color: .orange)
        }
        if Paths.steamcmd == nil {
            Banner(text: "steamcmd fehlt: brew install --cask steamcmd", color: .orange)
        }
        if !steamRunning {
            Banner(text: "Steam läuft nicht. Spiele brauchen den angemeldeten Steam-Client.", color: .yellow)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { runner.lastError != nil || installer.lastError != nil },
                set: { if !$0 { runner.lastError = nil; installer.lastError = nil } })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { installer.loginRequired != nil }, set: { if !$0 { installer.loginRequired = nil } })
    }
}

private struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(color.opacity(0.18))
    }
}

struct GameCard: View {
    let game: Game
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runner: Runner
    @EnvironmentObject private var installer: Installer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: game.headerImageURL) { image in
                image.resizable().aspectRatio(460.0 / 215.0, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary).aspectRatio(460.0 / 215.0, contentMode: .fit)
                    .overlay(Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary))
            }
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(game.name).font(.headline).lineLimit(1)
                status
                action
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu { menu }
    }

    @ViewBuilder private var status: some View {
        if let job = installer.jobs[game.appID] {
            ProgressView(value: job.progress) {
                Text("\(job.status) – \(Int(job.progress * 100)) %").font(.caption)
            }
        } else if runner.isRunning(game) {
            Label("Läuft", systemImage: "play.circle.fill").font(.caption).foregroundStyle(.green)
        } else if !game.isInstalled {
            Text("Nicht installiert" + sizeText).font(.caption).foregroundStyle(.secondary)
        } else if let played = game.lastPlayed {
            Text("Zuletzt gespielt " + played.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Installiert").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if runner.isRunning(game) {
            Button("Beenden", role: .destructive) { runner.stop(game) }
        } else if game.isInstalled {
            Button {
                runner.play(game)
                library.markPlayed(game)
            } label: {
                Label("Spielen", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(installer.isBusy(game))
        } else {
            Button {
                installer.install(game, library: library)
            } label: {
                Label("Installieren", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .disabled(installer.isBusy(game))
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Aktualisieren / Dateien prüfen") { installer.install(game, library: library) }
            .disabled(installer.isBusy(game) || runner.isRunning(game))
        Divider()
        Button("Spielordner im Finder zeigen") { reveal(game.installDir) }
        Button("Prefix im Finder zeigen") { reveal(runner.prefix(of: game).path) }
        Button("Protokoll öffnen") {
            NSWorkspace.shared.open(Paths.logsDir.appendingPathComponent("\(game.appID).log"))
        }
        Button("Im Steam-Shop öffnen") {
            if let url = URL(string: "https://store.steampowered.com/app/\(game.appID)/") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Aus der Bibliothek entfernen") { library.remove(game) }
            .disabled(runner.isRunning(game) || installer.isBusy(game))
    }

    private var sizeText: String {
        game.sizeBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: game.sizeBytes, countStyle: .file) : ""
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
