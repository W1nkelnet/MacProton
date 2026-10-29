import CryptoKit
import Foundation

/// A short session with Steam's servers as a Steam client holds one, for
/// the Steam Cloud methods that the web API only offers to publishers.
///
/// Two things keep the Mac's Steam client signed in next to it: the session
/// uses a login ID of its own (Steam replaces a session only when another
/// one logs in with the same ID), and it ends by closing the connection.
/// A ClientLogOff would sign out like the client's menu does, which revokes
/// the refresh token.
final class SteamConnection {
    private enum EMsg {
        static let multi: UInt32 = 1
        static let serviceMethodResponse: UInt32 = 147
        static let serviceMethodCallFromClient: UInt32 = 151
        static let clientHeartBeat: UInt32 = 703
        static let clientLogOff: UInt32 = 706
        static let clientLogOnResponse: UInt32 = 751
        static let clientLoggedOff: UInt32 = 757
        static let clientLogon: UInt32 = 5514
        static let clientHello: UInt32 = 9805
    }
    private static let protocolVersion: UInt64 = 65580
    private static let osTypeMacOS: Int32 = -102

    struct Failure: LocalizedError {
        var description: String
        var eresult: Int64 = 0
        var errorDescription: String? { description }
    }
    static let resultDuplicateRequest: Int64 = 29

    private struct Packet {
        var emsg: UInt32
        var header: ProtoMessage
        var body: Data
    }

    private let task: URLSessionWebSocketTask
    private var queue: [Packet] = []
    private(set) var steamID: UInt64 = 0
    private(set) var clientInstanceID: UInt64 = 0
    private var sessionID: Int32 = 0
    private var nextJob: UInt64 = 1
    private var heartbeat: Task<Void, Never>?

    private init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        task.resume()
    }

    deinit { disconnect() }

    /// Connects to a Steam server and signs in with the session's refresh token.
    static func open(_ session: SteamSession) async throws -> SteamConnection {
        let result = try await SteamWebAPI.call("ISteamDirectory/GetCMListForConnect", post: false,
                                                ["cellid": "0", "cmtype": "websockets"])
        let endpoints = (result["serverlist"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String) == "websockets" }
            .compactMap { $0["endpoint"] as? String }
        guard let endpoint = endpoints.first, let url = URL(string: "wss://\(endpoint)/cmsocket/") else {
            throw Failure(description: "Steam nennt keinen Server für die Verbindung.")
        }
        let connection = SteamConnection(url: url)
        do {
            try await connection.logon(session)
        } catch {
            connection.disconnect()
            throw error
        }
        return connection
    }

    func disconnect() {
        heartbeat?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Signs out like the Steam client's menu, which revokes the refresh token.
    func signOut() async {
        try? await send(EMsg.clientLogOff, header: header(), body: Data())
        try? await Task.sleep(nanoseconds: 500_000_000)
        disconnect()
    }

    // MARK: Messages

    private func header(job: UInt64? = nil, method: String? = nil) -> Data {
        var h = ProtoWriter()
        h.fixed64(1, steamID)
        h.int32(2, sessionID)
        if let job { h.fixed64(10, job) }
        if let method { h.string(12, method) }
        return h.data
    }

    private func send(_ emsg: UInt32, header: Data, body: Data) async throws {
        var packet = Data()
        withUnsafeBytes(of: (emsg | 0x8000_0000).littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(header.count).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(header)
        packet.append(body)
        try await task.send(.data(packet))
    }

    private static func parse(_ data: Data) throws -> [Packet] {
        let b = [UInt8](data)
        guard b.count >= 8 else { throw ProtoMessage.Malformed() }
        func u32(_ at: Int) -> UInt32 {
            UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        }
        let raw = u32(0)
        guard raw & 0x8000_0000 != 0 else { return [] }  // not a protobuf message, none of ours
        let emsg = raw & 0x7fff_ffff
        let headerLength = Int(u32(4))
        guard 8 + headerLength <= b.count else { throw ProtoMessage.Malformed() }
        let header = try ProtoMessage(Data(b[8..<(8 + headerLength)]))
        let body = Data(b[(8 + headerLength)...])
        guard emsg == EMsg.multi else { return [Packet(emsg: emsg, header: header, body: body)] }

        // Several messages, gzipped when size_unzipped is set
        let multi = try ProtoMessage(body)
        var content = multi.bytes(2) ?? Data()
        if let size = multi.uint(1), size > 0 { content = try gunzip(content, size: Int(size)) }
        let c = [UInt8](content)
        var packets: [Packet] = []
        var i = 0
        while i + 4 <= c.count {
            let n = Int(UInt32(c[i]) | UInt32(c[i + 1]) << 8 | UInt32(c[i + 2]) << 16 | UInt32(c[i + 3]) << 24)
            i += 4
            guard i + n <= c.count else { throw ProtoMessage.Malformed() }
            packets += try parse(Data(c[i..<(i + n)]))
            i += n
        }
        return packets
    }

    private func receive() async throws -> Packet {
        while queue.isEmpty {
            let message = try await task.receive()
            guard case .data(let data) = message else { continue }
            queue += try Self.parse(data)
        }
        return queue.removeFirst()
    }

    // MARK: Session

    private func logon(_ session: SteamSession) async throws {
        guard let id = UInt64(session.steamID) else { throw Failure(description: "Die Steam-Anmeldung nennt kein Konto.") }
        steamID = id

        var hello = ProtoWriter()
        hello.uint(1, Self.protocolVersion)
        try await send(EMsg.clientHello, header: header(), body: hello.data)

        let obfuscated = SteamSession.loginID ^ 0xBAAD_F00D
        var ip = ProtoWriter()
        ip.fixed32(1, obfuscated)
        var logon = ProtoWriter()
        logon.uint(1, Self.protocolVersion)
        logon.uint(2, UInt64(obfuscated))
        logon.uint(3, 0)
        logon.uint(5, 1771)
        logon.string(6, "english")
        logon.uint(7, UInt64(UInt32(bitPattern: Self.osTypeMacOS)))
        logon.bool(8, false)
        logon.bytes(11, ip.data)
        logon.string(50, session.accountName)
        logon.string(96, "MacProton")
        logon.string(108, session.refreshToken)
        try await send(EMsg.clientLogon, header: header(), body: logon.data)

        while true {
            let packet = try await receive()
            if packet.emsg == EMsg.clientLogOnResponse {
                let response = try ProtoMessage(packet.body)
                let eresult = response.int(1) ?? 2
                guard eresult == 1 else {
                    throw Failure(description: eresult == 5 || eresult == 15
                                  ? "Steam hat die Anmeldung von MacProton nicht angenommen. Melde dich in den Einstellungen neu an."
                                  : "Steam-Anmeldung fehlgeschlagen (EResult \(eresult)).", eresult: eresult)
                }
                if let s = packet.header.uint(1) { steamID = s }
                sessionID = Int32(truncatingIfNeeded: packet.header.int(2) ?? 0)
                clientInstanceID = response.uint(27) ?? 0
                startHeartbeat(every: Double(max(5, response.int(3) ?? response.int(2) ?? 30)))
                return
            }
            if packet.emsg == EMsg.clientLoggedOff {
                throw Failure(description: "Steam hat die Verbindung beendet (EResult \(try ProtoMessage(packet.body).int(1) ?? 0)).")
            }
        }
    }

    private func startHeartbeat(every seconds: Double) {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                guard let self, !Task.isCancelled else { return }
                try? await self.send(EMsg.clientHeartBeat, header: self.header(), body: Data())
            }
        }
    }

    /// Calls a unified service method, e.g. "Cloud.GetAppFileChangelist#1".
    func call(_ method: String, _ body: Data) async throws -> ProtoMessage {
        let job = nextJob
        nextJob += 1
        try await send(EMsg.serviceMethodCallFromClient, header: header(job: job, method: method), body: body)
        while true {
            let packet = try await receive()
            guard packet.emsg == EMsg.serviceMethodResponse, packet.header.uint(11) == job else { continue }
            let eresult = packet.header.int(13) ?? 2
            guard eresult == 1 else {
                throw Failure(description: "\(method): EResult \(eresult) \(packet.header.string(14) ?? "")", eresult: eresult)
            }
            return try ProtoMessage(packet.body)
        }
    }
}

// MARK: - Steam Cloud

/// A file as the cloud lists it for an app.
struct CloudFile {
    /// With the root as prefix, e.g. "%WinAppDataLocalLow%Redbeet Interactive/Raft/…"
    var path: String
    var sha: String
    var timestamp: Date
    var size: Int
    /// ECloudStoragePersistState: 0 persisted, 1 forgotten, 2 deleted
    var persistState: Int
    /// ERemoteStoragePlatform bits
    var platforms: UInt32

    var isPersisted: Bool { persistState == 0 }
    /// Kept for Windows, the platform of the games MacProton runs
    var isForWindows: Bool { platforms == 0 || platforms & 1 != 0 }
}

/// The Cloud service methods the Steam client uses to sync a game.
enum SteamCloudService {
    static func files(_ connection: SteamConnection, appID: Int) async throws -> (changeNumber: UInt64, files: [CloudFile]) {
        var request = ProtoWriter()
        request.uint(1, UInt64(appID))
        request.uint(2, 0)
        let response = try await connection.call("Cloud.GetAppFileChangelist#1", request.data)
        let prefixes = response.all(4).map { String(decoding: $0, as: UTF8.self) }
        let files = try response.all(2).map { data -> CloudFile in
            let f = try ProtoMessage(data)
            let prefixIndex = Int(f.uint(7) ?? 0)
            return CloudFile(path: (prefixIndex < prefixes.count ? prefixes[prefixIndex] : "") + (f.string(1) ?? ""),
                             sha: hex(f.bytes(2) ?? Data()),
                             timestamp: Date(timeIntervalSince1970: TimeInterval(f.uint(3) ?? 0)),
                             size: Int(f.uint(4) ?? 0),
                             persistState: Int(f.uint(5) ?? 0),
                             platforms: UInt32(truncatingIfNeeded: f.uint(6) ?? 0))
        }
        return (response.uint(1) ?? 0, files)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func sha1(_ data: Data) -> String { hex(Data(Insecure.SHA1.hash(data: data))) }

    /// Downloads a file and checks it against the SHA-1 the cloud has for it.
    static func download(_ connection: SteamConnection, appID: Int, path: String) async throws -> Data {
        var request = ProtoWriter()
        request.uint(1, UInt64(appID))
        request.string(2, path)
        request.uint(3, 1)  // k_ESteamRealmSteamGlobal
        let r = try await connection.call("Cloud.ClientFileDownload#1", request.data)
        guard !r.bool(11) else { throw SteamConnection.Failure(description: "\(path) ist verschlüsselt gespeichert.") }
        guard let host = r.string(7), let urlPath = r.string(8),
              let url = URL(string: (r.bool(9) ? "https://" : "http://") + host + urlPath) else {
            throw SteamConnection.Failure(description: "Steam nennt keine Download-Adresse für \(path).")
        }
        var http = URLRequest(url: url)
        for h in r.all(10) {
            let header = try ProtoMessage(h)
            if let name = header.string(1), let value = header.string(2) { http.setValue(value, forHTTPHeaderField: name) }
        }
        let (data, response) = try await URLSession.shared.data(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SteamConnection.Failure(description: "Download von \(path): HTTP \(status)") }
        let fileSize = Int(r.uint(2) ?? 0), rawSize = Int(r.uint(3) ?? 0)
        let raw = (fileSize != rawSize && rawSize > 0) ? try unzipSingle(data, rawSize: rawSize) : data
        guard sha1(raw) == hex(r.bytes(4) ?? Data()) else {
            throw SteamConnection.Failure(description: "\(path) kam beschädigt an (SHA-1 weicht ab).")
        }
        return raw
    }

    struct Upload {
        var path: String
        var data: Data
        var timestamp: Date
        var platforms: UInt32
    }

    /// Uploads and deletes files in one batch, as the Steam client does after
    /// a game ends. Files the cloud already has with the same content are
    /// skipped (EResult 29). Throws, and completes the batch as failed, if
    /// anything did not go through.
    static func commit(_ connection: SteamConnection, appID: Int, uploads: [Upload], deletes: [String],
                       machineName: String) async throws {
        guard !uploads.isEmpty || !deletes.isEmpty else { return }
        var begin = ProtoWriter()
        begin.uint(1, UInt64(appID))
        begin.string(2, machineName)
        for upload in uploads { begin.string(3, upload.path) }
        for path in deletes { begin.string(4, path) }
        begin.uint(5, connection.clientInstanceID)
        let batchID = try await connection.call("Cloud.BeginAppUploadBatch#1", begin.data).uint(1) ?? 0

        func complete(_ eresult: UInt64) async throws {
            var request = ProtoWriter()
            request.uint(1, UInt64(appID))
            request.uint(2, batchID)
            request.uint(3, eresult)
            _ = try await connection.call("Cloud.CompleteAppUploadBatchBlocking#1", request.data)
        }

        do {
            for upload in uploads { try await uploadFile(connection, appID: appID, upload, batchID: batchID) }
            for path in deletes {
                var request = ProtoWriter()
                request.uint(1, UInt64(appID))
                request.string(2, path)
                request.bool(3, true)
                request.uint(4, batchID)
                _ = try await connection.call("Cloud.ClientDeleteFile#1", request.data)
            }
        } catch {
            try? await complete(2)  // k_EResultFail
            throw error
        }
        try await complete(1)
    }

    private static func uploadFile(_ connection: SteamConnection, appID: Int, _ upload: Upload, batchID: UInt64) async throws {
        let sha = Data(Insecure.SHA1.hash(data: upload.data))
        var file = ProtoWriter()
        file.uint(1, UInt64(appID))
        file.uint(2, UInt64(upload.data.count))
        file.uint(3, UInt64(upload.data.count))
        file.bytes(4, sha)
        file.uint(5, UInt64(max(0, upload.timestamp.timeIntervalSince1970)))
        file.string(6, upload.path)
        file.uint(7, UInt64(upload.platforms))
        file.bool(10, false)
        file.uint(13, batchID)
        let started: ProtoMessage
        do {
            started = try await connection.call("Cloud.ClientBeginFileUpload#1", file.data)
        } catch let failure as SteamConnection.Failure where failure.eresult == SteamConnection.resultDuplicateRequest {
            return  // the cloud has this content already
        }
        guard !started.bool(1) else {
            throw SteamConnection.Failure(description: "Steam verlangt Verschlüsselung für \(upload.path).")
        }

        var succeeded = true
        for blockData in started.all(2) {
            let block = try ProtoMessage(blockData)
            guard let host = block.string(1), let urlPath = block.string(2),
                  let url = URL(string: (block.bool(3) ? "https://" : "http://") + host + urlPath) else {
                succeeded = false
                break
            }
            var request = URLRequest(url: url)
            // EHTTPMethod: 1 GET, 2 HEAD, 3 POST, 4 PUT
            request.httpMethod = [1: "GET", 2: "HEAD", 3: "POST", 4: "PUT", 5: "DELETE"][Int(block.int(4) ?? 4)] ?? "PUT"
            for h in block.all(5) {
                let header = try ProtoMessage(h)
                if let name = header.string(1), let value = header.string(2) { request.setValue(value, forHTTPHeaderField: name) }
            }
            let offset = Int(block.uint(6) ?? 0)
            let length = Int(block.uint(7) ?? UInt64(upload.data.count))
            let body = block.bytes(8) ?? upload.data.subdata(in: min(offset, upload.data.count)..<min(upload.data.count, offset + length))
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            if !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                succeeded = false
                break
            }
        }

        var commit = ProtoWriter()
        commit.bool(1, succeeded)
        commit.uint(2, UInt64(appID))
        commit.bytes(3, sha)
        commit.string(4, upload.path)
        let committed = try await connection.call("Cloud.ClientCommitFileUpload#1", commit.data).bool(1)
        guard succeeded, committed else {
            throw SteamConnection.Failure(description: "Steam hat \(upload.path) nicht angenommen.")
        }
    }
}
