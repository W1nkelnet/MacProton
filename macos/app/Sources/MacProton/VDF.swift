import Foundation

/// Valve's text KeyValues format (VDF), as printed by steamcmd and used in
/// Steam's config files. Keys keep their order; lookups ignore case.
indirect enum VDF {
    case string(String)
    case dict([(String, VDF)])

    subscript(key: String) -> VDF? {
        guard case .dict(let entries) = self else { return nil }
        return entries.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    subscript(path: String...) -> VDF? {
        path.reduce(self as VDF?) { $0?[$1] }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var entries: [(String, VDF)] {
        if case .dict(let entries) = self { return entries }
        return []
    }

    /// Parses `"key" "value"` pairs and `"key" { ... }` blocks.
    static func parse(_ text: String) -> VDF {
        var tokens = Tokenizer(text)
        return .dict(parseEntries(&tokens))
    }

    private static func parseEntries(_ tokens: inout Tokenizer) -> [(String, VDF)] {
        var entries: [(String, VDF)] = []
        while let token = tokens.next() {
            guard case .string(let key) = token else { break } // closing brace
            switch tokens.next() {
            case .string(let value): entries.append((key, .string(value)))
            case .open: entries.append((key, .dict(parseEntries(&tokens))))
            default: return entries
            }
        }
        return entries
    }

    private enum Token { case string(String), open, close }

    private struct Tokenizer {
        let chars: [Character]
        var index = 0

        init(_ text: String) { chars = Array(text) }

        mutating func next() -> Token? {
            while index < chars.count {
                let c = chars[index]
                if c.isWhitespace { index += 1; continue }
                if c == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                    while index < chars.count && chars[index] != "\n" { index += 1 }
                    continue
                }
                index += 1
                switch c {
                case "{": return .open
                case "}": return .close
                case "\"": return .string(quoted())
                default:
                    var value = String(c)
                    while index < chars.count && !chars[index].isWhitespace && !"{}\"".contains(chars[index]) {
                        value.append(chars[index]); index += 1
                    }
                    return .string(value)
                }
            }
            return nil
        }

        private mutating func quoted() -> String {
            var value = ""
            while index < chars.count && chars[index] != "\"" {
                // Only known escapes; Windows paths contain plain backslashes
                if chars[index] == "\\" && index + 1 < chars.count && "nt\\\"".contains(chars[index + 1]) {
                    index += 1
                    switch chars[index] {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    default: value.append(chars[index])
                    }
                } else {
                    value.append(chars[index])
                }
                index += 1
            }
            index += 1
            return value
        }
    }
}
