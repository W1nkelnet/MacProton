import AppKit
import Foundation

/// Downloads games with steamcmd and reports progress per app id.
@MainActor
final class Installer: ObservableObject {
    struct Job { var progress: Double; var status: String }

    @Published private(set) var jobs: [Int: Job] = [:]
    /// Games being moved to another folder, with progress
    @Published private(set) var moves: [Int: Double] = [:]
    @Published var loginRequired: String?
    @Published var lastError: String?

    var account: String {
        let saved = UserDefaults.standard.string(forKey: "steamAccount") ?? ""
        return saved.isEmpty ? (detectSteamAccount() ?? "") : saved
    }

    func isBusy(_ game: Game) -> Bool { jobs[game.appID] != nil || moves[game.appID] != nil }

    /// Installs Rosetta 2 in Terminal, where macOS may ask for an admin password.
    func installRosetta() {
        let script = Paths.support.appendingPathComponent("install-rosetta.command")
        let text = """
        #!/bin/bash
        echo "Rosetta 2 für MacProton installieren …"
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        echo
        echo "Fertig. Dieses Fenster kann geschlossen werden."
        """
        try? text.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    /// Downloads or updates the game. A new installation goes to the default
    /// location from the settings; one already begun stays where it is.
    func install(_ game: Game, library: Library) {
        guard !isBusy(game) else { return }
        // Not a new installation, only its disk is missing
        guard game.locationAvailable else { return start(game, library: library) }
        let location = Paths.gameLocation
        guard game.isInstalled || FileManager.default.fileExists(atPath: game.installDir) else {
            if location != Paths.gamesDir {
                guard FileManager.default.fileExists(atPath: location.path) else {
                    lastError = "Der Standard-Speicherort „\(location.path)“ ist nicht da. Schließ das Laufwerk an oder ändere ihn in den Einstellungen."
                    return
                }
            }
            install(game, in: location, library: library)
            return
        }
        start(game, library: library)
    }

    private func start(_ game: Game, library: Library) {
        guard game.locationAvailable else {
            lastError = "Das Laufwerk „\(game.externalVolume ?? "")“ mit \(game.name) ist nicht verbunden. Schließ es an oder wähle per Rechtsklick „Installieren in …“ einen anderen Ort."
            return
        }
        let account = self.account
        guard !account.isEmpty else {
            loginRequired = ""  // opens the login window
            return
        }
        jobs[game.appID] = Job(progress: 0, status: "Verbinde mit Steam …")
        let appID = game.appID

        Task {
            do {
                try await SteamCMD.install(appID: appID, into: game.installDir, account: account) { value, line in
                    Task { @MainActor in
                        let status = line.contains("verifying") ? "Prüfe Dateien" : "Lade herunter"
                        self.jobs[appID] = Job(progress: value, status: status)
                    }
                }
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
            } catch SteamCMDError.loginRequired(let name) {
                loginRequired = name
            } catch {
                lastError = error.localizedDescription
            }
            jobs[appID] = nil
        }
    }

    /// Installs the game into its own folder in `folder` from now on.
    func install(_ game: Game, in folder: URL, library: Library) {
        guard !isBusy(game) else { return }
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
        start(updated, library: library)
    }

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
                lastError = "\(game.name) wurde nicht verschoben: \(error.localizedDescription)"
            }
            moves[appID] = nil
        }
    }
}
