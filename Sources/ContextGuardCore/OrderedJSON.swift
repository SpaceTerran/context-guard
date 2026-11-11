import Foundation

/// A JSON document that keeps its keys in the order they were written and prints as `jq .` does, for
/// editing a file people also edit by hand (Claude Code's settings). Foundation's dictionaries would
/// reorder the keys.
public indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number as written. It prints in jq's form (see `jqNumber`).
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        /// Where in the text (bytes from the start).
        public var offset: Int
        public var reason: String
        public var description: String { "\(reason) at byte \(offset)" }
    }

    // MARK: Objects

    /// A member's value; nil when it's missing or this isn't an object.
    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// Sets a member's value where it is, or adds it at the end. Only for objects.
    public mutating func set(_ key: String, _ value: OrderedJSON) {
        guard case .object(var members) = self else { return }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append(Member(key, value))
        }
        self = .object(members)
    }

    // MARK: Reading

    /// Reads JSON text. A leading byte order mark is skipped. As jq does, a key given twice keeps
    /// its first place and its last value, and a lone surrogate escape is an error.
    public static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: Array(data))
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        p.skipSpace()
        let value = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.error("more text after the JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        /// Deeper than any real settings file; stops a hostile one from overflowing the stack.
        static let maxDepth = 512

        func error(_ reason: String) -> ParseError { ParseError(offset: i, reason: reason) }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard bytes.count - i >= w.count, Array(bytes[i ..< i + w.count]) == w else { throw error("expected \(word)") }
            i += w.count
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < Self.maxDepth else { throw error("nested too deeply") }
            guard i < bytes.count else { throw error("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws -> OrderedJSON {
            i += 1
            var members: [Member] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected :") }
                i += 1
                skipSpace()
                let v = try value(depth: depth + 1)
                if let at = members.firstIndex(where: { $0.key == key }) {
                    members[at].value = v
                } else {
                    members.append(Member(key, v))
                }
                skipSpace()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw error("expected , or }")
            }
        }

        mutating func array(depth: Int) throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(items)
            }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw error("expected , or ]")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - i >= 4 else { throw error("short \\u escape") }
            var v: UInt32 = 0
            for _ in 0 ..< 4 {
                let c = bytes[i]
                let d: UInt8
                switch c {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
                case UInt8(ascii: "a") ... UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A") ... UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
                default: throw error("bad \\u escape")
                }
                v = v << 4 | UInt32(d)
                i += 1
            }
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw error("unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                guard c >= 0x20 else { throw error("control character in a string") }
                guard c == UInt8(ascii: "\\") else {
                    out.append(c)
                    i += 1
                    continue
                }
                i += 1
                guard i < bytes.count else { throw error("unterminated string") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800 ... 0xDBFF).contains(scalar) {
                        guard bytes.count - i >= 2, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw error("lone surrogate escape")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00 ... 0xDFFF).contains(low) else { throw error("lone surrogate escape") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00 ... 0xDFFF).contains(scalar) {
                        throw error("lone surrogate escape")
                    }
                    out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar)!)).utf8))
                default:
                    throw error("bad escape")
                }
            }
        }

        mutating func number() throws -> String {
            let start = i
            func digits() -> Int {
                let s = i
                while i < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
                return i - s
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            let intStart = i
            guard digits() > 0 else { throw error("unexpected character") }
            if bytes[intStart] == UInt8(ascii: "0"), i - intStart > 1 { throw error("leading zero") }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digits() > 0 else { throw error("expected digits after .") }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw error("expected an exponent") }
            }
            return String(decoding: bytes[start ..< i], as: UTF8.self)
        }
    }

    // MARK: Writing

    /// The text `jq .` prints: two-space indents, `"key": value`, `{}` and `[]` when empty, and a
    /// final newline.
    public var jqText: String {
        var out = ""
        write(to: &out, indent: 0)
        out += "\n"
        return out
    }

    private func write(to out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.jqNumber(n)
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += String(repeating: " ", count: indent + 2)
                item.write(to: &out, indent: indent + 2)
                out += n < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (n, m) in members.enumerated() {
                out += String(repeating: " ", count: indent + 2)
                Self.writeString(m.key, to: &out)
                out += ": "
                m.value.write(to: &out, indent: indent + 2)
                out += n < members.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }

    /// As jq escapes: quote, backslash, the C escapes, other control characters and DEL as `\u00xx`;
    /// everything else as it is.
    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// A number as jq 1.7 prints it: its decimal value kept exactly, in the General Decimal
    /// Arithmetic "to-scientific-string" form. Plain decimals come out as written (`1.10`, `-0`);
    /// exponents are rewritten (`1e2` → `1E+2`, `0.1e-5` → `0.000001`).
    static func jqNumber(_ literal: String) -> String {
        var text = Substring(literal)
        let negative = text.hasPrefix("-")
        if negative { text = text.dropFirst() }
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let x = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")),
                  abs(x) < 1_000_000_000 else { return literal }
            exponent = x
            text = text[..<e]
        }
        var digits = String(text)
        if let dot = text.firstIndex(of: ".") {
            exponent -= text.distance(from: dot, to: text.endIndex) - 1
            digits.remove(at: digits.firstIndex(of: ".")!)
        }
        // The coefficient without leading zeros, at least one digit.
        let trimmed = digits.drop { $0 == "0" }
        let coefficient = trimmed.isEmpty ? "0" : String(trimmed)
        let adjusted = exponent + coefficient.count - 1
        var out = negative ? "-" : ""
        if exponent <= 0, adjusted >= -6 {
            if exponent == 0 { return out + coefficient }
            let point = coefficient.count + exponent
            if point > 0 {
                let head = coefficient.prefix(point)
                return out + head + "." + coefficient.dropFirst(point)
            }
            return out + "0." + String(repeating: "0", count: -point) + coefficient
        }
        out += String(coefficient.prefix(1))
        if coefficient.count > 1 { out += "." + coefficient.dropFirst() }
        return out + "E" + (adjusted >= 0 ? "+" : "-") + String(abs(adjusted))
    }
}
