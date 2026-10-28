import AppKit
import Foundation

/// Downloads games with steamcmd and reports progress per app id.
@MainActor
final class Installer: ObservableObject {
    struct Job { var progress: Double; var status: String }

    @Published private(set) var jobs: [Int: Job] = [:]
    @Published var loginRequired: String?
    @Published var lastError: String?

    var account: String {
        let saved = UserDefaults.standard.string(forKey: "steamAccount") ?? ""
        return saved.isEmpty ? (detectSteamAccount() ?? "") : saved
    }

    func isBusy(_ game: Game) -> Bool { jobs[game.appID] != nil }

    func install(_ game: Game, library: Library) {
        guard jobs[game.appID] == nil else { return }
        let account = self.account
        guard !account.isEmpty else {
            lastError = "Kein Steam-Konto gefunden. Trage es in den Einstellungen ein."
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

    /// Opens Terminal with an interactive steamcmd login, so the user enters
    /// password and Steam Guard code there; steamcmd caches the login.
    func openLoginTerminal(account: String) {
        guard let steamcmd = Paths.steamcmd else { return }
        let script = Paths.support.appendingPathComponent("steam-login.command")
        let quotedAccount = account.replacingOccurrences(of: "'", with: "")
        let text = """
        #!/bin/bash
        echo "Anmeldung für MacProton. Gib Passwort und ggf. Steam-Guard-Code ein."
        HOME='\(Paths.steamcmdHome.path)' '\(steamcmd)' +login '\(quotedAccount)' +quit
        echo
        echo "Fertig. Dieses Fenster kann geschlossen werden."
        """
        try? text.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}
