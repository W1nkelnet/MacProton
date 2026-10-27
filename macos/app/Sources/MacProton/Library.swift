import Foundation

struct Game: Codable, Identifiable, Hashable {
    var appID: Int
    var name: String
    /// Folder steamcmd installs the Windows version into
    var installDir: String
    /// Path of the executable relative to installDir, with "/" separators
    var executable: String
    var arguments: String = ""
    var sizeBytes: Int64 = 0
    var lastPlayed: Date?
    /// The game also has a native macOS version, no need for Proton
    var hasNativeMac: Bool?

    var id: Int { appID }

    var headerImageURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: (installDir as NSString).appendingPathComponent(executable))
    }
}

/// Paths and settings shared by the app.
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacProton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let libraryFile = support.appendingPathComponent("library.json")
    static let gamesDir = support.appendingPathComponent("games", isDirectory: true)
    static let logsDir = support.appendingPathComponent("logs", isDirectory: true)

    /// Proton runtime: dist directory produced by macos/build.sh, containing
    /// run.sh and files/. Configurable in the settings.
    static var runtime: URL {
        if let custom = UserDefaults.standard.string(forKey: "runtimePath"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("run.sh").path) {
            return bundled
        }
        return support.appendingPathComponent("runtime", isDirectory: true)
    }

    static var runtimeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("run.sh").path)
    }

    static let steamcmd: String? = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// HOME for steamcmd. Its default data directory is the Steam client's
    /// (~/Library/Application Support/Steam), and the client overwrites
    /// config.vdf there, dropping steamcmd's cached login.
    static let steamcmdHome: URL = {
        let dir = support.appendingPathComponent("steamcmd-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var steamRunning: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-q", "steam_osx"]
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var games: [Game] = []

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile),
              let decoded = try? JSONDecoder().decode([Game].self, from: data) else { return }
        games = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(games).write(to: Paths.libraryFile, options: .atomic)
    }

    func upsert(_ game: Game) {
        if let index = games.firstIndex(where: { $0.appID == game.appID }) {
            games[index] = game
        } else {
            games.append(game)
            games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        save()
    }

    func remove(_ game: Game) {
        games.removeAll { $0.appID == game.appID }
        save()
    }

    func markPlayed(_ game: Game) {
        guard var updated = games.first(where: { $0.appID == game.appID }) else { return }
        updated.lastPlayed = Date()
        upsert(updated)
    }
}

/// The Steam account last logged in to the macOS Steam client.
func detectSteamAccount() -> String? {
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/config/loginusers.vdf")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let users = VDF.parse(text)["users"]?.entries ?? []
    let recent = users.first { $0.1["MostRecent"]?.string == "1" } ?? users.first
    return recent?.1["AccountName"]?.string
}
