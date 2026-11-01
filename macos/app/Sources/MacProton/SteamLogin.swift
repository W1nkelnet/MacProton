import Foundation

/// Logs steamcmd in, answering its password and Steam Guard prompts with what
/// the user types in the login window. steamcmd then caches a login token, so
/// later runs need no password. The password is written to steamcmd's
/// terminal only, never passed as an argument and never stored.
@MainActor
final class SteamLogin: ObservableObject {
    enum Step: Equatable {
        case idle
        case connecting
        case password
        case emailCode
        case mobileCode
        case mobileConfirmation
        case done
        case failed(String)
    }

    @Published private(set) var step = Step.idle
    @Published private(set) var account = ""
    /// Set when the user should see the login window
    @Published var isPresented = false

    var running: Bool { process?.isRunning ?? false }

    private var process: Process?
    private var input: Pipe?
    private var buffer = ""

    func present(account: String) {
        self.account = account
        if !running { step = .idle }
        isPresented = true
    }

    func start(account: String) {
        guard !running, let steamcmd = Paths.steamcmd else {
            if Paths.steamcmd == nil { step = .failed(SteamCMDError.notInstalled.localizedDescription) }
            return
        }
        self.account = account
        buffer = ""
        step = .connecting

        // Through script(1), so steamcmd prompts on a terminal as it would for a person
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", steamcmd, "+login", account, "+quit"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Paths.steamcmdHome.path
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.received(text) }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.finished() }
        }
        do {
            try process.run()
            self.process = process
            self.input = input
        } catch {
            step = .failed(String(localized: "steamcmd konnte nicht gestartet werden: \(error.localizedDescription)"))
        }
    }

    /// Answers the current prompt with the password or code.
    func submit(_ answer: String) {
        guard running, [.password, .emailCode, .mobileCode].contains(step) else { return }
        step = .connecting
        input?.fileHandleForWriting.write(Data((answer + "\n").utf8))
    }

    func cancel() {
        if running { process?.terminate() }
        step = .idle
        isPresented = false
    }

    private func received(_ text: String) {
        buffer += text
        let lower = buffer.lowercased()

        if let message = Self.failure(in: buffer) {
            step = .failed(message)
            process?.terminate()
        } else if lower.contains("waiting for user info...ok") {
            step = .done
            buffer = ""
            UserDefaults.standard.set(account, forKey: "steamAccount")
        } else if lower.hasSuffix("password: ") || lower.hasSuffix("password:") {
            step = .password
            buffer = ""
        } else if lower.contains("steam guard code:") {
            step = .emailCode
            buffer = ""
        } else if lower.contains("two-factor code:") {
            step = .mobileCode
            buffer = ""
        } else if lower.contains("steam mobile app") {
            step = .mobileConfirmation
        }
    }

    private func finished() {
        process = nil
        input = nil
        buffer = ""
        switch step {
        case .done, .failed, .idle: break
        default: step = .failed(String(localized: "steamcmd wurde vor dem Ende der Anmeldung beendet."))
        }
    }

    /// steamcmd ends a failed login with e.g. "FAILED (Invalid Password)"
    static func failure(in text: String) -> String? {
        guard let range = text.range(of: #"(FAILED|ERROR) \(([^)]*)\)"#, options: .regularExpression) else { return nil }
        let reason = text[range].drop { $0 != "(" }.dropFirst().dropLast()
        switch reason {
        case "Invalid Password": return String(localized: "Benutzername oder Passwort ist falsch.")
        case "Two-factor code mismatch", "Invalid Login Auth Code": return String(localized: "Der Steam-Guard-Code stimmt nicht.")
        case "Rate Limit Exceeded": return String(localized: "Zu viele Anmeldeversuche. Warte ein paar Minuten.")
        default: return String(localized: "Anmeldung fehlgeschlagen (\(reason)).")
        }
    }
}
