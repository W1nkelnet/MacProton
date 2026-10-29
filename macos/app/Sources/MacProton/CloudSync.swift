import Darwin
import Foundation

/// Syncs the Steam Cloud saves of Windows games, which macOS Steam lists but
/// never downloads or uploads: before a game starts, MacProton takes what
/// changed in the cloud into the prefix, and after the game ends it uploads
/// what the game wrote, like the Steam client on Windows does.
///
/// It keeps the SHA-1 of every file as last synced, so it can tell which
/// side changed. A file changed on both sides is a conflict, which the user
/// decides. Files MacProton would overwrite or delete on this Mac are backed
/// up first. Games with a macOS version are left to the Steam client, as are
/// files a game saves through Steam's cloud API (no root in the path).
enum CloudSync {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "cloudSync") as? Bool ?? true }

    static func applies(to game: Game) -> Bool {
        enabled && game.steamCloud == true && !game.runsNatively && SteamSession.load() != nil
    }

    static var machineName: String { "MacProton (\(Host.current().localizedName ?? "Mac"))" }

    // MARK: State

    struct SyncedFile: Codable {
        var path: String
        var sha: String
    }

    /// What the last sync left behind, by lowercased cloud path
    struct State: Codable {
        var files: [String: SyncedFile] = [:]
        /// Rules fetched for games the library has none for yet
        var rules: [CloudRule]?
    }

    static let stateDir = Paths.support.appendingPathComponent("cloud-sync", isDirectory: true)

    static func loadState(_ appID: Int) -> State {
        guard let data = try? Data(contentsOf: stateDir.appendingPathComponent("\(appID).json")) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    static func saveState(_ state: State, appID: Int) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateDir.appendingPathComponent("\(appID).json"), options: .atomic)
    }

    // MARK: Paths

    struct Context {
        let game: Game
        let prefix: URL
        let session: SteamSession
        let rules: [CloudRule]
    }

    /// Fills in the account placeholders of a rule path.
    static func substitute(_ path: String, _ ctx: Context) -> String {
        path.replacingOccurrences(of: "{64BitSteamID}", with: ctx.session.steamID, options: .caseInsensitive)
            .replacingOccurrences(of: "{Steam3AccountID}", with: String(ctx.session.accountID), options: .caseInsensitive)
    }

    static func base(_ root: String, _ ctx: Context) -> URL? {
        switch root.lowercased() {
        case "gameinstall": return URL(fileURLWithPath: ctx.game.installDir, isDirectory: true)
        case "winprogramdata": return ctx.prefix.appendingPathComponent("drive_c/ProgramData", isDirectory: true)
        default: return SaveSync.windowsBase(root, prefix: ctx.prefix)
        }
    }

    /// A relative path below a folder, or nil if it could leave the folder
    static func append(_ base: URL, _ relative: String) -> URL? {
        let parts = relative.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(base) { $0.appendingPathComponent($1) }
    }

    /// Where a cloud file such as "%WinAppDataLocalLow%Redbeet Interactive/…"
    /// lives in the prefix, or nil for files MacProton leaves to Steam.
    static func localURL(of cloudPath: String, _ ctx: Context) -> URL? {
        guard cloudPath.hasPrefix("%"), let close = cloudPath.dropFirst().firstIndex(of: "%") else { return nil }
        let root = String(cloudPath[cloudPath.index(after: cloudPath.startIndex)..<close])
        let rest = String(cloudPath[cloudPath.index(after: close)...]).replacingOccurrences(of: "\\", with: "/")

        // Rules whose files Windows keeps elsewhere than the cloud names
        for rule in ctx.rules where rule.root.caseInsensitiveCompare(root) == .orderedSame
            && (rule.localRoot.caseInsensitiveCompare(rule.root) != .orderedSame || rule.localPath != rule.path) {
            let cloudDir = substitute(rule.path, ctx)
            guard cloudDir.isEmpty || rest.lowercased().hasPrefix(cloudDir.lowercased() + "/") else { continue }
            let remainder = cloudDir.isEmpty ? rest : String(rest.dropFirst(cloudDir.count + 1))
            let localDir = substitute(rule.localPath, ctx)
            guard let base = base(rule.localRoot, ctx) else { return nil }
            return append(base, localDir.isEmpty ? remainder : localDir + "/" + remainder)
        }
        guard let base = base(root, ctx) else { return nil }
        return append(base, rest)
    }

    struct LocalFile {
        var path: String
        var url: URL
        var platforms: UInt32
    }

    /// The files in the prefix that the rules put in the cloud, by
    /// lowercased cloud path.
    static func localFiles(_ ctx: Context) -> [String: LocalFile] {
        var result: [String: LocalFile] = [:]
        let fm = FileManager.default
        for rule in ctx.rules {
            guard let base = base(rule.localRoot, ctx) else { continue }
            let localDir = substitute(rule.localPath, ctx)
            guard let dir = localDir.isEmpty ? base : append(base, localDir) else { continue }
            let real = dir.resolvingSymlinksInPath()
            guard let files = fm.enumerator(at: real, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: rule.recursive ? [] : [.skipsSubdirectoryDescendants]) else { continue }
            let cloudDir = substitute(rule.path, ctx)
            for case let file as URL in files {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      file.lastPathComponent != ".DS_Store" else { continue }
                let relative = String(file.resolvingSymlinksInPath().path.dropFirst(real.path.count + 1))
                let subject = rule.pattern.contains("/") ? relative : file.lastPathComponent
                guard fnmatch(rule.pattern, subject, FNM_CASEFOLD) == 0 else { continue }
                let path = "%\(rule.root)%" + (cloudDir.isEmpty ? "" : cloudDir + "/") + relative
                result[path.lowercased()] = LocalFile(path: path, url: dir.appendingPathComponent(relative),
                                                      platforms: rule.platforms)
            }
        }
        return result
    }

    static func sha1(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map(SteamCloudService.sha1)
    }

    // MARK: Plan

    enum Resolution { case cloud, mac }

    struct Conflict {
        var path: String
        var local: URL
        var cloud: CloudFile
    }

    /// What a sync would do; apply() carries it out on the same connection.
    struct Plan {
        var ctx: Context
        var connection: SteamConnection
        var state: State
        var downloads: [(file: CloudFile, local: URL)] = []
        var uploads: [LocalFile] = []
        var cloudDeletes: [String] = []
        var localDeletes: [(path: String, local: URL)] = []
        var conflicts: [Conflict] = []
        var beforeStart: Bool

        var isEmpty: Bool {
            downloads.isEmpty && uploads.isEmpty && cloudDeletes.isEmpty && localDeletes.isEmpty && conflicts.isEmpty
        }
    }

    /// Compares the cloud with the prefix. Before a start it plans what to
    /// download, after the game ends what to upload; files the other side
    /// changed wait for the other step. A file missing after the game is
    /// deleted in the cloud only with allowCloudDeletes, which the caller
    /// sets when the sync before the start brought every file into the
    /// prefix; otherwise a missing file may just never have been downloaded.
    static func prepare(_ game: Game, prefix: URL, beforeStart: Bool, allowCloudDeletes: Bool = false) async throws -> Plan {
        guard let session = SteamSession.load() else {
            throw SteamConnection.Failure(description: "MacProton ist nicht bei Steam angemeldet.")
        }
        var state = loadState(game.appID)
        var rules = game.cloudRules ?? state.rules
        if rules == nil, let fetched = try? await SteamCMD.appInfo(game.appID).cloudRules {
            rules = fetched
            state.rules = fetched
        }
        let ctx = Context(game: game, prefix: prefix, session: session, rules: rules ?? [])
        let connection = try await SteamConnection.open(session)
        let listing: [CloudFile]
        do {
            listing = try await SteamCloudService.files(connection, appID: game.appID).files
        } catch {
            connection.disconnect()
            throw error
        }

        var plan = Plan(ctx: ctx, connection: connection, state: state, beforeStart: beforeStart)
        var cloud: [String: CloudFile] = [:]
        var deletedInCloud: Set<String> = []
        for file in listing where file.isForWindows && localURL(of: file.path, ctx) != nil {
            if file.isPersisted { cloud[file.path.lowercased()] = file } else { deletedInCloud.insert(file.path.lowercased()) }
        }
        let local = localFiles(ctx)
        // Without rules, MacProton knows only the files the cloud or the last sync named
        let canTellDeletes = allowCloudDeletes && !ctx.rules.isEmpty

        let keys = Set(cloud.keys).union(local.keys).union(state.files.keys)
        for key in keys {
            let cloudFile = cloud[key]
            let path = cloudFile?.path ?? local[key]?.path ?? state.files[key]?.path ?? key
            guard let url = local[key]?.url ?? localURL(of: path, ctx) else { continue }
            let localSHA = FileManager.default.fileExists(atPath: url.path) ? sha1(of: url) : nil
            let known = state.files[key]?.sha

            if let localSHA, localSHA == cloudFile?.sha {
                plan.state.files[key] = SyncedFile(path: path, sha: localSHA)
                continue
            }
            if localSHA == nil && cloudFile == nil {
                plan.state.files[key] = nil
                continue
            }
            if beforeStart {
                if let cloudFile {
                    if localSHA == nil || known == localSHA {
                        plan.downloads.append((cloudFile, url))
                    } else if known != cloudFile.sha {
                        plan.conflicts.append(Conflict(path: path, local: url, cloud: cloudFile))
                    }
                } else if localSHA != nil, deletedInCloud.contains(key), known == localSHA {
                    plan.localDeletes.append((path, url))
                }
            } else {
                if let localSHA {
                    let platforms = local[key]?.platforms ?? cloudFile?.platforms ?? 1
                    if let cloudFile {
                        if known == cloudFile.sha {
                            plan.uploads.append(LocalFile(path: cloudFile.path, url: url, platforms: cloudFile.platforms))
                        } else if known != localSHA {
                            plan.conflicts.append(Conflict(path: path, local: url, cloud: cloudFile))
                        }
                    } else if !(deletedInCloud.contains(key) && known == localSHA) {
                        plan.uploads.append(LocalFile(path: path, url: url, platforms: platforms))
                    }
                } else if let cloudFile, known == cloudFile.sha, canTellDeletes,
                          !path.lowercased().hasPrefix("%gameinstall%") {
                    plan.cloudDeletes.append(cloudFile.path)
                }
            }
        }
        return plan
    }

    struct Summary {
        var downloaded = 0
        var uploaded = 0
        var deleted = 0
        /// Files of this Mac that were replaced or deleted, and cloud versions
        /// of conflicts this Mac's version won, all in the backup
        var backedUpFromMac = 0
        var backedUpFromCloud = 0
        var backup: URL?
    }

    /// Carries out a plan, conflicts as resolved (nil leaves them for the next
    /// sync), and closes the connection.
    static func apply(_ plan: Plan, resolving resolution: Resolution?) async throws -> Summary {
        var plan = plan
        defer { plan.connection.disconnect() }
        let fm = FileManager.default
        let appID = plan.ctx.game.appID
        var summary = Summary()

        switch resolution {
        case .cloud:
            plan.downloads += plan.conflicts.map { ($0.cloud, $0.local) }
        case .mac:
            for conflict in plan.conflicts {
                if plan.beforeStart {
                    // Counts as synced with the cloud's version, so the upload after the game takes this Mac's
                    plan.state.files[conflict.path.lowercased()] = SyncedFile(path: conflict.cloud.path, sha: conflict.cloud.sha)
                } else {
                    plan.uploads.append(LocalFile(path: conflict.cloud.path, url: conflict.local, platforms: conflict.cloud.platforms))
                }
            }
        case nil:
            break
        }

        // Back up every file on this Mac that gets replaced or deleted, and
        // the cloud's version of conflicts this Mac's version wins
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = SaveSync.backupsDir.appendingPathComponent("\(appID)/\(stamp)-cloud-sync", isDirectory: true)
        let replaced = plan.downloads.map(\.local).filter { fm.fileExists(atPath: $0.path) } + plan.localDeletes.map(\.local)
        let drive = plan.ctx.prefix.resolvingSymlinksInPath().path
        for file in replaced {
            let real = file.resolvingSymlinksInPath().path
            let relative = real.hasPrefix(drive + "/") ? String(real.dropFirst(drive.count + 1)) : file.lastPathComponent
            let target = backup.appendingPathComponent("mac").appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
            summary.backedUpFromMac += 1
            summary.backup = backup
        }
        if resolution == .mac {
            for conflict in plan.conflicts {
                let data = try await SteamCloudService.download(plan.connection, appID: appID, path: conflict.cloud.path)
                let name = conflict.cloud.path.replacingOccurrences(of: "%", with: "")
                guard let target = append(backup.appendingPathComponent("cloud", isDirectory: true), name) else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
                summary.backedUpFromCloud += 1
                summary.backup = backup
            }
        }

        // The addresses come one by one over the connection, the files in
        // parallel; what arrived counts as synced even if the rest does not
        do {
            var index = 0
            while index < plan.downloads.count {
                try Task.checkCancellation()
                let chunk = Array(plan.downloads[index..<min(index + 32, plan.downloads.count)])
                index += chunk.count
                var tickets: [SteamCloudService.DownloadTicket] = []
                for (file, _) in chunk {
                    tickets.append(try await SteamCloudService.ticket(plan.connection, appID: appID, path: file.path))
                }
                try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    var next = 0
                    func addNext() {
                        let i = next
                        next += 1
                        let ticket = tickets[i]
                        group.addTask { (i, try await SteamCloudService.fetch(ticket)) }
                    }
                    for _ in 0..<min(8, tickets.count) { addNext() }
                    while let (i, data) = try await group.next() {
                        let (file, local) = chunk[i]
                        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: local, options: .atomic)
                        try? fm.setAttributes([.modificationDate: file.timestamp], ofItemAtPath: local.path)
                        plan.state.files[file.path.lowercased()] = SyncedFile(path: file.path, sha: file.sha)
                        summary.downloaded += 1
                        if next < tickets.count { addNext() }
                    }
                }
                try saveState(plan.state, appID: appID)
            }
        } catch {
            try? saveState(plan.state, appID: appID)
            throw error
        }
        for (path, local) in plan.localDeletes {
            try? fm.removeItem(at: local)
            plan.state.files[path.lowercased()] = nil
            summary.deleted += 1
        }

        if !plan.uploads.isEmpty || !plan.cloudDeletes.isEmpty {
            var uploads: [SteamCloudService.Upload] = []
            var hashes: [String: String] = [:]
            for file in plan.uploads {
                let data = try Data(contentsOf: file.url)
                let date = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                uploads.append(.init(path: file.path, data: data, timestamp: date, platforms: file.platforms))
                hashes[file.path.lowercased()] = SteamCloudService.sha1(data)
            }
            try await SteamCloudService.commit(plan.connection, appID: appID, uploads: uploads,
                                               deletes: plan.cloudDeletes, machineName: machineName)
            for file in plan.uploads {
                plan.state.files[file.path.lowercased()] = SyncedFile(path: file.path, sha: hashes[file.path.lowercased()] ?? "")
            }
            for path in plan.cloudDeletes { plan.state.files[path.lowercased()] = nil }
            summary.uploaded = plan.uploads.count
            summary.deleted += plan.cloudDeletes.count
        }

        try saveState(plan.state, appID: appID)
        return summary
    }
}
