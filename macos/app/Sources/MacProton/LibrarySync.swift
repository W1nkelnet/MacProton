import Foundation

/// Finds the games of a Steam account with a Windows version:
/// licenses -> packages -> apps -> app info, keeping apps of type "game".
@MainActor
final class LibrarySync: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published var lastResult: String?
    @Published var loginRequired: String?
    @Published var lastError: String?

    func sync(library: Library, account: String) {
        guard !running else { return }
        guard !account.isEmpty else {
            loginRequired = ""  // opens the login window
            return
        }
        running = true
        progress = 0
        status = "Lese Lizenzen …"

        Task {
            defer { running = false }
            do {
                let found = try await fetchGames(account: account)
                var added = 0
                for info in found {
                    if var existing = library.games.first(where: { $0.appID == info.appID }) {
                        // keep the user's folder and play history, refresh what Steam says
                        existing.apply(info)
                        library.upsert(existing)
                    } else {
                        library.upsert(Game(info: info))
                        added += 1
                    }
                }
                lastResult = "\(found.count) Windows-Spiele gefunden, \(added) neu in der Bibliothek."
            } catch SteamCMDError.loginRequired {
                loginRequired = account
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func fetchGames(account: String) async throws -> [AppInfo] {
        guard let steamcmd = Paths.steamcmd else { throw SteamCMDError.notInstalled }

        // The license list is complete when run non-interactively
        let licenses = try await SteamCMD.run(steamcmd, ["+login", account, "+licenses_print", "+quit"]) { line in
            try SteamCMD.checkLogin(line, account: account)
        }
        let (apps, truncated) = Self.parseLicenses(licenses)

        let console = try SteamConsole()
        do {
            let games = try await fetchGames(console: console, account: account, apps: apps, truncated: truncated)
            await console.quit()
            return games
        } catch {
            await console.quit()
            throw error
        }
    }

    private func fetchGames(console: SteamConsole, account: String,
                            apps: Set<Int>, truncated: [Int]) async throws -> [AppInfo] {
        var apps = apps
        try await console.login(account)

        // Packages with many apps are abbreviated in the license list
        for package in truncated {
            status = "Lese Paket \(package) …"
            if let text = try await console.block("package_info_print \(package)", marker: "PackageID : \(package)") {
                apps.formUnion(Self.packageApps(text))
            }
        }

        var games: [AppInfo] = []
        let sorted = apps.sorted()
        for (index, appID) in sorted.enumerated() {
            progress = Double(index) / Double(max(sorted.count, 1))
            status = "Prüfe Apps … \(index + 1)/\(sorted.count)"
            guard let text = try await console.block("app_info_print \(appID)", marker: "AppID : \(appID)") else { continue }
            let root = VDF.parse(String(text[(text.firstIndex(of: "\n") ?? text.startIndex)...]))
            guard root[String(appID), "common", "type"]?.string?.lowercased() == "game",
                  let info = SteamCMD.parseAppInfo(text + "\n", appID: appID),
                  !info.executable.isEmpty else { continue }
            games.append(info)
        }
        progress = 1
        return games
    }

    /// App ids of all active licenses except package 0 (Steam's own tools and
    /// servers), and the packages whose app list was abbreviated.
    nonisolated static func parseLicenses(_ text: String) -> (Set<Int>, [Int]) {
        var apps = Set<Int>()
        var truncated: [Int] = []
        for block in text.components(separatedBy: "License packageID ").dropFirst() {
            guard let package = Int(block.prefix { $0.isNumber }), package != 0,
                  block.contains("State   : Active") || block.contains("State : Active"),
                  let line = block.split(separator: "\n").first(where: { $0.contains(" - Apps") }) else { continue }
            let list = line.split(separator: ":", maxSplits: 1).last.map { $0.split(separator: "(").first ?? $0 } ?? ""
            apps.formUnion(list.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
            if line.contains("...") { truncated.append(package) }
        }
        return (apps, truncated)
    }

    nonisolated static func packageApps(_ text: String) -> [Int] {
        guard let body = text.firstIndex(of: "\n") else { return [] }
        let root = VDF.parse(String(text[body...]))
        let package = root.entries.first?.1
        return package?["appids"]?.entries.compactMap { $0.1.string.flatMap(Int.init) } ?? []
    }
}
