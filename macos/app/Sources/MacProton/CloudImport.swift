import CryptoKit
import Foundation

/// Brings Steam Cloud saves to this Mac without starting the game: the user
/// downloads them from Steam's "View Steam Cloud" page, and the import
/// copies them to where Steam keeps them for the game. The files equal the
/// cloud's, so Steam finds them in sync instead of reporting a conflict.
/// Files it replaces are backed up first; it deletes nothing else.
enum CloudImport {
    /// The page lists each file with a folder and its path
    static func pageURL(_ appID: Int) -> URL {
        URL(string: "https://store.steampowered.com/account/remotestorageapp/?appid=\(appID)")!
    }

    /// The "Folder" column of the page
    enum Folder: Hashable {
        /// Empty column: Steam's own cloud folder of the game
        case steamCloud
        /// A Steam root such as WinAppDataLocal or GameInstall
        case root(String)

        var title: String {
            switch self {
            case .steamCloud: return "Leer (Steam-Cloud-Ordner)"
            case .root(let name): return name
            }
        }

        /// As stored in the import records
        var key: String {
            switch self {
            case .steamCloud: return ""
            case .root(let name): return name
            }
        }

        init(key: String) { self = key.isEmpty ? .steamCloud : .root(key) }
    }

    /// A file imported earlier, kept next to the game's save backups
    struct Record: Codable {
        var path: String
        var folder: String
        var sha256: String
        var date: Date
    }

    /// A cloud file of the game and whether it was imported
    struct FileState: Identifiable {
        enum Status { case notImported, imported(Date), changedSince(Date) }
        var path: String
        var folder: Folder
        var status: Status
        var id: String { folder.key + "/" + path }
    }

    private static func recordsFile(_ appID: Int) -> URL {
        SaveSync.backupsDir.appendingPathComponent("\(appID)/cloud-imports.json")
    }

    static func records(_ appID: Int) -> [Record] {
        guard let data = try? Data(contentsOf: recordsFile(appID)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    private static func save(_ records: [Record], appID: Int) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = recordsFile(appID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: file, options: .atomic)
    }

    private static func sha256(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    /// The last import of this path, if any
    static func record(path: String, folder: Folder, in records: [Record]) -> Record? {
        records.last { normalized($0.path) == normalized(path) && $0.folder == folder.key }
    }

    /// The files Steam lists for the game on this Mac, plus those imported
    /// before, each with whether it was imported and is still unchanged.
    static func overview(for game: Game, prefix: URL) -> [FileState] {
        let records = records(game.appID)
        var files = SteamClient.knownCloudFiles(game.appID).map { ($0, Folder.steamCloud) }
        for record in records where !files.contains(where: { normalized($0.0) == normalized(record.path) && $0.1.key == record.folder }) {
            files.append((record.path, Folder(key: record.folder)))
        }
        return files.map { path, folder in
            var status = FileState.Status.notImported
            if let record = record(path: path, folder: folder, in: records) {
                let item = Item(source: URL(fileURLWithPath: "/"), path: path, folder: folder)
                let current = destination(of: item, game: game, prefix: prefix).flatMap(sha256)
                status = current == record.sha256 ? .imported(record.date) : .changedSince(record.date)
            }
            return FileState(path: path, folder: folder, status: status)
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let source: URL
        /// Path from the page's "File Name" column, e.g. out/save/save_0.sav
        var path: String
        var folder: Folder
    }

    static func folders(for game: Game) -> [Folder] {
        var roots = (game.cloudSaves ?? []).map(\.windowsRoot)
        roots.append("GameInstall")
        var seen = Set<String>()
        return [.steamCloud] + roots.filter { seen.insert($0.lowercased()).inserted }.map(Folder.root)
    }

    /// Takes the path Steam knows for a file of the same name, if any.
    static func items(for files: [URL], game: Game) -> [Item] {
        let known = SteamClient.knownCloudFiles(game.appID)
        let fallback: Folder = (game.cloudSaves ?? []).first.map { .root($0.windowsRoot) } ?? .steamCloud
        return files.map { file in
            if let path = known.first(where: { ($0 as NSString).lastPathComponent == file.lastPathComponent }) {
                return Item(source: file, path: path, folder: .steamCloud)
            }
            return Item(source: file, path: file.lastPathComponent, folder: fallback)
        }
    }

    static func base(of folder: Folder, game: Game, prefix: URL) -> URL? {
        switch folder {
        case .steamCloud:
            return SteamClient.appUserData(game.appID)?.appendingPathComponent("remote", isDirectory: true)
        case .root(let name) where name.lowercased() == "gameinstall":
            return URL(fileURLWithPath: game.installDir, isDirectory: true)
        case .root(let name):
            return SaveSync.windowsBase(name, prefix: prefix)
        }
    }

    /// Where the item goes, or nil if its path could leave the folder.
    static func destination(of item: Item, game: Game, prefix: URL) -> URL? {
        let parts = item.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty, !item.path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
              let base = base(of: item.folder, game: game, prefix: prefix) else { return nil }
        return parts.reduce(base) { $0.appendingPathComponent($1) }
    }

    struct Result {
        var copied = 0
        var backup: URL?
    }

    /// Backs up files that would be replaced, then copies the items.
    static func run(_ items: [Item], game: Game, prefix: URL) throws -> Result {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = SaveSync.backupsDir.appendingPathComponent("\(game.appID)/\(stamp)-cloud-import", isDirectory: true)
        var result = Result()

        let targets = try items.map { item -> (URL, URL) in
            guard let target = destination(of: item, game: game, prefix: prefix) else {
                throw SteamCMDError.failed("Ungültiger Pfad: \(item.path)")
            }
            return (item.source, target)
        }
        for (index, (_, target)) in targets.enumerated() where fm.fileExists(atPath: target.path) {
            let saved = backup.appendingPathComponent("\(index)-\(target.lastPathComponent)")
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try fm.copyItem(at: target, to: saved)
            result.backup = backup
        }
        if result.backup != nil {
            let list = targets.map { $0.1.path }.joined(separator: "\n")
            try? list.write(to: backup.appendingPathComponent("ziele.txt"), atomically: true, encoding: .utf8)
        }
        var records = records(game.appID)
        for (item, (source, target)) in zip(items, targets) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            result.copied += 1
            records.removeAll { normalized($0.path) == normalized(item.path) && $0.folder == item.folder.key }
            records.append(Record(path: item.path, folder: item.folder.key, sha256: sha256(target) ?? "", date: Date()))
        }
        try? save(records, appID: game.appID)
        return result
    }
}
