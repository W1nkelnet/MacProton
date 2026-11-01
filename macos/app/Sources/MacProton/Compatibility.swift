import Foundation

/// What MacProton can tell about a game before running it, from Steam's app
/// info: anti-cheat, third-party launchers and Steam Deck test results.
enum CompatibilityIssue: String, Codable, Hashable {
    /// Anti-cheat on the default launch option; MacProton uses an option
    /// without it, so only offline or single player modes may work
    case antiCheatOffline
    /// Anti-cheat without an alternative; the game most likely won't start
    case antiCheat
    /// Anti-cheat files found in the installed game
    case antiCheatFiles
    /// Needs a launcher like EA app or Ubisoft Connect
    case thirdPartyLauncher
    /// Single player needs an internet connection
    case needsInternet

    var title: String {
        switch self {
        case .antiCheatOffline: return String(localized: "Anti-Cheat: nur offline")
        case .antiCheat: return "Anti-Cheat"
        case .antiCheatFiles: return String(localized: "Anti-Cheat im Spiel")
        case .thirdPartyLauncher: return "Fremd-Launcher"
        case .needsInternet: return "Braucht Internet"
        }
    }

    var explanation: String {
        switch self {
        case .antiCheatOffline:
            return String(localized: "Der normale Start nutzt Anti-Cheat (EasyAntiCheat/BattlEye), das unter MacProton nicht läuft. MacProton startet stattdessen die Version ohne Anti-Cheat – Einzelspieler oder nicht-offizielle Server können funktionieren, offizielle Online-Server nicht.")
        case .antiCheat:
            return String(localized: "Das Spiel nutzt Anti-Cheat (EasyAntiCheat/BattlEye). Dafür gibt es unter MacProton keine Laufzeitumgebung; das Spiel startet sehr wahrscheinlich nicht.")
        case .antiCheatFiles:
            return String(localized: "Im Spielordner liegt EasyAntiCheat oder BattlEye. Online-Modi mit Anti-Cheat funktionieren unter MacProton nicht; manche Spiele bieten im Launcher einen Start ohne Anti-Cheat.")
        case .thirdPartyLauncher:
            return String(localized: "Das Spiel braucht einen eigenen Launcher (z. B. EA app oder Ubisoft Connect), der mit installiert werden muss und unter Wine oft Probleme macht.")
        case .needsInternet:
            return String(localized: "Laut Steam braucht auch der Einzelspielermodus eine Internetverbindung.")
        }
    }

    /// Issues that most likely prevent the game from running at all
    var isBlocking: Bool { self == .antiCheat }
}

/// A save folder synced by Steam Auto-Cloud on both Windows and macOS,
/// with the same files on both, from the app's "ufs" section.
struct CloudSaveLocation: Codable, Hashable {
    /// Steam root name and path for Windows, e.g. WinAppDataLocalLow
    var windowsRoot: String
    var windowsPath: String
    /// Steam root name and path for macOS, e.g. MacAppSupport
    var macRoot: String
    var macPath: String
}

/// A Steam Auto-Cloud rule for the Windows version, from the app's "ufs"
/// section: which files under which folder the cloud keeps.
struct CloudRule: Codable, Hashable {
    /// Root and path as the cloud names its files, e.g. WinAppDataLocalLow and
    /// "Redbeet Interactive/Raft/User/User_{64BitSteamID}"
    var root: String
    var path: String
    /// Where Windows keeps them, after the app's root overrides for Windows
    var localRoot: String
    var localPath: String
    /// File name pattern such as "*.rgd"
    var pattern: String
    var recursive: Bool
    /// ERemoteStoragePlatform bits
    var platforms: UInt32
}

enum AppAnalysis {
    static let antiCheatMarkers = ["_be.exe", "battleye", "easyanticheat", "_eac.exe", "start_protected_game"]

    /// Anti-cheat runtimes shipped in the game folder
    static func hasAntiCheatFiles(in dir: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.contains { name in
            let lower = name.lowercased()
            return lower == "easyanticheat" || lower == "battleye" || lower.hasPrefix("easyanticheat_eos")
        }
    }

    static func isAntiCheat(_ executable: String) -> Bool {
        let lower = executable.lowercased()
        return antiCheatMarkers.contains { lower.contains($0) }
    }

    /// Windows launch options, excluding ones limited to beta branches
    static func windowsLaunches(_ app: VDF) -> [VDF] {
        let launches = app["config", "launch"]?.entries.map(\.1) ?? []
        return launches.filter {
            ($0["config", "oslist"]?.string ?? "windows").contains("windows")
                && ($0["config", "betakey"]?.string ?? "").isEmpty
                && $0["executable"]?.string != nil
        }
    }

    /// Picks the launch option to use and the issues that apply.
    static func analyze(_ app: VDF) -> (launch: VDF?, issues: [CompatibilityIssue]) {
        let launches = windowsLaunches(app)
        let preferred = launches.first { $0["type"]?.string == "default" } ?? launches.first
        var issues: [CompatibilityIssue] = []
        var launch = preferred

        if let exe = preferred?["executable"]?.string, isAntiCheat(exe) {
            // e.g. ARK lists ShooterGame.exe next to ShooterGame_BE.exe
            if let plain = launches.first(where: { !isAntiCheat($0["executable"]?.string ?? "") }) {
                launch = plain
                issues.append(.antiCheatOffline)
            } else {
                issues.append(.antiCheat)
            }
        }

        let tests = app["common", "steam_deck_compatibility", "tests"]?.entries.compactMap { $0.1["token"]?.string } ?? []
        if tests.contains(where: { $0.hasSuffix("UnsupportedAntiCheatConfiguration") }) && !issues.contains(.antiCheat) {
            issues.removeAll { $0 == .antiCheatOffline }
            issues.append(.antiCheat)
        }
        let exe = launch?["executable"]?.string?.lowercased() ?? ""
        if tests.contains(where: { $0.hasSuffix("LauncherInteractionIssues") }) || exe.contains("://") {
            issues.append(.thirdPartyLauncher)
        }
        if tests.contains(where: { $0.hasSuffix("SingleplayerGameplayRequiresActiveInternetConnection") }) {
            issues.append(.needsInternet)
        }
        return (launch, issues)
    }

    /// Save folders that Auto-Cloud syncs on both Windows and macOS. Empty if
    /// Steam says cross-platform cloud saves are not supported.
    static func cloudSaves(_ app: VDF) -> [CloudSaveLocation] {
        let tests = app["common", "steam_deck_compatibility", "tests"]?.entries.compactMap { $0.1["token"]?.string } ?? []
        if tests.contains(where: { $0.hasSuffix("CrossPlatformCloudSavesNotSupported") }) { return [] }

        let overrides = app["ufs", "rootoverrides"]?.entries.map(\.1) ?? []
        func resolve(_ root: String, _ path: String, os: String) -> (String, String)? {
            resolveRoot(overrides, root, path, os: os)
        }

        var locations: [CloudSaveLocation] = []
        for (_, file) in app["ufs", "savefiles"]?.entries ?? [] {
            guard let root = file["root"]?.string else { continue }
            let path = file["path"]?.string ?? ""
            guard let (winRoot, winPath) = resolve(root, path, os: "Windows"),
                  let (macRoot, macPath) = resolve(root, path, os: "MacOS"),
                  winRoot.hasPrefix("Win"), macRoot.hasPrefix("Mac") else { continue }
            func clean(_ path: String) -> String {
                path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let location = CloudSaveLocation(windowsRoot: winRoot, windowsPath: clean(winPath),
                                             macRoot: macRoot, macPath: clean(macPath))
            if !locations.contains(location) { locations.append(location) }
        }
        return locations
    }

    /// A root and path after the app's root override for an OS, if any.
    private static func resolveRoot(_ overrides: [VDF], _ root: String, _ path: String, os: String) -> (String, String)? {
        guard let rule = overrides.first(where: {
            $0["root"]?.string?.caseInsensitiveCompare(root) == .orderedSame
                && $0["os"]?.string?.caseInsensitiveCompare(os) == .orderedSame
        }) else { return (root, path) }
        var resolved = path
        for (_, transform) in rule["pathtransforms"]?.entries ?? [] {
            if let find = transform["find"]?.string, let replace = transform["replace"]?.string {
                resolved = resolved.replacingOccurrences(of: find, with: replace)
            }
        }
        if let prefix = rule["addpath"]?.string, !prefix.isEmpty {
            resolved = (prefix as NSString).appendingPathComponent(resolved)
        }
        return (rule["useinstead"]?.string ?? root, resolved)
    }

    /// The Auto-Cloud rules that apply to the Windows version.
    static func cloudRules(_ app: VDF) -> [CloudRule] {
        let overrides = app["ufs", "rootoverrides"]?.entries.map(\.1) ?? []
        func clean(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        var rules: [CloudRule] = []
        for (_, file) in app["ufs", "savefiles"]?.entries ?? [] {
            guard let root = file["root"]?.string else { continue }
            var platforms: UInt32 = 0
            for (_, platform) in file["platforms"]?.entries ?? [] {
                switch platform.string?.lowercased() {
                case "windows": platforms |= 1
                case "macos": platforms |= 2
                case "linux": platforms |= 8
                case "all": platforms = 0xFFFF_FFFF
                default: break
                }
            }
            if platforms == 0 { platforms = 0xFFFF_FFFF }
            guard platforms & 1 != 0 else { continue }
            let path = clean(file["path"]?.string ?? "")
            guard let (localRoot, localPath) = resolveRoot(overrides, root, path, os: "Windows"),
                  localRoot.hasPrefix("Win") || localRoot.caseInsensitiveCompare("GameInstall") == .orderedSame else { continue }
            let rule = CloudRule(root: root, path: path, localRoot: localRoot, localPath: clean(localPath),
                                 pattern: file["pattern"]?.string ?? "*",
                                 recursive: file["recursive"]?.string == "1", platforms: platforms)
            if !rules.contains(rule) { rules.append(rule) }
        }
        return rules
    }
}
