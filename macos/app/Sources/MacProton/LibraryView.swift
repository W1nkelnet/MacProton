import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runner: Runner
    @EnvironmentObject private var installer: Installer
    @EnvironmentObject private var sync: LibrarySync
    @State private var showAdd = false
    @State private var steamRunning = Paths.steamRunning
    @State private var steamOnline = SteamClient.isOnline
    @AppStorage("libraryFilter") private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all = "Alle", installed = "Installiert"
    }

    private var shownGames: [Game] {
        filter == .installed ? library.games.filter { $0.isInstalled || $0.isInstalledNatively } : library.games
    }

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            banners
            if sync.running {
                ProgressView(value: sync.progress) { Text(sync.status).font(.caption) }
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if library.games.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Spiele", systemImage: "gamecontroller")
                } description: {
                    Text("Übernimm deine Windows-Spiele aus Steam oder füge eines über seine App-ID hinzu.")
                } actions: {
                    Button("Bibliothek synchronisieren") { sync.sync(library: library, account: installer.account) }
                        .disabled(sync.running)
                    Button("Spiel hinzufügen") { showAdd = true }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(shownGames) { GameCard(game: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { sync.sync(library: library, account: installer.account) } label: {
                    Label("Bibliothek synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.running)
                .help("Windows-Spiele aus deinem Steam-Konto übernehmen")
            }
            ToolbarItem {
                Button { showAdd = true } label: { Label("Spiel hinzufügen", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddGameView() }
        .alert("Fehler", isPresented: errorBinding) {
            Button("OK") { runner.lastError = nil; installer.lastError = nil; sync.lastError = nil }
        } message: {
            Text(runner.lastError ?? installer.lastError ?? sync.lastError ?? "")
        }
        .alert("Hinweis", isPresented: noticeBinding) {
            Button("OK") { runner.notice = nil }
        } message: {
            Text(runner.notice ?? "")
        }
        .alert("Bibliothek synchronisiert", isPresented: resultBinding) {
            Button("OK") { sync.lastResult = nil }
        } message: {
            Text(sync.lastResult ?? "")
        }
        .onChange(of: sync.loginRequired) { _, account in
            if let account { installer.loginRequired = account; sync.loginRequired = nil }
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
        .alert("Steam ist offline", isPresented: offlineBinding) {
            Button("Offline spielen") {
                if let game = runner.offlineGame { runner.play(game, allowOffline: true) }
                runner.offlineGame = nil
            }
            Button("Abbrechen", role: .cancel) { runner.offlineGame = nil }
        } message: {
            Text(offlineText)
        }
        .onChange(of: steamcmdBusy) { _, busy in
            if !busy && Paths.steamRunning && SteamClient.isOnline == false {
                runner.reconnectSteam(automatic: true)
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            steamRunning = Paths.steamRunning
            steamOnline = SteamClient.isOnline
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
        } else if runner.reconnecting {
            Banner(text: "Steam wird neu gestartet und meldet sich wieder an …", color: .yellow)
        } else if steamOnline == false {
            Banner(text: "Steam ist offline. Lobbys und Online-Funktionen in Spielen gehen erst nach dem Neuverbinden.",
                   color: .yellow, action: ("Neu verbinden", { runner.reconnectSteam() }))
        }
    }

    private var offlineText: String {
        runner.running.isEmpty
            ? "Steam hat sich nach dem Neustart nicht wieder verbunden. Prüfe die Anmeldung im Steam-Fenster. "
                + "Ohne Verbindung gehen Lobbys und Online-Funktionen nicht."
            : "Der Steam-Client hat keine Verbindung. Zum Neuverbinden müsste MacProton Steam neu starten, "
                + "das würde die laufenden Spiele trennen. Ohne Verbindung gehen Lobbys und Online-Funktionen nicht."
    }

    /// steamcmd's login replaced the Steam client's session
    private var steamcmdBusy: Bool { !installer.jobs.isEmpty || sync.running }

    private var offlineBinding: Binding<Bool> {
        Binding(get: { runner.offlineGame != nil }, set: { if !$0 { runner.offlineGame = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { runner.lastError != nil || installer.lastError != nil || sync.lastError != nil },
                set: { if !$0 { runner.lastError = nil; installer.lastError = nil; sync.lastError = nil } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { runner.notice != nil }, set: { if !$0 { runner.notice = nil } })
    }

    private var resultBinding: Binding<Bool> {
        Binding(get: { sync.lastResult != nil }, set: { if !$0 { sync.lastResult = nil } })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { installer.loginRequired != nil }, set: { if !$0 { installer.loginRequired = nil } })
    }
}

private struct Banner: View {
    let text: String
    let color: Color
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.0, action: action.1)
            }
        }
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
                HStack {
                    Text(game.name).font(.headline).lineLimit(1)
                    Spacer()
                    if game.hasNativeMac == true {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.secondary)
                            .help("Native Mac-Version: MacProton startet sie über Steam.")
                    }
                }
                if !(game.cloudSaves ?? []).isEmpty {
                    Label("Steam Cloud", systemImage: "icloud")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Spielstände werden plattformübergreifend über Steam Cloud synchronisiert (Mac-Speicherort).")
                }
                // The issues concern the Windows version under Wine
                if !game.runsNatively, let issues = game.issues, !issues.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(issues, id: \.self) { issue in
                            Text(issue.title)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((issue.isBlocking ? Color.red : Color.orange).opacity(0.2), in: Capsule())
                                .foregroundStyle(issue.isBlocking ? .red : .orange)
                                .help(issue.explanation)
                        }
                    }
                }
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
        } else if game.runsNatively {
            if !game.isInstalledNatively {
                Text("Mac-Version · Installation über Steam").font(.caption).foregroundStyle(.secondary)
            } else if let played = game.lastPlayed {
                Text("Mac-Version · zuletzt gespielt " + played.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Mac-Version · in Steam installiert").font(.caption).foregroundStyle(.secondary)
            }
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
        } else if game.runsNatively {
            let installed = game.isInstalledNatively
            Button {
                runner.playNative(game)
                if installed { library.markPlayed(game) }
            } label: {
                Label(installed ? "Spielen" : "Mit Steam installieren",
                      systemImage: installed ? "play.fill" : "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.reconnecting)
            .help("Startet die native Mac-Version über Steam.")
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
        if game.runsNatively {
            // The Windows version stays available, e.g. if the Mac version is outdated
            if game.isInstalled {
                Button("Windows-Version spielen") {
                    runner.play(game)
                    library.markPlayed(game)
                }
                .disabled(installer.isBusy(game) || runner.isRunning(game))
            }
            Button(game.isInstalled ? "Windows-Version aktualisieren" : "Windows-Version installieren") {
                installer.install(game, library: library)
            }
            .disabled(installer.isBusy(game) || runner.isRunning(game))
        } else {
            Button("Aktualisieren / Dateien prüfen") { installer.install(game, library: library) }
                .disabled(installer.isBusy(game) || runner.isRunning(game))
        }
        Divider()
        Button("Spielordner im Finder zeigen") { reveal(game.installDir) }
        Button("Prefix im Finder zeigen") { reveal(runner.prefix(of: game).path) }
        if !(game.cloudSaves ?? []).isEmpty {
            Button("Spielstand-Backups zeigen") {
                let dir = SaveSync.backupsDir.appendingPathComponent(String(game.appID))
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                reveal(dir.path)
            }
        }
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
