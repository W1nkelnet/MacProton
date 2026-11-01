import Foundation

/// A Steam Cloud conflict for the user to decide
struct CloudConflictPrompt: Identifiable {
    let id = UUID()
    let game: Game
    let files: [String]
    let beforeStart: Bool
    let answer: (CloudSync.Resolution?) -> Void
}

/// The sync before a start failed; the user decides whether to start anyway
struct CloudFailurePrompt: Identifiable {
    let id = UUID()
    let game: Game
    let message: String
    let answer: (Bool) -> Void
}

/// Starts games through the runtime's run.sh and tracks running ones.
@MainActor
final class Runner: ObservableObject {
    @Published private(set) var running: Set<Int> = []
    @Published var lastError: String?
    @Published var notice: String?
    /// Game the user started while the Steam client was offline
    @Published var offlineGame: Game?
    /// Game whose Steam Cloud saves this Mac never synced
    @Published var cloudWarningGame: Game?
    @Published private(set) var reconnecting = false
    /// What a starting game waits for, e.g. its install scripts
    @Published private(set) var preparing: [Int: String] = [:]
    @Published var cloudConflict: CloudConflictPrompt?
    @Published var cloudFailure: CloudFailurePrompt?
    /// Games whose cloud saves all came into the prefix before this start
    private var cloudPulled: Set<Int> = []
    /// The start of a game or the upload after it, which stop() cancels
    private var syncTasks: [Int: Task<Void, Never>] = [:]

    static var syncSaves: Bool { UserDefaults.standard.object(forKey: "syncSaves") as? Bool ?? true }

    private var processes: [Int: Process] = [:]

    func isRunning(_ game: Game) -> Bool { running.contains(game.appID) }

    /// Games the user was told about their Steam Cloud saves
    private static var cloudWarned: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "cloudWarnedApps") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "cloudWarnedApps") }
    }

    /// The user got the cloud saves, so the notice is not needed anymore.
    func markCloudHandled(_ game: Game) {
        Self.cloudWarned.insert(game.appID)
    }

    /// Starts the game after the Steam Cloud notice.
    func playAfterCloudNotice(_ game: Game) {
        Self.cloudWarned.insert(game.appID)
        play(game)
    }

    func play(_ game: Game, allowOffline: Bool = false) {
        guard !isRunning(game), !reconnecting else { return }
        guard !game.launchesViaURL else {
            lastError = String(localized: "\(game.name) startet über den Launcher eines anderen Anbieters (\(game.executable.prefix { $0 != ":" })). Solche Launcher unterstützt MacProton noch nicht.")
            return
        }
        guard Paths.runtimeAvailable else {
            lastError = String(localized: "Proton-Laufzeit nicht gefunden in \(Paths.runtime.path). Lege sie in den Einstellungen fest.")
            return
        }
        guard game.locationAvailable else {
            lastError = String(localized: "Das Laufwerk „\(game.externalVolume ?? "")“ mit \(game.name) ist nicht verbunden.")
            return
        }
        guard Paths.steamRunning else {
            lastError = String(localized: "Steam läuft nicht. Starte Steam und melde dich an.")
            return
        }
        // macOS Steam does not download cloud saves before a Windows game starts
        if game.steamCloud == true, !CloudSync.applies(to: game), !Self.cloudWarned.contains(game.appID),
           SteamClient.cloudNeverSynced(game.appID) == true {
            cloudWarningGame = game
            return
        }
        guard allowOffline || SteamClient.isOnline != false else {
            // Restarting Steam would cut off the other running games
            if running.isEmpty { reconnectSteam(then: game) } else { offlineGame = game }
            return
        }

        running.insert(game.appID)
        syncTasks[game.appID] = Task {
            defer { syncTasks[game.appID] = nil }
            let prefix = prefix(of: game)
            if !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) {
                preparing[game.appID] = String(localized: "Richte Wine ein …")
                await runScript(["--prepare", String(game.appID)])
            }
            await runInstallScripts(game, prefix: prefix)
            preparing[game.appID] = nil
            if Self.syncSaves, !(game.cloudSaves ?? []).isEmpty { await linkSaves(game) }
            if CloudSync.applies(to: game) {
                preparing[game.appID] = String(localized: "Gleiche Spielstände mit der Steam Cloud ab …")
                let start = await syncCloudBeforeStart(game, prefix: prefix)
                preparing[game.appID] = nil
                guard start else {
                    running.remove(game.appID)
                    return
                }
            }
            guard !Task.isCancelled else {
                running.remove(game.appID)
                return
            }
            launch(game)
        }
    }

    /// Brings the cloud's saves into the prefix. False if the user cancelled the start.
    private func syncCloudBeforeStart(_ game: Game, prefix: URL) async -> Bool {
        cloudPulled.remove(game.appID)
        do {
            let plan = try await CloudSync.prepare(game, prefix: prefix, beforeStart: true)
            var resolution: CloudSync.Resolution?
            if !plan.conflicts.isEmpty {
                guard let choice = await askCloudConflict(game, plan.conflicts.map(\.path), beforeStart: true) else {
                    plan.connection.disconnect()
                    return false
                }
                resolution = choice
            }
            let summary = try await CloudSync.apply(plan, resolving: resolution)
            cloudPulled.insert(game.appID)
            if let backup = summary.backup {
                var parts: [String] = []
                if summary.downloaded > 0 {
                    parts.append(String(localized: "\(summary.downloaded) Spielstand-Dateien von \(game.name) kamen aus der Steam Cloud."))
                }
                if summary.backedUpFromMac > 0 {
                    parts.append(String(localized: "\(summary.backedUpFromMac) Dateien dieses Macs, die dabei ersetzt wurden, liegen gesichert in \(backup.appendingPathComponent("mac").path)."))
                }
                if summary.backedUpFromCloud > 0 {
                    parts.append(String(localized: "Die Cloud-Version von \(summary.backedUpFromCloud) Dateien liegt gesichert in \(backup.appendingPathComponent("cloud").path). Nach dem Spielen lädt MacProton die Version dieses Macs hoch."))
                }
                notice = parts.joined(separator: " ")
            }
            return true
        } catch {
            // Stopped from the game card: the files that came are kept
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                cloudFailure = CloudFailurePrompt(game: game, message: error.localizedDescription) { continuation.resume(returning: $0) }
            }
        }
    }

    /// Uploads what the game saved. Files that do not make it stay on this
    /// Mac and go up after the next session.
    private func syncCloudAfterExit(_ game: Game) async {
        let allowDeletes = cloudPulled.remove(game.appID) != nil
        do {
            let plan = try await CloudSync.prepare(game, prefix: prefix(of: game), beforeStart: false,
                                                   allowCloudDeletes: allowDeletes)
            var resolution: CloudSync.Resolution?
            if !plan.conflicts.isEmpty {
                resolution = await askCloudConflict(game, plan.conflicts.map(\.path), beforeStart: false)
            }
            _ = try await CloudSync.apply(plan, resolving: resolution)
        } catch {
            if Task.isCancelled {
                notice = String(localized: "Hochladen der Spielstände von \(game.name) abgebrochen. Sie bleiben auf diesem Mac und gehen nach dem nächsten Spielen mit hoch.")
            } else {
                lastError = String(localized: "Die Spielstände von \(game.name) konnten nicht in die Steam Cloud geladen werden: \(error.localizedDescription) Sie bleiben auf diesem Mac und gehen nach dem nächsten Spielen mit hoch.")
            }
        }
    }

    private func askCloudConflict(_ game: Game, _ paths: [String], beforeStart: Bool) async -> CloudSync.Resolution? {
        await withCheckedContinuation { continuation in
            cloudConflict = CloudConflictPrompt(game: game, files: paths, beforeStart: beforeStart) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Waits until nothing runs in the game's prefix anymore, such as a game
    /// its launcher started.
    private func waitForPrefix(_ game: Game) async {
        let server = Process()
        server.executableURL = Paths.runtime.appendingPathComponent("files/bin/wineserver")
        server.arguments = ["-w"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix(of: game).path
        server.environment = env
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            server.terminationHandler = { _ in continuation.resume() }
            do { try server.run() } catch { continuation.resume() }
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
            preparing[game.appID] = String(localized: "Installiere Komponenten des Spiels (\(i + 1)/\(steps.count)) …")
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
                notice = String(localized: "Spielstand-Sync für \(game.name) teilweise nicht eingerichtet:\n") + report.skipped.joined(separator: "\n")
            } else if let backup = report.backup {
                notice = String(localized: "Spielstände von \(game.name) werden jetzt mit Steam Cloud synchronisiert. Eine Sicherung der bisherigen Spielstände liegt in \(backup.path).")
            }
        } catch {
            notice = String(localized: "Spielstand-Sync für \(game.name) fehlgeschlagen, das Spiel startet ohne Sync: \(error.localizedDescription)")
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

    /// On disks without extended attributes, such as exFAT, macOS keeps them in
    /// "._" files next to every file a download wrote. Games that read whole
    /// folders choke on those: Foundation took them for localization files
    /// and crashed. They only hold macOS metadata.
    static func removeAppleDoubleFiles(in dir: String) {
        guard let files = FileManager.default.enumerator(atPath: dir) else { return }
        for case let path as String in files where (path as NSString).lastPathComponent.hasPrefix("._") {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(path))
        }
    }

    private func launch(_ game: Game) {
        let exe = game.executable as NSString
        let dir = (game.installDir as NSString).appendingPathComponent(exe.deletingLastPathComponent)
        if game.externalVolume != nil {
            Self.removeAppleDoubleFiles(in: game.installDir)
        }

        try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        let logURL = Paths.logsDir.appendingPathComponent("\(game.appID).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = Paths.runtime.appendingPathComponent("run.sh")
        process.arguments = [String(game.appID), dir, exe.lastPathComponent]
            + game.arguments.split(separator: " ").map(String.init)
            + InstallScripts.split(game.launchOptions ?? "")
        var environment = ProcessInfo.processInfo.environment
        // Apple's Metal Performance HUD, for any Metal app
        if UserDefaults.standard.bool(forKey: "metalHUD") {
            environment["MTL_HUD_ENABLED"] = "1"
        }
        environment.merge(Upscaling.current.environment) { $1 }
        environment["MACPROTON_VULKAN_DRIVER"] = VulkanDriver.effective(for: game).rawValue
        if game.usesZink {
            environment["MACPROTON_OPENGL"] = "zink"
        }
        if UserDefaults.standard.object(forKey: "steamOverlay") as? Bool == false {
            environment["MACPROTON_STEAM_OVERLAY"] = "0"
        }
        process.environment = environment
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
                // A quick non-zero exit means the game did not start at all
                if status != 0 && Date().timeIntervalSince(started) < 15 {
                    self.lastError = String(localized: "Das Spiel konnte nicht gestartet werden (Code \(status)). Protokoll: \(logURL.path)")
                }
                if CloudSync.applies(to: game) {
                    self.preparing[appID] = String(localized: "Lade Spielstände in die Steam Cloud …")
                    let upload = Task {
                        await self.waitForPrefix(game)
                        await self.syncCloudAfterExit(game)
                    }
                    self.syncTasks[appID] = upload
                    await upload.value
                    self.syncTasks[appID] = nil
                    self.preparing[appID] = nil
                }
                self.running.remove(appID)
            }
        }

        do {
            try process.run()
            processes[appID] = process
        } catch {
            running.remove(appID)
            lastError = String(localized: "Start fehlgeschlagen: \(error.localizedDescription)")
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
            if !automatic { lastError = String(localized: "Beende zuerst die laufenden Spiele, Steam wird dafür neu gestartet.") }
            return
        }
        reconnect { online in
            if let game {
                if online { self.play(game) } else { self.offlineGame = game }
            } else if !online {
                self.lastError = String(localized: "Steam hat sich nicht wieder verbunden. Prüfe die Anmeldung im Steam-Fenster.")
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
        // Also ends a cloud sync before the start or after the game
        if preparing[game.appID] != nil { syncTasks[game.appID]?.cancel() }
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
