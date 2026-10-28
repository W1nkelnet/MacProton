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
    /// What a starting game waits for, e.g. its install scripts
    @Published private(set) var preparing: [Int: String] = [:]

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
            let prefix = prefix(of: game)
            if !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) {
                preparing[game.appID] = "Richte Wine ein …"
                await runScript(["--prepare", String(game.appID)])
            }
            await runInstallScripts(game, prefix: prefix)
            preparing[game.appID] = nil
            if Self.syncSaves, !(game.cloudSaves ?? []).isEmpty { await linkSaves(game) }
            launch(game)
        }
    }

    /// Runs the game's install scripts not done yet, e.g. the Visual C++
    /// runtime installers; their output goes to the game's setup log.
    private func runInstallScripts(_ game: Game, prefix: URL) async {
        let steps = InstallScripts.pending(for: game, prefix: prefix)
        guard !steps.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        let log = Paths.logsDir.appendingPathComponent("\(game.appID)-setup.log")
        for (i, step) in steps.enumerated() {
            preparing[game.appID] = "Installiere Komponenten des Spiels (\(i + 1)/\(steps.count)) …"
            let status = await runScript(["--exec", String(game.appID), step.program] + step.arguments, log: log)
            // 3010: reboot required, 1638: a newer version is installed
            if [0, 3010, 1638].contains(status) {
                InstallScripts.markDone(step, prefix: prefix)
            }
        }
    }

    /// Links the prefix's save folders to the ones macOS Steam syncs.
    /// Failures only skip the sync.
    private func linkSaves(_ game: Game) async {
        let prefix = prefix(of: game)
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

    /// Runs run.sh with the arguments and returns its exit status.
    @discardableResult
    private func runScript(_ arguments: [String], log: URL? = nil) async -> Int32 {
        let process = Process()
        process.executableURL = Paths.runtime.appendingPathComponent("run.sh")
        process.arguments = arguments
        var output: FileHandle = .nullDevice
        if let log {
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); output = handle }
        }
        process.standardOutput = output
        process.standardError = output
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
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
        // Apple's Metal Performance HUD, for any Metal app
        if UserDefaults.standard.bool(forKey: "metalHUD") {
            var environment = ProcessInfo.processInfo.environment
            environment["MTL_HUD_ENABLED"] = "1"
            process.environment = environment
        }
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

    /// Starts the macOS version through the Steam client, which installs it
    /// first if needed, reconnecting the client if steamcmd took its session.
    func playNative(_ game: Game) {
        guard !reconnecting else { return }
        if Paths.steamRunning && SteamClient.isOnline == false && running.isEmpty {
            reconnect { _ in SteamClient.runOrInstall(game.appID) }
        } else {
            SteamClient.runOrInstall(game.appID)
        }
    }

    /// Restarts the Steam client so it logs in again, then starts the game.
    /// Automatic reconnects (after steamcmd ran) skip quietly while games run.
    func reconnectSteam(then game: Game? = nil, automatic: Bool = false) {
        guard running.isEmpty else {
            if !automatic { lastError = "Beende zuerst die laufenden Spiele, Steam wird dafür neu gestartet." }
            return
        }
        reconnect { online in
            if let game {
                if online { self.play(game) } else { self.offlineGame = game }
            } else if !online {
                self.lastError = "Steam hat sich nicht wieder verbunden. Prüfe die Anmeldung im Steam-Fenster."
            }
        }
    }

    private func reconnect(then completion: @escaping (Bool) -> Void) {
        guard !reconnecting else { return }
        reconnecting = true
        Task {
            let online = await SteamClient.reconnect()
            reconnecting = false
            completion(online)
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
