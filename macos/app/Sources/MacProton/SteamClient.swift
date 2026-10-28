import AppKit
import Foundation

/// The macOS Steam client that games talk to. steamcmd logging in with the
/// same account on this Mac replaces the client's session ("Session
/// Replaced"), and the client does not reconnect by itself, so games get no
/// lobbies or other online features until it logs in again.
enum SteamClient {
    static let bundleID = "com.valvesoftware.steam"
    private static let steamDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam")
    private static let connectionLog = steamDir.appendingPathComponent("logs/connection_log.txt")

    /// The client's library folders, each with a steamapps folder
    static var libraryFolders: [String] {
        let file = steamDir.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [steamDir.path] }
        let paths = VDF.parse(text)["libraryfolders"]?.entries.compactMap { $0.1["path"]?.string } ?? []
        return paths.isEmpty ? [steamDir.path] : paths
    }

    /// Whether Steam never synced the game's cloud saves on this Mac: it
    /// keeps a remotecache.vdf per account and app with the change number
    /// it synced to. Nil if no account is known.
    static func cloudNeverSynced(_ appID: Int) -> Bool? {
        guard let cache = appUserData(appID)?.appendingPathComponent("remotecache.vdf") else { return nil }
        guard let cacheText = try? String(contentsOf: cache, encoding: .utf8) else { return true }
        let change = VDF.parse(cacheText)[String(appID), "ChangeNumber"]?.string.flatMap(Int.init) ?? 0
        return change <= 0
    }

    /// Steam's folder for the logged-in account and an app, which holds
    /// remotecache.vdf and, in remote/, the files of the Steam Cloud API.
    static func appUserData(_ appID: Int) -> URL? {
        let file = steamDir.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let users = VDF.parse(text)["users"]?.entries ?? []
        guard let user = users.first(where: { $0.1["MostRecent"]?.string == "1" }) ?? users.first,
              let steamID = UInt64(user.0) else { return nil }
        let accountID = steamID - 76561197960265728  // the account part of a SteamID64
        return steamDir.appendingPathComponent("userdata/\(accountID)/\(appID)", isDirectory: true)
    }

    /// Relative names of the cloud files Steam knows for an app
    static func knownCloudFiles(_ appID: Int) -> [String] {
        guard let cache = appUserData(appID)?.appendingPathComponent("remotecache.vdf"),
              let text = try? String(contentsOf: cache, encoding: .utf8) else { return [] }
        return (VDF.parse(text)[String(appID)]?.entries ?? []).compactMap { name, value in
            value["sha"] != nil ? name : nil
        }
    }

    /// Whether the client has the game fully installed, i.e. its macOS version
    static func isInstalled(_ appID: Int) -> Bool {
        libraryFolders.contains { folder in
            let manifest = (folder as NSString).appendingPathComponent("steamapps/appmanifest_\(appID).acf")
            guard let text = try? String(contentsOfFile: manifest, encoding: .utf8),
                  let flags = VDF.parse(text)["AppState", "StateFlags"]?.string.flatMap(Int.init) else { return false }
            return flags & 4 != 0  // StateFullyInstalled
        }
    }

    /// Runs the game in the client, or opens its install dialog. "steam://run"
    /// alone does not install a game the client wrongly takes as installed,
    /// e.g. after its Windows version ran here and reported its app id.
    static func runOrInstall(_ appID: Int) {
        let action = isInstalled(appID) ? "run" : "install"
        NSWorkspace.shared.open(URL(string: "steam://open/games")!)
        if let url = URL(string: "steam://\(action)/\(appID)") { NSWorkspace.shared.open(url) }
    }

    /// The client's last connection state: true when logged on, false when
    /// logged off, nil while connecting or when the log is unreadable.
    static var isOnline: Bool? {
        guard let handle = try? FileHandle(forReadingFrom: connectionLog) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        // "[2026-10-28 00:43:26] [Logged Off, 4, 0] [U:1:…] ConnectionDisconnected(…)"
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: "] [") else { continue }
            switch line[range.upperBound...].prefix(while: { $0 != "," && $0 != "]" }) {
            case "Logged On": return true
            case "Logged Off": return false
            case "Connecting", "Connected", "Logging On", "Logging Off": return nil
            default: continue
            }
        }
        return nil
    }

    /// Quits and reopens the client, which logs in again with its saved
    /// login. Returns true once it is online, false after a timeout.
    static func reconnect() async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        for _ in 0..<60 where Paths.steamRunning {
            try? await Task.sleep(for: .seconds(1))
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(1))
            if Paths.steamRunning && isOnline == true { return true }
        }
        return false
    }
}
