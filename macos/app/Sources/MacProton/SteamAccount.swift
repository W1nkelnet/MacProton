import AppKit
import CoreImage
import Foundation

/// Steam's web API, for signing in and finding Steam's servers.
enum SteamWebAPI {
    static let base = URL(string: "https://api.steampowered.com/")!

    /// Calls a service method and returns its "response" object.
    static func call(_ method: String, post: Bool, _ parameters: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: base.appendingPathComponent(method + "/v1/"), resolvingAgainstBaseURL: false)!
        let items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request: URLRequest
        if post {
            request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = items
            // URLComponents leaves "+" alone, which forms read as a space
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8) ?? Data()
        } else {
            components.queryItems = items
            request = URLRequest(url: components.url!)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["response"] as? [String: Any] else {
            throw SteamConnection.Failure(description: String(localized: "Steam antwortet nicht wie erwartet (\(method), HTTP \(status))."))
        }
        return result
    }
}

/// MacProton's own Steam sign-in for Steam Cloud. The refresh token stays
/// in a file only the user can read; the keychain would ask for access
/// after every update, since the app is signed per build.
struct SteamSession: Codable {
    var accountName: String
    var steamID: String
    var refreshToken: String
    var accessToken: String?

    static let dir = Paths.support.appendingPathComponent("steam-cloud", isDirectory: true)
    static let file = dir.appendingPathComponent("session.json")

    static func load() -> SteamSession? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SteamSession.self, from: data)
    }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.dir.path)
        fm.createFile(atPath: Self.file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try JSONEncoder().encode(self).write(to: Self.file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    /// The account part of the SteamID64, as in {Steam3AccountID}
    var accountID: UInt64 { (UInt64(steamID) ?? 0) & 0xFFFF_FFFF }

    /// A login ID of this installation, kept across runs, so that Steam
    /// keeps the Mac's Steam client signed in next to MacProton's sessions
    static var loginID: UInt32 {
        let file = dir.appendingPathComponent("login-id")
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let id = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let id = UInt32.random(in: 0x1000_0000...0xEFFF_FFFF)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(id).write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    /// The "sub" claim of a JWT, the SteamID64 for Steam's tokens
    static func subject(of token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["sub"] as? String
    }
}

/// Sign-in through a QR code that the Steam app on a phone approves, so
/// MacProton never sees the password.
@MainActor
final class SteamCloudAccount: ObservableObject {
    @Published private(set) var accountName: String? = SteamSession.load()?.accountName
    @Published private(set) var qrCode: NSImage?
    @Published private(set) var signingIn = false
    @Published var error: String?

    private var signIn: Task<Void, Never>?

    func startSignIn() {
        guard !signingIn else { return }
        signingIn = true
        error = nil
        signIn = Task {
            defer {
                signingIn = false
                qrCode = nil
            }
            do {
                // Platform type 1 (Steam client): its tokens also sign in to Steam's servers
                let begin = try await SteamWebAPI.call("IAuthenticationService/BeginAuthSessionViaQR", post: true,
                                                       ["device_friendly_name": "MacProton", "platform_type": "1"])
                guard var clientID = begin["client_id"] as? String,
                      let requestID = begin["request_id"] as? String,
                      let url = begin["challenge_url"] as? String else {
                    throw SteamConnection.Failure(description: String(localized: "Steam hat keine Anmeldung angelegt."))
                }
                qrCode = Self.qrImage(url)
                let interval = (begin["interval"] as? Double) ?? 5
                let deadline = Date().addingTimeInterval(600)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1e9))
                    let poll = try await SteamWebAPI.call("IAuthenticationService/PollAuthSessionStatus", post: true,
                                                          ["client_id": clientID, "request_id": requestID])
                    if let newID = poll["new_client_id"] as? String { clientID = newID }
                    // Steam renews the code now and then; the old one no longer works
                    if let newURL = poll["new_challenge_url"] as? String, !newURL.isEmpty { qrCode = Self.qrImage(newURL) }
                    if let refresh = poll["refresh_token"] as? String, !refresh.isEmpty {
                        let session = SteamSession(accountName: poll["account_name"] as? String ?? "",
                                                   steamID: SteamSession.subject(of: refresh) ?? "",
                                                   refreshToken: refresh,
                                                   accessToken: poll["access_token"] as? String)
                        try session.save()
                        accountName = session.accountName
                        return
                    }
                }
                error = String(localized: "Die Anmeldung ist abgelaufen. Starte sie neu.")
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signIn?.cancel()
    }

    /// Signs out at Steam too, which revokes MacProton's token there.
    func signOut() {
        let session = SteamSession.load()
        SteamSession.remove()
        accountName = nil
        guard let session else { return }
        Task.detached { try? await SteamConnection.open(session).signOut() }
    }

    static func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
    }
}
