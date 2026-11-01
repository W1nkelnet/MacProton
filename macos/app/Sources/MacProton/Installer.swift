import AppKit
import Foundation

/// A game download in MacProton's queue
struct Download: Codable, Identifiable {
    enum State: String, Codable { case queued, running, paused, failed }

    var appID: Int
    var name: String
    var state: State
    /// What steamcmd is doing, e.g. "Lade herunter"
    var phase = ""
    var progress = 0.0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    /// The progress counts files checked, not bytes loaded
    var verifying = false
    var error: String?

    var id: Int { appID }
}

/// Downloads games with steamcmd, one after another. The queue is saved, so
/// paused and interrupted downloads continue after MacProton restarts; on
/// continuing, steamcmd first checks the files already there.
@MainActor
final class Installer: ObservableObject {
    @Published private(set) var downloads: [Download] = []
    /// Bytes per second of the running download
    @Published private(set) var speeds: [Int: Double] = [:]
    /// Games whose download finished in this session
    @Published private(set) var completed: [Int] = []
    /// Games being moved to another folder, with progress
    @Published private(set) var moves: [Int: Double] = [:]
    @Published var loginRequired: String?
    @Published var lastError: String?

    private var library: Library?
    private var handles: [Int: SteamCMD.Handle] = [:]
    private var samples: [Int: (date: Date, bytes: Int64)] = [:]
    private var lastSave = Date.distantPast
    private var quitting = false
    private static let queueFile = Paths.support.appendingPathComponent("downloads.json")

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForQuit() }
        }
    }

    var account: String {
        let saved = UserDefaults.standard.string(forKey: "steamAccount") ?? ""
        return saved.isEmpty ? (detectSteamAccount() ?? "") : saved
    }

    func download(for appID: Int) -> Download? { downloads.first { $0.appID == appID } }

    /// steamcmd is logged in for a download
    var isDownloading: Bool { downloads.contains { $0.state == .running } }

    /// A download runs or waits to
    var hasPendingDownloads: Bool { downloads.contains { $0.state == .running || $0.state == .queued } }

    func isBusy(_ game: Game) -> Bool {
        if moves[game.appID] != nil { return true }
        guard let state = download(for: game.appID)?.state else { return false }
        return state != .failed
    }

    /// Installs Rosetta 2 in Terminal, where macOS may ask for an admin password.
    func installRosetta() {
        let script = Paths.support.appendingPathComponent("install-rosetta.command")
        let text = """
        #!/bin/bash
        echo String(localized: "Rosetta 2 für MacProton installieren …")
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        echo
        echo String(localized: "Fertig. Dieses Fenster kann geschlossen werden.")
        """
        try? text.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    // MARK: Queue

    /// Loads the saved queue and adds downloads begun earlier that it lacks,
    /// e.g. from before a crash, then continues.
    func attach(_ library: Library) {
        guard self.library == nil else { return }
        self.library = library
        if let data = try? Data(contentsOf: Self.queueFile),
           let saved = try? JSONDecoder().decode([Download].self, from: data) {
            downloads = saved.filter { saved in library.games.contains { $0.appID == saved.appID } }
            // Interrupted by quitting: continue
            for index in downloads.indices where downloads[index].state == .running {
                downloads[index].state = .queued
            }
        }
        for game in library.games where download(for: game.appID) == nil {
            guard let begun = Self.begunDownload(game) else { continue }
            downloads.append(begun)
        }
        save()
        pump()
    }

    /// steamcmd's manifest of a download that did not finish
    static func begunDownload(_ game: Game) -> Download? {
        guard game.locationAvailable else { return nil }
        let manifest = (game.installDir as NSString).appendingPathComponent("steamapps/appmanifest_\(game.appID).acf")
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else { return nil }
        let state = VDF.parse(text)["AppState"]
        let flags = state?["StateFlags"]?.string.flatMap(Int.init) ?? 4
        // Fully installed and no update pending
        guard flags & 4 == 0 || flags & 2 != 0 else { return nil }
        var download = Download(appID: game.appID, name: game.name, state: .paused, phase: String(localized: "Unterbrochen"))
        download.bytesDone = Int64(state?["BytesDownloaded"]?.string ?? "") ?? 0
        download.bytesTotal = Int64(state?["BytesToDownload"]?.string ?? "") ?? 0
        if download.bytesTotal > 0 { download.progress = Double(download.bytesDone) / Double(download.bytesTotal) }
        return download
    }

    /// Downloads or updates the game. A new installation goes to the default
    /// location from the settings; one already begun stays where it is.
    func install(_ game: Game, library: Library) {
        guard !isBusy(game) else { return }
        self.library = self.library ?? library
        // Not a new installation, only its disk is missing
        guard game.locationAvailable else { return enqueue(game) }
        let location = Paths.gameLocation
        guard game.isInstalled || FileManager.default.fileExists(atPath: game.installDir) else {
            if location != Paths.gamesDir {
                guard FileManager.default.fileExists(atPath: location.path) else {
                    lastError = String(localized: "Der Standard-Speicherort „\(location.path)“ ist nicht da. Schließ das Laufwerk an oder ändere ihn in den Einstellungen.")
                    return
                }
            }
            install(game, in: location, library: library)
            return
        }
        enqueue(game)
    }

    /// Installs the game into its own folder in `folder` from now on.
    func install(_ game: Game, in folder: URL, library: Library) {
        guard !isBusy(game) else { return }
        self.library = self.library ?? library
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = GameLocation.installDir(for: game, in: folder)
        if let problem = GameLocation.installProblem(game, dir: dir) {
            lastError = problem
            return
        }
        // Created now, so that it stays the game's place even if the download does not start
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var updated = library.games.first { $0.appID == game.appID } ?? game
        updated.installDir = dir.path
        library.upsert(updated)
        enqueue(updated)
    }

    private func enqueue(_ game: Game) {
        guard game.locationAvailable else {
            lastError = String(localized: "Das Laufwerk „\(game.externalVolume ?? "")“ mit \(game.name) ist nicht verbunden. Schließ es an oder wähle per Rechtsklick „Installieren in …“ einen anderen Ort.")
            return
        }
        guard !account.isEmpty else {
            loginRequired = ""  // opens the login window
            return
        }
        if let index = downloads.firstIndex(where: { $0.appID == game.appID }) {
            downloads[index].state = .queued
            downloads[index].error = nil
        } else {
            downloads.append(Download(appID: game.appID, name: game.name, state: .queued, phase: String(localized: "Wartet")))
        }
        save()
        pump()
    }

    func pause(_ appID: Int) {
        guard let index = downloads.firstIndex(where: { $0.appID == appID }),
              downloads[index].state == .running || downloads[index].state == .queued else { return }
        downloads[index].state = .paused
        downloads[index].phase = String(localized: "Pausiert")
        speeds[appID] = nil
        save()
        // The run ends and starts the next download
        handles[appID]?.stop()
    }

    func resume(_ appID: Int) {
        guard let index = downloads.firstIndex(where: { $0.appID == appID }),
              downloads[index].state == .paused || downloads[index].state == .failed else { return }
        downloads[index].state = .queued
        downloads[index].phase = String(localized: "Wartet")
        downloads[index].error = nil
        save()
        pump()
    }

    /// Loads this one next, after the running download
    func moveToFront(_ appID: Int) {
        guard let index = downloads.firstIndex(where: { $0.appID == appID }) else { return }
        downloads.insert(downloads.remove(at: index), at: 0)
        save()
    }

    /// Takes the download off the list; what it loaded stays on disk, so
    /// installing the game again continues from there.
    func remove(_ appID: Int) {
        downloads.removeAll { $0.appID == appID }
        speeds[appID] = nil
        save()
        handles[appID]?.stop()
    }

    /// Starts the first waiting download if none runs.
    private func pump() {
        guard !quitting, !isDownloading, let library,
              let index = downloads.firstIndex(where: { $0.state == .queued }) else { return }
        let appID = downloads[index].appID
        guard let game = library.games.first(where: { $0.appID == appID }) else {
            downloads.remove(at: index)
            save()
            return pump()
        }
        guard game.locationAvailable else {
            downloads[index].state = .paused
            downloads[index].phase = String(localized: "Pausiert")
            downloads[index].error = String(localized: "Laufwerk „\(game.externalVolume ?? "")“ nicht verbunden")
            save()
            return pump()
        }
        let account = self.account
        guard !account.isEmpty else {
            downloads[index].state = .paused
            downloads[index].error = String(localized: "Steam-Anmeldung nötig")
            save()
            loginRequired = ""
            return
        }
        downloads[index].state = .running
        downloads[index].phase = String(localized: "Verbinde mit Steam …")
        downloads[index].error = nil
        save()
        let handle = SteamCMD.Handle()
        handles[appID] = handle
        samples[appID] = nil
        Task { await run(game, account: account, handle: handle) }
    }

    private func run(_ game: Game, account: String, handle: SteamCMD.Handle) async {
        let appID = game.appID
        // Two steamcmd writing the same folder would spoil the download
        if await Self.steamcmdRunning(in: game.installDir) {
            update(appID) {
                $0.state = .paused
                $0.phase = String(localized: "Pausiert")
                $0.error = String(localized: "Ein steamcmd aus einer früheren Sitzung lädt das Spiel noch. Setze fort, wenn es fertig ist.")
            }
            handles[appID] = nil
            save()
            return pump()
        }
        do {
            try await SteamCMD.install(appID: appID, into: game.installDir, account: account, handle: handle) { state in
                Task { @MainActor in self.report(appID, state) }
            }
            finish(game)
        } catch {
            if handle.wasStopped {
                // Paused, removed or quitting; the state is already set
            } else if case SteamCMDError.loginRequired(let name) = error {
                update(appID) { $0.state = .paused; $0.phase = String(localized: "Pausiert"); $0.error = String(localized: "Steam-Anmeldung nötig") }
                loginRequired = name
            } else {
                update(appID) { $0.state = .failed; $0.error = error.localizedDescription }
                lastError = "\(game.name): \(error.localizedDescription)"
            }
        }
        handles[appID] = nil
        speeds[appID] = nil
        save()
        pump()
    }

    /// Whether a steamcmd, e.g. left by an earlier session, installs into `dir`
    static func steamcmdRunning(in dir: String) async -> Bool {
        // Without a UTF-8 locale ps escapes characters such as "™" in paths
        guard let list = try? await SteamCMD.run("/usr/bin/env", ["LC_ALL=en_US.UTF-8", "/bin/ps", "-axww", "-o", "command="],
                                                 onLine: { _ in }) else { return false }
        return list.split(whereSeparator: \.isNewline).contains {
            $0.contains("steamcmd") && $0.contains("+force_install_dir \(dir) +")
        }
    }

    private func report(_ appID: Int, _ state: SteamCMD.UpdateState) {
        guard let index = downloads.firstIndex(where: { $0.appID == appID }), downloads[index].state == .running else { return }
        downloads[index].phase = state.phase
        downloads[index].verifying = state.verifying
        if state.bytesTotal > 0 || state.progress > 0 {
            downloads[index].progress = state.progress
            downloads[index].bytesDone = state.bytesDone
            downloads[index].bytesTotal = state.bytesTotal
        }
        if state.downloading {
            let now = Date()
            if let sample = samples[appID] {
                let seconds = now.timeIntervalSince(sample.date)
                if seconds >= 2 {
                    let rate = Double(max(state.bytesDone - sample.bytes, 0)) / seconds
                    speeds[appID] = speeds[appID].map { $0 * 0.7 + rate * 0.3 } ?? rate
                    samples[appID] = (now, state.bytesDone)
                }
            } else {
                samples[appID] = (now, state.bytesDone)
            }
        } else {
            speeds[appID] = nil
            samples[appID] = nil
        }
        if Date().timeIntervalSince(lastSave) > 10 { save() }
    }

    private func finish(_ game: Game) {
        let appID = game.appID
        if let library {
            var installed = library.games.first { $0.appID == appID } ?? game
            let exeDir = (installed.installDir as NSString)
                .appendingPathComponent((installed.executable as NSString).deletingLastPathComponent)
            var issues = installed.issues ?? []
            if issues.allSatisfy({ ![.antiCheat, .antiCheatOffline, .antiCheatFiles].contains($0) }),
               AppAnalysis.hasAntiCheatFiles(in: installed.installDir) || AppAnalysis.hasAntiCheatFiles(in: exeDir) {
                issues.append(.antiCheatFiles)
                installed.issues = issues
            }
            library.upsert(installed)
        }
        downloads.removeAll { $0.appID == appID }
        completed.append(appID)
    }

    private func update(_ appID: Int, _ change: (inout Download) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.appID == appID }) else { return }
        change(&downloads[index])
    }

    /// Ends steamcmd with the app; the downloads continue at the next start.
    private func stopForQuit() {
        quitting = true
        save()
        for handle in handles.values { handle.stop() }
    }

    private func save() {
        lastSave = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(downloads).write(to: Self.queueFile, options: .atomic)
    }

    // MARK: Moving

    /// Moves the installed game's folder into `folder`.
    func move(_ game: Game, to folder: URL, library: Library) {
        guard !isBusy(game) else { return }
        let source = URL(fileURLWithPath: game.installDir, isDirectory: true)
        let target = folder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        // Already there
        guard folder.resolvingSymlinksInPath() != source.deletingLastPathComponent().resolvingSymlinksInPath() else { return }
        let appID = game.appID
        moves[appID] = 0

        Task {
            let progress = GameLocation.Progress()
            let work = Task.detached {
                defer { progress.finish() }
                return try GameLocation.move(source, to: target, progress: progress)
            }
            while !progress.isFinished {
                moves[appID] = progress.value
                try? await Task.sleep(for: .milliseconds(250))
            }
            do {
                if let note = try await work.value { lastError = note }
                if var moved = library.games.first(where: { $0.appID == appID }) {
                    moved.installDir = target.path
                    library.upsert(moved)
                }
            } catch {
                lastError = String(localized: "\(game.name) wurde nicht verschoben: \(error.localizedDescription)")
            }
            moves[appID] = nil
        }
    }
}
