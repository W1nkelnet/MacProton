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
}

enum SteamCMDError: LocalizedError {
    case notInstalled
    case loginRequired(String)
    case noWindowsVersion
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "steamcmd ist nicht installiert. Installiere es mit: brew install --cask steamcmd"
        case .loginRequired(let account):
            return "steamcmd ist für \(account) nicht angemeldet. Melde dich einmal im Terminal an."
        case .noWindowsVersion:
            return "Für dieses Spiel gibt es keine Windows-Version."
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
        throw SteamCMDError.failed("Keine App-Informationen für \(appID) erhalten.")
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
                       cloudSaves: AppAnalysis.cloudSaves(app))
    }

    /// Downloads or updates the Windows version of an app.
    static func install(appID: Int, into dir: String, account: String,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard let steamcmd = Paths.steamcmd else { throw SteamCMDError.notInstalled }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Through script(1) so steamcmd sees a terminal and prints progress live
        let args = ["-q", "/dev/null", steamcmd,
                    "+@sSteamCmdForcePlatformType", "windows", "+force_install_dir", dir,
                    "+login", account, "+app_update", String(appID), "validate", "+quit"]
        let output = try await run("/usr/bin/script", args) { line in
            if let value = parseProgress(line) { progress(value, line) }
            try checkLogin(line, account: account)
        }
        if output.contains("Success! App '\(appID)'") { return }
        if output.contains("No subscription") {
            throw SteamCMDError.failed("Das Spiel ist nicht in der Bibliothek von \(account).")
        }
        if output.contains("Invalid Password") || output.contains("Login Failure") {
            throw SteamCMDError.loginRequired(account)
        }
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        throw SteamCMDError.failed("Download fehlgeschlagen: \(last)")
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
    static func run(_ executable: String, _ arguments: [String],
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
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
                if let text = String(data: rest, encoding: .utf8) { _ = state.append(text + "\n") }
                if let error = state.error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state.output) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Collects process output and splits it into lines (on \n and \r).
private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var output = ""
    private(set) var error: Error?

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
