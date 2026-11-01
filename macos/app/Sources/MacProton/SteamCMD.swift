import Darwin
import Foundation

struct AppInfo {
    var appID: Int
    var name: String
    /// Windows launch entry, relative to the install dir with "/" separators
    var executable: String
    var arguments: String
    var sizeBytes: Int64
    var hasNativeMac = false
    var issues: [CompatibilityIssue] = []
    var cloudSaves: [CloudSaveLocation] = []
    var cloudRules: [CloudRule] = []
    /// The game keeps saves in Steam Cloud
    var steamCloud = false
    /// Build of the public branch
    var buildID: String?
}

enum SteamCMDError: LocalizedError {
    case notInstalled
    case loginRequired(String)
    case noWindowsVersion
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "steamcmd ist noch nicht eingerichtet. MacProton lädt es beim Start von Valve; prüfe die Internetverbindung.")
        case .loginRequired(let account):
            return String(localized: "steamcmd ist für \(account) nicht angemeldet.")
        case .noWindowsVersion:
            return String(localized: "Für dieses Spiel gibt es keine Windows-Version.")
        case .failed(let message):
            return message
        }
    }
}

/// Runs Valve's steamcmd. Credentials are never handled here: steamcmd uses
/// the login cached by a previous interactive "steamcmd +login NAME".
enum SteamCMD {
    static func appInfo(_ appID: Int) async throws -> AppInfo {
        guard let steamcmd = Paths.steamcmd else { throw SteamCMDError.notInstalled }
        let args = ["+login", "anonymous", "+app_info_update", "1", "+app_info_print", String(appID), "+quit"]

        // steamcmd sometimes exits right after updating itself; retry once
        for _ in 0..<2 {
            let output = try await run(steamcmd, args) { _ in }
            if let info = parseAppInfo(output, appID: appID) { return info }
        }
        throw SteamCMDError.failed(String(localized: "Keine App-Informationen für \(appID) erhalten."))
    }

    static func parseAppInfo(_ output: String, appID: Int) -> AppInfo? {
        guard let start = output.range(of: "\"\(appID)\"\n") ?? output.range(of: "\"\(appID)\"\r\n") else { return nil }
        let root = VDF.parse(String(output[start.lowerBound...]))
        guard let app = root[String(appID)], let name = app["common", "name"]?.string else { return nil }

        let (entry, issues) = AppAnalysis.analyze(app)
        guard let exe = entry?["executable"]?.string else {
            return AppInfo(appID: appID, name: name, executable: "", arguments: "", sizeBytes: 0)
        }

        var size: Int64 = 0
        for (_, depot) in app["depots"]?.entries ?? [] {
            // DLC and other-language depots are not part of the base download
            let oslist = depot["config", "oslist"]?.string ?? "windows"
            let language = depot["config", "language"]?.string ?? ""
            guard oslist.contains("windows"), depot["dlcappid"] == nil, language.isEmpty || language == "english",
                  let value = depot["manifests", "public", "size"]?.string else { continue }
            size += Int64(value) ?? 0
        }

        return AppInfo(appID: appID, name: name,
                       executable: exe.replacingOccurrences(of: "\\", with: "/"),
                       arguments: entry?["arguments"]?.string ?? "",
                       sizeBytes: size,
                       hasNativeMac: app["common", "oslist"]?.string?.contains("macos") ?? false,
                       issues: issues,
                       cloudSaves: AppAnalysis.cloudSaves(app),
                       cloudRules: AppAnalysis.cloudRules(app),
                       steamCloud: (Int64(app["ufs", "quota"]?.string ?? "") ?? 0) > 0,
                       buildID: app["depots", "branches", "public", "buildid"]?.string)
    }

    /// What steamcmd reports while it updates an app
    struct UpdateState: Sendable {
        var phase: String
        var progress: Double
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var verifying = false
        var downloading = false
    }

    /// "Update state (0x61) downloading, progress: 38.63 (1428051780 / 3696370087)"
    static func parseUpdateState(_ line: String) -> UpdateState? {
        guard line.contains("Update state"), let value = parseProgress(line),
              let close = line.firstIndex(of: ")"), let comma = line[close...].firstIndex(of: ",") else { return nil }
        let name = line[line.index(after: close)..<comma].trimmingCharacters(in: .whitespaces)
        var state = UpdateState(phase: String(localized: "Arbeite"), progress: value)
        if name.contains("verifying") { state.phase = String(localized: "Prüfe vorhandene Dateien"); state.verifying = true }
        else if name.contains("downloading") { state.phase = String(localized: "Lade herunter"); state.downloading = true }
        else if name.contains("preallocating") { state.phase = String(localized: "Reserviere Speicherplatz") }
        else if name.contains("committing") { state.phase = String(localized: "Übernehme Dateien") }
        else if name.contains("reconfiguring") { state.phase = String(localized: "Bereite vor") }
        if let open = line.lastIndex(of: "("), let end = line.lastIndex(of: ")"), open < end {
            let numbers = line[line.index(after: open)..<end].split(separator: "/").compactMap {
                Int64($0.trimmingCharacters(in: .whitespaces))
            }
            if numbers.count == 2 { state.bytesDone = numbers[0]; state.bytesTotal = numbers[1] }
        }
        return state
    }

    /// A running steamcmd, so that a download can be stopped
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var stopped = false

        var wasStopped: Bool { lock.withLock { stopped } }

        func started(_ pid: pid_t) {
            let stop = lock.withLock { self.pid = pid; return stopped }
            if stop { Self.terminate(pid) }
        }

        func stop() {
            let pid = lock.withLock { stopped = true; return self.pid }
            if pid > 0 { Self.terminate(pid) }
        }

        /// script(1) starts steamcmd in a session of its own, which a signal
        /// to script's process group would not reach; stop the whole tree.
        private static func terminate(_ pid: pid_t) {
            var children = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(Int(max(count, 0))) where child > 0 { terminate(child) }
            kill(pid, SIGTERM)
        }
    }

    /// Downloads or updates the Windows version of an app. steamcmd checks
    /// the files already there first and only loads what is missing.
    static func install(appID: Int, into dir: String, account: String, handle: Handle? = nil,
                        progress: @escaping @Sendable (UpdateState) -> Void) async throws {
        guard let steamcmd = Paths.steamcmd else { throw SteamCMDError.notInstalled }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Through script(1) so steamcmd sees a terminal and prints progress live
        let args = ["-q", "/dev/null", steamcmd,
                    "+@sSteamCmdForcePlatformType", "windows", "+force_install_dir", dir,
                    "+login", account, "+app_update", String(appID), "validate", "+quit"]
        let output = try await run("/usr/bin/script", args, handle: handle) { line in
            if let state = parseUpdateState(line) { progress(state) }
            else if line.hasPrefix("Logging in user") { progress(UpdateState(phase: String(localized: "Melde bei Steam an …"), progress: 0)) }
            try checkLogin(line, account: account)
        }
        if output.contains("Success! App '\(appID)'") { return }
        if output.contains("No subscription") {
            throw SteamCMDError.failed(String(localized: "Das Spiel ist nicht in der Bibliothek von \(account)."))
        }
        if output.contains("Invalid Password") || output.contains("Login Failure") {
            throw SteamCMDError.loginRequired(account)
        }
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        throw SteamCMDError.failed(String(localized: "Download fehlgeschlagen: \(last)"))
    }

    /// steamcmd prints "Cached credentials not found." before prompting for a
    /// password; stop there, so it never attempts a login with an empty one.
    static func checkLogin(_ line: String, account: String) throws {
        let lower = line.lowercased()
        if lower.contains("cached credentials not found") || lower.contains("password:")
            || lower.contains("steam guard") || lower.contains("two-factor") {
            throw SteamCMDError.loginRequired(account)
        }
    }

    /// "Update state (0x61) downloading, progress: 38.63 (1428051780 / 3696370087)"
    static func parseProgress(_ line: String) -> Double? {
        // The final "Update state (0x0) unknown, progress: 0.00 (0 / 0)" is no progress
        guard let range = line.range(of: "progress: "), !line.contains("(0 / 0)") else { return nil }
        let number = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(number).map { $0 / 100 }
    }

    /// Runs a process, calling onLine for each output line. Throwing from
    /// onLine terminates the process and rethrows.
    static func run(_ executable: String, _ arguments: [String], handle: Handle? = nil,
                    onLine: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Paths.steamcmdHome.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let state = OutputState()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = state.decode(data) else { return }
            for line in state.append(text) {
                do { try onLine(line) } catch {
                    state.fail(error)
                    process.terminate()
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                _ = state.append((state.decode(rest, final: true) ?? "") + "\n")
                if let error = state.error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state.output) }
            }
            do {
                try process.run()
                handle?.started(process.processIdentifier)
            } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Collects process output and splits it into lines (on \n and \r).
private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var output = ""
    private(set) var error: Error?
    private var pending = Data()

    /// Text of the bytes so far; a character split across reads waits for
    /// its remaining bytes.
    func decode(_ data: Data, final: Bool = false) -> String? {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        for cut in stride(from: pending.count, through: max(pending.count - 3, 1), by: -1) {
            if let text = String(data: pending.prefix(cut), encoding: .utf8) {
                pending.removeFirst(cut)
                return text
            }
        }
        // Not UTF-8 at all, or the end
        guard final || pending.count > 3 else { return nil }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }

    func append(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        output += text
        buffer += text
        var lines: [String] = []
        // isNewline also matches "\r\n", which Swift treats as one Character
        while let index = buffer.firstIndex(where: \.isNewline) {
            let line = String(buffer[..<index]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...index)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if self.error == nil { self.error = error }
    }
}
