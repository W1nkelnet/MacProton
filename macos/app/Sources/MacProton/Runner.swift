import Foundation

/// Starts games through the runtime's run.sh and tracks running ones.
@MainActor
final class Runner: ObservableObject {
    @Published private(set) var running: Set<Int> = []
    @Published var lastError: String?

    private var processes: [Int: Process] = [:]

    func isRunning(_ game: Game) -> Bool { running.contains(game.appID) }

    func play(_ game: Game) {
        guard !isRunning(game) else { return }
        guard Paths.runtimeAvailable else {
            lastError = "Proton-Laufzeit nicht gefunden in \(Paths.runtime.path). Lege sie in den Einstellungen fest."
            return
        }
        guard Paths.steamRunning else {
            lastError = "Steam läuft nicht. Starte Steam und melde dich an."
            return
        }

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
            running.insert(appID)
        } catch {
            lastError = "Start fehlgeschlagen: \(error.localizedDescription)"
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
