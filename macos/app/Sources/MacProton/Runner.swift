import Foundation

/// Starts games through the runtime's run.sh and tracks running ones.
@MainActor
final class Runner: ObservableObject {
    @Published private(set) var running: Set<Int> = []
    @Published var lastError: String?
    @Published var notice: String?
    /// Game the user started while the Steam client was offline
    @Published var offlineGame: Game?
    @Published private(set) var reconnecting = false

    static var syncSaves: Bool { UserDefaults.standard.object(forKey: "syncSaves") as? Bool ?? true }

    private var processes: [Int: Process] = [:]

    func isRunning(_ game: Game) -> Bool { running.contains(game.appID) }

    func play(_ game: Game, allowOffline: Bool = false) {
        guard !isRunning(game), !reconnecting else { return }
        guard !game.launchesViaURL else {
            lastError = "\(game.name) startet über den Launcher eines anderen Anbieters (\(game.executable.prefix { $0 != ":" })). Solche Launcher unterstützt MacProton noch nicht."
            return
        }
        guard Paths.runtimeAvailable else {
            lastError = "Proton-Laufzeit nicht gefunden in \(Paths.runtime.path). Lege sie in den Einstellungen fest."
            return
        }
        guard Paths.steamRunning else {
            lastError = "Steam läuft nicht. Starte Steam und melde dich an."
            return
        }
        guard allowOffline || SteamClient.isOnline != false else {
            // Restarting Steam would cut off the other running games
            if running.isEmpty { reconnectSteam(then: game) } else { offlineGame = game }
            return
        }

        running.insert(game.appID)
        Task {
            if Self.syncSaves, !(game.cloudSaves ?? []).isEmpty { await linkSaves(game) }
            launch(game)
        }
    }

    /// Links the prefix's save folders to the ones macOS Steam syncs, creating
    /// the prefix first if needed. Failures only skip the sync.
    private func linkSaves(_ game: Game) async {
        let prefix = prefix(of: game)
        if !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) {
            await prepare(game)
        }
        do {
            let report = try SaveSync.link(game, prefix: prefix)
            if !report.skipped.isEmpty {
                notice = "Spielstand-Sync für \(game.name) teilweise nicht eingerichtet:\n" + report.skipped.joined(separator: "\n")
            } else if let backup = report.backup {
                notice = "Spielstände von \(game.name) werden jetzt mit Steam Cloud synchronisiert. Eine Sicherung der bisherigen Spielstände liegt in \(backup.path)."
            }
        } catch {
            notice = "Spielstand-Sync für \(game.name) fehlgeschlagen, das Spiel startet ohne Sync: \(error.localizedDescription)"
        }
    }

    private func prepare(_ game: Game) async {
        let process = Process()
        process.executableURL = Paths.runtime.appendingPathComponent("run.sh")
        process.arguments = ["--prepare", String(game.appID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }

    private func launch(_ game: Game) {
        let exe = game.executable as NSString
        let dir = (game.installDir as NSString).appendingPathComponent(exe.deletingLastPathComponent)

        try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        let logURL = Paths.logsDir.appendingPathComponent("\(game.appID).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = Paths.runtime.appendingPathComponent("run.sh")
        process.arguments = [String(game.appID), dir, exe.lastPathComponent]
            + game.arguments.split(separator: " ").map(String.init)
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = log
        process.standardError = log

        let appID = game.appID
        let started = Date()
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.processes[appID] = nil
                self.running.remove(appID)
                // A quick non-zero exit means the game did not start at all
                if status != 0 && Date().timeIntervalSince(started) < 15 {
                    self.lastError = "Das Spiel konnte nicht gestartet werden (Code \(status)). Protokoll: \(logURL.path)"
                }
            }
        }

        do {
            try process.run()
            processes[appID] = process
        } catch {
            running.remove(appID)
            lastError = "Start fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Restarts the Steam client so it logs in again, then starts the game.
    /// Automatic reconnects (after steamcmd ran) skip quietly while games run.
    func reconnectSteam(then game: Game? = nil, automatic: Bool = false) {
        guard !reconnecting, running.isEmpty else {
            if !running.isEmpty && !automatic {
                lastError = "Beende zuerst die laufenden Spiele, Steam wird dafür neu gestartet."
            }
            return
        }
        reconnecting = true
        Task {
            let online = await SteamClient.reconnect()
            reconnecting = false
            if let game {
                if online { play(game) } else { offlineGame = game }
            } else if !online {
                lastError = "Steam hat sich nicht wieder verbunden. Prüfe die Anmeldung im Steam-Fenster."
            }
        }
    }

    /// Ends the game and all Wine processes of its prefix.
    func stop(_ game: Game) {
        let server = Process()
        server.executableURL = Paths.runtime.appendingPathComponent("files/bin/wineserver")
        server.arguments = ["-k"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = Paths.support.appendingPathComponent("prefixes/\(game.appID)").path
        server.environment = env
        try? server.run()
    }

    func prefix(of game: Game) -> URL {
        Paths.support.appendingPathComponent("prefixes/\(game.appID)", isDirectory: true)
    }
}
