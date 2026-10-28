import Foundation

/// Finds updates for installed Windows games by comparing the build in
/// steamcmd's app manifest with the public build in Steam's app info. The
/// app info comes from an anonymous steamcmd login, which leaves the Steam
/// client's session alone.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: Set<Int> = []
    @Published private(set) var checking = false
    private var lastCheck: Date?

    static let interval: TimeInterval = 4 * 3600

    static var autoUpdate: Bool { UserDefaults.standard.bool(forKey: "autoUpdate") }

    /// Checks when the last check is older than the interval and steamcmd is free.
    func checkIfDue(library: Library, steamcmdBusy: Bool) {
        guard !checking, !steamcmdBusy, Paths.steamcmd != nil else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        check(library: library)
    }

    func check(library: Library) {
        let games = library.games.filter { $0.isInstalled && !$0.launchesViaURL }
        lastCheck = Date()
        guard !games.isEmpty else { return }
        checking = true

        Task {
            var found = Set<Int>()
            if let console = try? SteamConsole() {
                do {
                    try await console.login("anonymous")
                    for game in games {
                        guard let text = try await console.block("app_info_print \(game.appID)", marker: "AppID : \(game.appID)"),
                              let info = SteamCMD.parseAppInfo(text + "\n", appID: game.appID) else { continue }
                        if let latest = info.buildID, let installed = game.installedBuildID, latest != installed {
                            found.insert(game.appID)
                        }
                        // Also keeps the Steam Cloud flag current for the notice before starting
                        if var current = library.games.first(where: { $0.appID == game.appID }),
                           current.steamCloud != info.steamCloud {
                            current.steamCloud = info.steamCloud
                            library.upsert(current)
                        }
                    }
                } catch {
                    // Leave the previous result; the next check retries
                    found = available
                }
                await console.quit()
            }
            available = found
            checking = false
        }
    }

    /// Called when an update or a check of the game's files has finished.
    func markUpdated(_ appID: Int) {
        available.remove(appID)
    }
}

/// Looks for a newer MacProton release on GitHub. Without a token this only
/// works while the repository is public; failures are silent.
@MainActor
final class AppUpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let url: URL
    }

    @Published private(set) var newRelease: Release?
    private var lastCheck: Date?

    static let releasesURL = URL(string: "https://api.github.com/repos/W1nkelnet/MacProton/releases/latest")!

    func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3600 { return }
        lastCheck = Date()
        Task {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if Self.isNewer(version, than: current) {
                newRelease = Release(version: version, url: page)
            }
        }
    }

    /// Compares dotted version numbers, e.g. 0.1.0.2 > 0.1.0.1
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
