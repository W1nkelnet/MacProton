import AppKit
import Foundation

/// The macOS Steam client that games talk to. steamcmd logging in with the
/// same account on this Mac replaces the client's session ("Session
/// Replaced"), and the client does not reconnect by itself, so games get no
/// lobbies or other online features until it logs in again.
enum SteamClient {
    static let bundleID = "com.valvesoftware.steam"
    private static let connectionLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/logs/connection_log.txt")

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
