import Foundation

/// Lets Steam Auto-Cloud sync the saves of the Windows version: macOS Steam
/// only syncs the macOS save folder, so the folder in the Wine prefix is
/// replaced with a link to it. Only done for games whose saves are the same
/// files on both systems (see AppAnalysis.cloudSaves). Both folders are
/// backed up before anything is changed.
enum SaveSync {
    struct Report {
        var linked: [String] = []
        var skipped: [String] = []
        var backup: URL?
    }

    static let backupsDir = Paths.support.appendingPathComponent("save-backups", isDirectory: true)

    /// Folder of a Steam Windows root inside the prefix (Proton's user is
    /// always "steamuser")
    static func windowsBase(_ root: String, prefix: URL) -> URL? {
        let user = prefix.appendingPathComponent("drive_c/users/steamuser", isDirectory: true)
        switch root.lowercased() {
        case "winappdatalocallow": return user.appendingPathComponent("AppData/LocalLow")
        case "winappdatalocal": return user.appendingPathComponent("AppData/Local")
        case "winappdataroaming": return user.appendingPathComponent("AppData/Roaming")
        case "winmydocuments": return user.appendingPathComponent("Documents")
        case "winsavedgames": return user.appendingPathComponent("Saved Games")
        default: return nil
        }
    }

    static func macBase(_ root: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch root.lowercased() {
        case "macappsupport": return home.appendingPathComponent("Library/Application Support")
        case "macdocuments": return home.appendingPathComponent("Documents")
        case "machome": return home
        case "maccaches": return home.appendingPathComponent("Library/Caches")
        default: return nil
        }
    }

    static func link(_ game: Game, prefix: URL) throws -> Report {
        var report = Report()
        let fm = FileManager.default
        let prefixReal = prefix.resolvingSymlinksInPath().path

        for location in game.cloudSaves ?? [] {
            guard let winBase = windowsBase(location.windowsRoot, prefix: prefix),
                  let macBase = macBase(location.macRoot) else {
                report.skipped.append("\(location.windowsRoot) → \(location.macRoot): unbekannter Speicherort")
                continue
            }
            let winDir = winBase.appendingPathComponent(location.windowsPath, isDirectory: true)
            let macDir = macBase.appendingPathComponent(location.macPath, isDirectory: true)

            // Already linked?
            if let target = try? fm.destinationOfSymbolicLink(atPath: winDir.path) {
                if URL(fileURLWithPath: target).standardizedFileURL == macDir.standardizedFileURL {
                    report.linked.append(macDir.path)
                } else {
                    report.skipped.append(String(localized: "\(winDir.path) ist bereits eine Verknüpfung nach \(target)"))
                }
                continue
            }
            // Never touch folders that resolve outside the prefix, e.g. when
            // Wine links Documents to the real ~/Documents
            let winReal = winDir.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(winDir.lastPathComponent).path
            guard winReal.hasPrefix(prefixReal + "/") else {
                report.skipped.append(String(localized: "\(winDir.path) liegt außerhalb des Prefix (\(winReal))"))
                continue
            }

            // Back up both sides before changing anything
            if report.backup == nil, hasFiles(winDir) || hasFiles(macDir) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                report.backup = backupsDir.appendingPathComponent("\(game.appID)/\(stamp)", isDirectory: true)
            }
            if let backup = report.backup {
                let index = (game.cloudSaves ?? []).firstIndex(of: location) ?? 0
                if hasFiles(winDir) {
                    try copy(winDir, to: backup.appendingPathComponent("\(index)-windows"))
                }
                if hasFiles(macDir) {
                    try copy(macDir, to: backup.appendingPathComponent("\(index)-mac"))
                }
            }

            // Merge into the macOS folder: the newer file wins
            try fm.createDirectory(at: macDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: winDir.path) {
                try merge(winDir, into: macDir)
                try fm.removeItem(at: winDir)
            }
            try fm.createDirectory(at: winDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: winDir, withDestinationURL: macDir)
            report.linked.append(macDir.path)
        }
        return report
    }

    private static func hasFiles(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return items.contains { $0 != ".DS_Store" }
    }

    private static func copy(_ dir: URL, to backup: URL) throws {
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir, to: backup)
    }

    private static func merge(_ source: URL, into target: URL) throws {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return }
        for case let file as URL in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let destination = target.appendingPathComponent(relative)
            let sourceDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let destinationDate = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               destinationDate >= sourceDate {
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: file, to: destination)
        }
    }
}
