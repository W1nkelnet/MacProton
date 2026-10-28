import Foundation

/// An interactive steamcmd session. steamcmd loads app and package info
/// asynchronously and does not wait for it when many commands are passed on
/// the command line, so commands are sent one at a time and each waits for
/// its answer.
final class SteamConsole: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = ""
    private var loginMissing = false

    init() throws {
        guard let steamcmd = Paths.steamcmd else { throw SteamCMDError.notInstalled }
        process.executableURL = URL(fileURLWithPath: steamcmd)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Paths.steamcmdHome.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }
        try process.run()
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        stop()
    }

    /// Logs in with the cached credentials of `account`; steamcmd is stopped
    /// before it would prompt for a password.
    func login(_ account: String) async throws {
        guard try await wait(timeout: 180, account: account, until: { $0.contains("Steam>") }) else {
            throw SteamCMDError.failed("steamcmd antwortet nicht.")
        }
        send("login \(account)")
        guard try await wait(timeout: 90, account: account, until: { $0.contains("Waiting for user info...OK") }) else {
            throw SteamCMDError.failed("Anmeldung bei Steam fehlgeschlagen.")
        }
    }

    /// Sends a command whose answer is a header line starting with `marker`
    /// followed by a KeyValues block, and returns header and block, or nil if
    /// no complete answer arrives in time.
    func block(_ command: String, marker: String, timeout: TimeInterval = 10) async throws -> String? {
        clear()
        send(command)
        var result: String?
        _ = try await wait(timeout: timeout, account: "") { text in
            guard let start = text.range(of: marker),
                  let end = Self.endOfBlock(in: text, from: start.upperBound) else { return false }
            result = String(text[start.lowerBound..<end])
            return true
        }
        return result
    }

    /// Asks steamcmd to quit and waits for it, then stops what is left.
    func quit() async {
        send("quit")
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
    }

    /// steamcmd.sh runs steamcmd as a child and waits for it before handling
    /// a signal, so signal the whole process group it leads.
    private func stop() {
        if process.isRunning { kill(-process.processIdentifier, SIGTERM) }
    }

    /// Index after the closing brace of the first balanced { } block.
    static func endOfBlock(in text: String, from index: String.Index) -> String.Index? {
        var depth = 0
        var inQuotes = false
        var i = index
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" { inQuotes.toggle() }
            else if !inQuotes && c == "{" { depth += 1 }
            else if !inQuotes && c == "}" {
                depth -= 1
                if depth == 0 { return text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private func send(_ command: String) {
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
    }

    private func clear() {
        lock.lock(); buffer = ""; lock.unlock()
    }

    private func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        if text.contains("Cached credentials not found") || text.lowercased().contains("password:") {
            loginMissing = true
            process.terminate()
        }
    }

    private func snapshot() -> (String, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (buffer, loginMissing)
    }

    /// Polls the output until `condition` holds; false on timeout.
    private func wait(timeout: TimeInterval, account: String,
                      until condition: (String) -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (text, missing) = snapshot()
            if missing { throw SteamCMDError.loginRequired(account) }
            if condition(text) { return true }
            if !process.isRunning { throw SteamCMDError.failed("steamcmd wurde unerwartet beendet.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
