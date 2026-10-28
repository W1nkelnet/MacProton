import Foundation

/// Sets up Valve's steamcmd in Application Support on first launch, so no
/// Homebrew is needed. steamcmd updates itself there on its first start.
@MainActor
final class SteamCMDSetup: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var error: String?

    /// Valve's download, the same Homebrew uses
    nonisolated static let url = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
    /// Valve's Developer ID team, which signs steamcmd
    nonisolated static let requirement = #"anchor apple generic and certificate leaf[subject.OU] = "MXGJJ98X76""#

    func setUpIfNeeded() {
        guard Paths.steamcmd == nil, !running else { return }
        running = true
        error = nil
        Task {
            do {
                try await Self.install(into: Paths.steamcmdDir)
            } catch {
                self.error = "steamcmd konnte nicht eingerichtet werden: \(error.localizedDescription)"
            }
            running = false
        }
    }

    nonisolated static func install(into dir: URL) async throws {
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamCMDError.failed("Der Download von Valve ist fehlgeschlagen.")
        }

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
        for _ in 0..<3 {
            let output = (try? await SteamCMD.run(steamcmd, ["+quit"]) { _ in }) ?? ""
            if output.contains("Unloading Steam API...OK") { return }
        }
        try? FileManager.default.removeItem(at: dir)
        throw SteamCMDError.failed("steamcmd ließ sich nach dem Update nicht starten.")
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
