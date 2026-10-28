import AppKit
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
    var issues: [CompatibilityIssue]?
    var cloudSaves: [CloudSaveLocation]?
    /// Saves live in Steam Cloud, which macOS Steam does not download
    /// before a Windows game starts
    var steamCloud: Bool?

    var id: Int { appID }

    init(appID: Int, name: String, installDir: String, executable: String, arguments: String = "",
         sizeBytes: Int64 = 0) {
        self.appID = appID
        self.name = name
        self.installDir = installDir
        self.executable = executable
        self.arguments = arguments
        self.sizeBytes = sizeBytes
    }

    init(info: AppInfo, installDir: String? = nil) {
        self.init(appID: info.appID, name: info.name,
                  installDir: installDir ?? Paths.gamesDir.appendingPathComponent(Self.folderName(info.name)).path,
                  executable: info.executable)
        apply(info)
    }

    /// Folder a new installation gets, named after the game
    static func folderName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
    }

    /// Takes over what Steam's app info says, keeping folder and history.
    mutating func apply(_ info: AppInfo) {
        name = info.name
        executable = info.executable
        arguments = info.arguments
        sizeBytes = info.sizeBytes
        hasNativeMac = info.hasNativeMac
        issues = info.issues
        cloudSaves = info.cloudSaves
        steamCloud = info.steamCloud
    }

    var headerImageURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    /// steamcmd's app manifest says whether the download is complete; games
    /// added by hand have none, so fall back to the executable.
    var isInstalled: Bool {
        let manifest = (installDir as NSString).appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        if let text = try? String(contentsOfFile: manifest, encoding: .utf8),
           let flags = VDF.parse(text)["AppState", "StateFlags"]?.string.flatMap(Int.init) {
            return flags & 4 != 0  // StateFullyInstalled
        }
        return FileManager.default.fileExists(atPath: (installDir as NSString).appendingPathComponent(executable))
    }

    /// Has a macOS version, which runs through the Steam client instead of Wine
    var runsNatively: Bool { hasNativeMac == true }

    var isInstalledNatively: Bool { runsNatively && SteamClient.isInstalled(appID) }

    /// Build steamcmd installed, from its app manifest
    var installedBuildID: String? {
        let manifest = (installDir as NSString).appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else { return nil }
        return VDF.parse(text)["AppState", "buildid"]?.string
    }

    /// Launched through another store's client, e.g. "steam2ea://launchgame/…"
    var launchesViaURL: Bool { executable.contains("://") }

    /// Name of the disk holding the game, if that is not the startup disk
    var externalVolume: String? {
        let parts = URL(fileURLWithPath: installDir).resolvingSymlinksInPath().pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : nil
    }

    /// False while the disk holding the game is not connected
    var locationAvailable: Bool {
        externalVolume.map { FileManager.default.fileExists(atPath: "/Volumes/" + $0) } ?? true
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

    /// The app's own steamcmd, set up on first launch
    static let steamcmdDir = support.appendingPathComponent("steamcmd", isDirectory: true)

    /// Valve's Windows steamclient DLLs from the Steamworks SDK Redist, which
    /// run.sh puts in each prefix; Steam's DRM needs them
    static let steamRedistDir = support.appendingPathComponent("steamworks-redist", isDirectory: true)

    static var steamRedistAvailable: Bool {
        FileManager.default.fileExists(atPath: steamRedistDir.appendingPathComponent("steamclient64.dll").path)
    }

    static var steamcmd: String? {
        let path = steamcmdDir.appendingPathComponent("steamcmd.sh").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The runtime is x86_64, which Apple silicon Macs run through Rosetta 2.
    static var needsRosetta: Bool {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        return arm64 == 1 && !FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// HOME for steamcmd. Its default data directory is the Steam client's
    /// (~/Library/Application Support/Steam), and the client overwrites
    /// config.vdf there, dropping steamcmd's cached login.
    static let steamcmdHome: URL = {
        let dir = support.appendingPathComponent("steamcmd-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Asks the system rather than running pgrep: views read this while
    /// SwiftUI updates them, and waiting for a process there runs the run
    /// loop, which SwiftUI does not allow. Steam.app in Applications only
    /// starts the client, steam_osx.
    static var steamRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: SteamClient.bundleID)
            .contains { $0.executableURL?.lastPathComponent == "steam_osx" && !$0.isTerminated }
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

    /// Moves the game's folder, and its prefix if asked, to the Trash and
    /// removes it from the library. Only folders MacProton created are
    /// touched: those in its games folder, and elsewhere those steamcmd
    /// installed the game into. Returns an error message if a folder could
    /// not be moved.
    func uninstall(_ game: Game, prefix: URL?) -> String? {
        var failed: [String] = []
        let folder = URL(fileURLWithPath: game.installDir).standardizedFileURL
        let ours = folder.path.hasPrefix(Paths.gamesDir.standardizedFileURL.path + "/")
            || GameLocation.hasManifest(of: game.appID, in: folder)
        if ours, FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            catch { failed.append(folder.path) }
        }
        if let prefix, FileManager.default.fileExists(atPath: prefix.path) {
            do { try FileManager.default.trashItem(at: prefix, resultingItemURL: nil) }
            catch { failed.append(prefix.path) }
        }
        remove(game)
        return failed.isEmpty ? nil : "Nicht in den Papierkorb gelegt:\n" + failed.joined(separator: "\n")
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
