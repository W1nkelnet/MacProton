import Foundation

/// Sets up Valve's steamcmd in Application Support on first launch, so no
/// Homebrew is needed. steamcmd updates itself there on its first start.
@MainActor
final class SteamCMDSetup: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var error: String?
    /// Overall progress of the setup, 0 to 1
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""

    /// Valve's download, the same Homebrew uses
    nonisolated static let url = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
    /// Valve's Developer ID team, which signs steamcmd
    nonisolated static let requirement = #"anchor apple generic and certificate leaf[subject.OU] = "MXGJJ98X76""#

    var isComplete: Bool { Paths.steamcmd != nil && Paths.steamRedistAvailable }

    func setUpIfNeeded() {
        guard !isComplete, !running else { return }
        running = true
        error = nil
        progress = 0
        let report: @Sendable (Double, String) -> Void = { value, text in
            Task { @MainActor in
                self.progress = max(self.progress, value)
                self.status = text
            }
        }
        Task {
            do {
                if Paths.steamcmd == nil { try await Self.install(into: Paths.steamcmdDir, report: report) }
                if !Paths.steamRedistAvailable { try await Self.downloadRedist(report: report) }
                progress = 1
                status = "Fertig"
            } catch {
                self.error = "steamcmd konnte nicht eingerichtet werden: \(error.localizedDescription)"
            }
            running = false
        }
    }

    /// Downloads the Steamworks SDK Redist (app 1007) for Windows; anonymous,
    /// so it does not take over the Steam client's session.
    nonisolated static func downloadRedist(report: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws {
        guard let steamcmd = Paths.steamcmd else { throw SteamCMDError.notInstalled }
        report(0.75, "Lade Valves Steam-Komponenten für Windows …")
        let output = try await runLive(steamcmd, ["+@sSteamCmdForcePlatformType", "windows",
                                                  "+force_install_dir", Paths.steamRedistDir.path,
                                                  "+login", "anonymous", "+app_update", "1007", "validate", "+quit"]) { line in
            if let value = SteamCMD.parseProgress(line) {
                report(0.75 + 0.25 * value, "Lade Valves Steam-Komponenten für Windows …")
            }
        }
        guard output.contains("Success! App '1007'") else {
            throw SteamCMDError.failed("Valves Steamworks-Redist konnte nicht geladen werden.")
        }
    }

    nonisolated static func install(into dir: URL, report: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws {
        report(0, "Lade steamcmd von Valve …")
        let file = try await download(url) { report(0.2 * $0, "Lade steamcmd von Valve …") }
        defer { try? FileManager.default.removeItem(at: file) }

        report(0.2, "Prüfe Valves Signatur …")
        let staging = dir.deletingLastPathComponent().appendingPathComponent("steamcmd.partial", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard run("/usr/bin/tar", ["-xzf", file.path, "-C", staging.path]) else {
            throw SteamCMDError.failed("Das steamcmd-Archiv ist beschädigt.")
        }
        for binary in ["steamcmd", "crashhandler.dylib"] {
            let path = staging.appendingPathComponent(binary).path
            guard run("/usr/bin/codesign", ["--verify", "--strict", "-R=" + requirement, path]) else {
                throw SteamCMDError.failed("\(binary) ist nicht von Valve signiert.")
            }
        }

        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: staging, to: dir)

        // The first start updates steamcmd, and the old version sometimes
        // crashes right after; get that done here rather than during a login
        let steamcmd = dir.appendingPathComponent("steamcmd.sh").path
        report(0.25, "steamcmd aktualisiert sich …")
        for _ in 0..<3 {
            let output = (try? await runLive(steamcmd, ["+quit"]) { line in
                // "[ 45%] Downloading update (7,077 of 15,797 KB)..."
                if line.hasPrefix("["), let close = line.firstIndex(of: "%"),
                   let value = Double(line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)) {
                    report(0.25 + 0.5 * value / 100, "steamcmd aktualisiert sich …")
                }
            }) ?? ""
            if output.contains("Unloading Steam API...OK") { return }
        }
        try? FileManager.default.removeItem(at: dir)
        throw SteamCMDError.failed("steamcmd ließ sich nach dem Update nicht starten.")
    }

    /// Runs steamcmd through script(1), so it sees a terminal and prints progress live.
    private nonisolated static func runLive(_ steamcmd: String, _ arguments: [String],
                                            onLine: @escaping @Sendable (String) throws -> Void) async throws -> String {
        try await SteamCMD.run("/usr/bin/script", ["-q", "/dev/null", steamcmd] + arguments, onLine: onLine)
    }

    /// Downloads to a temporary file, reporting the fraction done.
    private nonisolated static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamCMDError.failed("Der Download von Valve ist fehlgeschlagen.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let total = Double(max(response.expectedContentLength, 1))
        var buffer = Data(capacity: 65536)
        var written = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 65536 {
                try handle.write(contentsOf: buffer)
                written += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(min(written / total, 1))
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
        return file
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
