import Compression
import Foundation

// MARK: - Protobuf

/// Writes protobuf fields; enough for Steam's client messages.
struct ProtoWriter {
    var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }
    mutating func uint(_ field: Int, _ value: UInt64) { key(field, 0); varint(value) }
    mutating func int32(_ field: Int, _ value: Int32) { key(field, 0); varint(UInt64(bitPattern: Int64(value))) }
    mutating func bool(_ field: Int, _ value: Bool) { uint(field, value ? 1 : 0) }
    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ field: Int, _ value: Data) { key(field, 2); varint(UInt64(value.count)); data.append(value) }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
}

/// The fields of a protobuf message by number.
struct ProtoMessage {
    enum Value {
        case varint(UInt64), fixed64(UInt64), fixed32(UInt32), bytes(Data)
    }
    private(set) var fields: [Int: [Value]] = [:]

    struct Malformed: Error {}

    init(_ data: Data) throws {
        let b = [UInt8](data)
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw Malformed() }
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }
        func fixed(_ n: Int) throws -> UInt64 {
            guard i + n <= b.count else { throw Malformed() }
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
            i += n
            return v
        }
        while i < b.count {
            let key = try varint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0: value = .varint(try varint())
            case 1: value = .fixed64(try fixed(8))
            case 5: value = .fixed32(UInt32(try fixed(4)))
            case 2:
                let n = Int(try varint())
                guard n >= 0, i + n <= b.count else { throw Malformed() }
                value = .bytes(Data(b[i..<(i + n)])); i += n
            default: throw Malformed()
            }
            fields[field, default: []].append(value)
        }
    }

    func uint(_ f: Int) -> UInt64? {
        switch fields[f]?.last {
        case .varint(let v): return v
        case .fixed64(let v): return v
        case .fixed32(let v): return UInt64(v)
        default: return nil
        }
    }
    func int(_ f: Int) -> Int64? { uint(f).map { Int64(bitPattern: $0) } }
    func bool(_ f: Int) -> Bool { (uint(f) ?? 0) != 0 }
    func bytes(_ f: Int) -> Data? {
        if case .bytes(let d) = fields[f]?.last { return d }
        return nil
    }
    func string(_ f: Int) -> String? { bytes(f).flatMap { String(data: $0, encoding: .utf8) } }
    func all(_ f: Int) -> [Data] {
        (fields[f] ?? []).compactMap { if case .bytes(let d) = $0 { return d } else { return nil } }
    }
}

// MARK: - Compression

func gunzip(_ data: Data, size: Int) throws -> Data {
    let b = [UInt8](data)
    guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw ProtoMessage.Malformed() }
    let flags = b[3]
    var i = 10
    if flags & 4 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
    if flags & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
    if flags & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
    if flags & 2 != 0 { i += 2 }
    return try inflate(Data(b[i..<(b.count - 8)]), size: size)
}

/// Raw DEFLATE, as in gzip and zip
func inflate(_ data: Data, size: Int) throws -> Data {
    var out = Data(count: size)
    let written = out.withUnsafeMutableBytes { dst in
        data.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    guard written == size else { throw ProtoMessage.Malformed() }
    return out
}

/// The single entry of a zip archive, as Steam Cloud stores compressed files.
func unzipSingle(_ data: Data, rawSize: Int) throws -> Data {
    let b = [UInt8](data)
    guard b.count > 30, b[0] == 0x50, b[1] == 0x4b, b[2] == 3, b[3] == 4 else { throw ProtoMessage.Malformed() }
    let method = Int(b[8]) | Int(b[9]) << 8
    let compressedSize = Int(b[18]) | Int(b[19]) << 8 | Int(b[20]) << 16 | Int(b[21]) << 24
    let nameLength = Int(b[26]) | Int(b[27]) << 8
    let extraLength = Int(b[28]) | Int(b[29]) << 8
    let start = 30 + nameLength + extraLength
    let end = compressedSize > 0 ? min(b.count, start + compressedSize) : b.count
    let payload = Data(b[start..<end])
    switch method {
    case 0: return payload
    case 8: return try inflate(payload, size: rawSize)
    default: throw SteamConnection.Failure(description: "Zip-Methode \(method) nicht unterstützt")
    }
}
