import AppKit
import Foundation

/// Lets games live elsewhere than in MacProton's games folder, e.g. on an
/// external disk: a new installation goes into a chosen folder, and an
/// installed game can move to one.
enum GameLocation {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Progress of a move, written by the copying thread and read by the app
    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0.0
        private var _finished = false

        var value: Double {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }

        var isFinished: Bool { lock.withLock { _finished } }

        func finish() { lock.withLock { _finished = true } }
    }

    /// The folder chosen last, where the open panel starts next time
    private static var lastFolder: URL? {
        get { UserDefaults.standard.string(forKey: "gameLocation").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "gameLocation") }
    }

    /// Asks for the folder that will hold the game's own folder.
    @MainActor static func choose(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = lastFolder
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        lastFolder = url
        return url
    }

    /// Where the game goes in the chosen folder. Holds that folder steamcmd's
    /// manifest of the game, it is an existing installation, which steamcmd
    /// checks and completes instead of downloading again.
    static func installDir(for game: Game, in folder: URL) -> URL {
        if hasManifest(of: game.appID, in: folder) { return folder }
        return folder.appendingPathComponent(Game.folderName(game.name), isDirectory: true)
    }

    static func hasManifest(of appID: Int, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("steamapps/appmanifest_\(appID).acf").path)
    }

    /// Why the game cannot be installed into `dir`, or nil.
    static func installProblem(_ game: Game, dir: URL) -> String? {
        let folder = dir.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return "MacProton darf in „\(folder.path)“ nicht schreiben. Laufwerke im Windows-Format NTFS kann macOS nur lesen."
        }
        if !hasManifest(of: game.appID, in: dir), game.sizeBytes > 0, let free = freeSpace(at: folder), free < game.sizeBytes {
            return "\(game.name) braucht \(format(game.sizeBytes)), auf dem Laufwerk sind nur \(format(free)) frei."
        }
        return nil
    }

    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Moves `source` to `target`. On the same disk that is a rename; to
    /// another disk the files are copied with progress, and the original
    /// goes away only once the copy is complete. A failed copy is removed.
    /// Returns a note if the game moved but parts of the original remain.
    static func move(_ source: URL, to target: URL, progress: Progress) throws -> String? {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        // Both exist, so they resolve alike, unlike the target
        let from = source.resolvingSymlinksInPath().path, into = folder.resolvingSymlinksInPath().path
        if into == from || into.hasPrefix(from + "/") {
            throw Failure("Ein Spiel kann nicht in seinen eigenen Ordner verschoben werden.")
        }
        if fm.fileExists(atPath: target.path) {
            throw Failure("In „\(folder.path)“ gibt es schon einen Ordner „\(target.lastPathComponent)“.")
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            throw Failure("MacProton darf in „\(folder.path)“ nicht schreiben. Laufwerke im Windows-Format NTFS kann macOS nur lesen.")
        }
        if sameVolume(source, folder) {
            try fm.moveItem(at: source, to: target)
            return nil
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var items: [(path: String, directory: Bool, size: Int64)] = []
        var total: Int64 = 0
        let files = fm.enumerator(atPath: source.path)
        while let path = files?.nextObject() as? String {
            let values = try source.appendingPathComponent(path).resourceValues(forKeys: keys)
            let directory = values.isDirectory == true && values.isSymbolicLink != true
            let size = Int64(directory ? 0 : values.fileSize ?? 0)
            items.append((path, directory, size))
            total += size
        }
        if let free = freeSpace(at: folder), free < total {
            throw Failure("Das Spiel braucht \(format(total)), auf dem Ziellaufwerk sind nur \(format(free)) frei.")
        }

        var copied: Int64 = 0
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for item in items {
                let destination = target.appendingPathComponent(item.path)
                if item.directory {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try fm.copyItem(at: source.appendingPathComponent(item.path), to: destination)
                    copied += item.size
                    progress.value = total > 0 ? Double(copied) / Double(total) : 1
                }
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        do { try fm.removeItem(at: source) } catch {
            return "Der alte Ordner „\(source.path)“ ließ sich nicht ganz löschen: \(error.localizedDescription)"
        }
        return nil
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let first = (try? a.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              let second = (try? b.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }
}
