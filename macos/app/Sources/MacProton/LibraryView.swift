import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runner: Runner
    @EnvironmentObject private var installer: Installer
    @EnvironmentObject private var sync: LibrarySync
    @EnvironmentObject private var login: SteamLogin
    @EnvironmentObject private var steamcmdSetup: SteamCMDSetup
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var appUpdates: AppUpdateChecker
    @State private var showAdd = false
    @State private var search = ""
    @State private var steamRunning = Paths.steamRunning
    @State private var steamOnline = SteamClient.isOnline
    @AppStorage("libraryFilter") private var filter = Filter.all
    @AppStorage("platformFilter") private var platform = Platform.all

    enum Filter: String, CaseIterable {
        case all = "Alle", installed = "Installiert", downloads = "Downloads"
    }

    /// Games that run only through Proton, or that also have a macOS version
    enum Platform: String, CaseIterable {
        case all = "Alle Plattformen", windows = "Nur Windows", mac = "Mit Mac-Version"

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .windows: return "pc"
            case .mac: return "apple.logo"
            }
        }

        func includes(_ game: Game) -> Bool {
            switch self {
            case .all: return true
            case .windows: return !game.runsNatively
            case .mac: return game.runsNatively
            }
        }
    }

    private var shownGames: [Game] {
        var games = filter == .installed ? library.games.filter { $0.isInstalled || $0.isInstalledNatively } : library.games
        games = games.filter(platform.includes)
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? games : games.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            banners
            if sync.running {
                ProgressView(value: sync.progress) { Text(sync.status).font(.caption) }
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if filter == .downloads {
                DownloadsView()
            } else if library.games.isEmpty {
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
                if shownGames.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if shownGames.isEmpty && platform != .all {
                    ContentUnavailableView {
                        Label("Keine Spiele", systemImage: platform.symbol)
                    } description: {
                        Text(platform == .windows ? "Alle Spiele hier haben auch eine Mac-Version." : "Keines der Spiele hier hat eine Mac-Version.")
                    } actions: {
                        Button("Alle Plattformen zeigen") { platform = .all }
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
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        let count = installer.downloads.count
                        Text(item == .downloads && count > 0 ? "Downloads (\(count))" : item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Menu {
                    Picker("Plattform", selection: $platform) {
                        ForEach(Platform.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Plattform", systemImage: platform == .all ? "line.3.horizontal.decrease.circle"
                                                                     : "line.3.horizontal.decrease.circle.fill")
                }
                .help(platform == .all ? "Nach Plattform filtern" : "Gefiltert: \(platform.rawValue)")
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
        .searchable(text: $search, placement: .toolbar, prompt: "Spiele suchen")
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
        .onChange(of: installer.loginRequired) { _, account in
            if let account { login.present(account: account); installer.loginRequired = nil }
        }
        .alert("Spielstände in der Steam Cloud", isPresented: cloudWarningBinding) {
            Button("Spielen") {
                if let game = runner.cloudWarningGame { runner.playAfterCloudNotice(game) }
                runner.cloudWarningGame = nil
            }
            Button("Abbrechen", role: .cancel) { runner.cloudWarningGame = nil }
        } message: {
            Text(cloudWarningText)
        }
        .alert("Spielstände unterschiedlich", isPresented: cloudConflictBinding, presenting: runner.cloudConflict) { prompt in
            Button("Cloud-Version") { runner.cloudConflict = nil; prompt.answer(.cloud) }
            Button("Version dieses Macs") { runner.cloudConflict = nil; prompt.answer(.mac) }
            Button(prompt.beforeStart ? "Abbrechen" : "Später entscheiden", role: .cancel) {
                runner.cloudConflict = nil
                prompt.answer(nil)
            }
        } message: { prompt in
            Text("\(prompt.game.name): \(prompt.files.count == 1 ? "Eine Datei hat" : "\(prompt.files.count) Dateien haben") sich seit dem letzten Abgleich in der Steam Cloud und auf diesem Mac geändert, etwa \(prompt.files.first.map { ($0 as NSString).lastPathComponent } ?? ""). Welche Version soll gelten? Die andere wird vorher gesichert.")
        }
        .alert("Steam Cloud nicht erreichbar", isPresented: cloudFailureBinding, presenting: runner.cloudFailure) { prompt in
            Button("Ohne Abgleich starten") { runner.cloudFailure = nil; prompt.answer(true) }
            Button("Abbrechen", role: .cancel) { runner.cloudFailure = nil; prompt.answer(false) }
        } message: { prompt in
            Text("Die Spielstände von \(prompt.game.name) konnten nicht abgeglichen werden: \(prompt.message)\n\nOhne Abgleich lädt MacProton nach dem Spielen nur neue und geänderte Dateien hoch und löscht nichts in der Cloud.")
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
        .onChange(of: installer.completed) { old, new in
            for appID in new.dropFirst(old.count) { updates.markUpdated(appID) }
            installNextUpdate()
        }
        .onAppear { installer.attach(library) }
        .onChange(of: updates.available) { _, _ in installNextUpdate() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            steamRunning = Paths.steamRunning
            steamOnline = SteamClient.isOnline
            updates.checkIfDue(library: library, steamcmdBusy: steamcmdBusy || !steamcmdSetup.isComplete)
            appUpdates.checkIfDue()
        }
    }

    /// With automatic updates on, downloads one available update at a time
    /// while no game runs and steamcmd is free.
    private func installNextUpdate() {
        guard UpdateChecker.autoUpdate, runner.running.isEmpty, !steamcmdBusy, !installer.hasPendingDownloads, !updates.checking,
              let game = library.games.first(where: { updates.available.contains($0.appID) && $0.locationAvailable }) else { return }
        installer.install(game, library: library)
    }

    @ViewBuilder private var banners: some View {
        if let release = appUpdates.newRelease {
            Banner(text: "MacProton \(release.version) ist verfügbar.", color: .blue,
                   action: ("Herunterladen", { NSWorkspace.shared.open(release.url) }))
        }
        if !Paths.runtimeAvailable {
            Banner(text: "Proton-Laufzeit nicht gefunden (\(Paths.runtime.path)). Lege den Ordner in den Einstellungen fest.",
                   color: .orange)
        }
        if Paths.needsRosetta {
            Banner(text: "Rosetta 2 fehlt. Die Windows-Laufzeit braucht es auf Macs mit Apple-Chip.",
                   color: .orange, action: ("Installieren", { installer.installRosetta() }))
        }
        if steamcmdSetup.running {
            Banner(text: "steamcmd wird von Valve geladen und eingerichtet …", color: .yellow)
        } else if let error = steamcmdSetup.error {
            Banner(text: error, color: .orange, action: ("Erneut versuchen", { steamcmdSetup.setUpIfNeeded() }))
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
    private var steamcmdBusy: Bool { installer.isDownloading || sync.running || login.isPresented }

    private var cloudConflictBinding: Binding<Bool> {
        Binding(get: { runner.cloudConflict != nil }, set: { _ in })
    }

    private var cloudFailureBinding: Binding<Bool> {
        Binding(get: { runner.cloudFailure != nil }, set: { _ in })
    }

    /// Windows-only games with Auto-Cloud rules get nothing from macOS Steam;
    /// games saving through Steam's cloud API sync when they end.
    private var cloudWarningText: String {
        let name = runner.cloudWarningGame?.name ?? "Dieses Spiel"
        if let game = runner.cloudWarningGame, !game.runsNatively, !(game.cloudRules ?? []).isEmpty {
            return "\(name) speichert in Windows-Ordnern in der Steam Cloud, und die gleicht Steam für macOS nicht ab. Melde dich in den Einstellungen unter „Steam Cloud“ an, dann lädt MacProton die Spielstände vor jedem Start und danach wieder hoch.\n\nOhne Anmeldung kannst du sie per Rechtsklick mit „Cloud-Spielstände holen …“ von Hand holen."
        }
        return "\(name) speichert in der Steam Cloud, und Steam hat die Spielstände auf diesem Mac noch nicht geladen. Für Windows-Spiele lädt Steam sie erst beim Beenden.\n\nHast du auf einem anderen Gerät gespielt: Starte das Spiel nur bis ins Hauptmenü und beende es wieder. Fragt Steam dann nach einem Konflikt, wähle die Cloud-Version. Ab dem nächsten Start sind deine Spielstände da."
    }

    private var cloudWarningBinding: Binding<Bool> {
        Binding(get: { runner.cloudWarningGame != nil }, set: { if !$0 { runner.cloudWarningGame = nil } })
    }

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
    @EnvironmentObject private var updates: UpdateChecker
    @State private var confirmUninstall = false
    @State private var uninstallError: String?
    @State private var showCloudImport = false
    @State private var showLaunchOptions = false

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
                    if !game.runsNatively, let volume = game.externalVolume {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.secondary)
                            .help("Liegt auf „\(volume)“")
                    }
                    if game.hasNativeMac == true {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.secondary)
                            .help("Native Mac-Version: MacProton startet sie über Steam.")
                    }
                }
                if !game.runsNatively, let options = game.launchOptions {
                    Label(options, systemImage: "slider.horizontal.3")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help("Startoptionen, per Rechtsklick änderbar")
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
        .sheet(isPresented: $showCloudImport) { CloudImportView(game: game) }
        .sheet(isPresented: $showLaunchOptions) { LaunchOptionsView(game: game) }
        .confirmationDialog("\(game.name) deinstallieren?", isPresented: $confirmUninstall) {
            Button("Deinstallieren", role: .destructive) { uninstall(prefix: false) }
            Button("Deinstallieren, auch Spielstände im Prefix", role: .destructive) { uninstall(prefix: true) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Spielordner kommt in den Papierkorb, und das Spiel verschwindet aus der Bibliothek. Der Wine-Prefix enthält lokale Spielstände und Einstellungen; Spielstände in Steam Cloud bleiben erhalten.")
        }
        .alert("Deinstallieren", isPresented: Binding(get: { uninstallError != nil }, set: { if !$0 { uninstallError = nil } })) {
            Button("OK") { uninstallError = nil }
        } message: {
            Text(uninstallError ?? "")
        }
    }

    private func uninstall(prefix: Bool) {
        uninstallError = library.uninstall(game, prefix: prefix ? runner.prefix(of: game) : nil)
    }

    private func chooseInstallFolder() {
        guard let folder = GameLocation.choose(
            prompt: "Hier installieren",
            message: "„\(game.name)“ bekommt in diesem Ordner einen eigenen Ordner, zum Beispiel auf einer externen Festplatte.")
        else { return }
        installer.install(game, in: folder, library: library)
    }

    private func chooseMoveTarget() {
        guard let folder = GameLocation.choose(
            prompt: "Hierher verschieben",
            message: "Der Ordner von „\(game.name)“ kommt in den gewählten Ordner. Auf ein anderes Laufwerk wird er kopiert und danach am alten Ort gelöscht.")
        else { return }
        installer.move(game, to: folder, library: library)
    }

    @ViewBuilder private var status: some View {
        if let download = installer.download(for: game.appID) {
            switch download.state {
            case .running:
                ProgressView(value: download.progress) {
                    Text("\(download.phase) – \(Int(download.progress * 100)) %").font(.caption)
                }
            case .queued:
                Label("Wartet auf Download", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            case .paused:
                ProgressView(value: download.progress) {
                    Text("Download pausiert – \(Int(download.progress * 100)) %" + (download.error.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(download.error == nil ? Color.secondary : .orange)
                }
            case .failed:
                Label("Download fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .help(download.error ?? "")
            }
        } else if let moved = installer.moves[game.appID] {
            ProgressView(value: moved) {
                Text("Verschiebe – \(Int(moved * 100)) %").font(.caption)
            }
        } else if let step = runner.preparing[game.appID] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(step).font(.caption).foregroundStyle(.secondary)
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
        } else if !game.locationAvailable {
            Label("Laufwerk „\(game.externalVolume ?? "")“ nicht verbunden", systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
        } else if game.isInstalled && updates.available.contains(game.appID) {
            Label("Update verfügbar", systemImage: "arrow.down.circle.fill")
                .font(.caption).foregroundStyle(.orange)
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
        } else if !game.runsNatively, let download = installer.download(for: game.appID) {
            if download.state == .running || download.state == .queued {
                Button { installer.pause(game.appID) } label: {
                    Label("Pausieren", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
            } else {
                Button { installer.resume(game.appID) } label: {
                    Label(download.state == .failed ? "Erneut versuchen" : "Fortsetzen", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!game.locationAvailable)
            }
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
            HStack {
                Button {
                    runner.play(game)
                    library.markPlayed(game)
                } label: {
                    Label("Spielen", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if updates.available.contains(game.appID) {
                    Button {
                        installer.install(game, library: library)
                    } label: {
                        Label("Update laden", systemImage: "arrow.down.circle")
                    }
                    .help("Lädt die neue Version des Spiels")
                }
            }
            .disabled(installer.isBusy(game))
        } else {
            Button {
                installer.install(game, library: library)
            } label: {
                Label("Installieren", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .disabled(installer.isBusy(game) || !game.locationAvailable)
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
            Button(game.isInstalled ? "Windows-Version verschieben …" : "Windows-Version installieren in …") {
                game.isInstalled ? chooseMoveTarget() : chooseInstallFolder()
            }
            .disabled(installer.isBusy(game) || runner.isRunning(game))
        } else {
            if !game.isInstalled {
                Button("Installieren in …") { chooseInstallFolder() }
                    .disabled(installer.isBusy(game))
            }
            Button("Aktualisieren / Dateien prüfen") { installer.install(game, library: library) }
                .disabled(installer.isBusy(game) || runner.isRunning(game))
            if game.isInstalled {
                Button("Verschieben …") { chooseMoveTarget() }
                    .disabled(installer.isBusy(game) || runner.isRunning(game))
            }
        }
        Button(game.runsNatively ? "Startoptionen der Windows-Version …" : "Startoptionen …") { showLaunchOptions = true }
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
        if !game.runsNatively {
            Button("Cloud-Spielstände holen …") { showCloudImport = true }
                .disabled(runner.isRunning(game))
        }
        Divider()
        if game.isInstalledNatively {
            Button("Mac-Version in Steam deinstallieren") {
                if let url = URL(string: "steam://uninstall/\(game.appID)") { NSWorkspace.shared.open(url) }
            }
        }
        Button("Deinstallieren …") { confirmUninstall = true }
            .disabled(!(game.isInstalled || FileManager.default.fileExists(atPath: game.installDir))
                      || runner.isRunning(game) || installer.isBusy(game))
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
