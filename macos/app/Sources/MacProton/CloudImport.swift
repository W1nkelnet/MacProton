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
        for (source, target) in targets {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            result.copied += 1
        }
        return result
    }
}
