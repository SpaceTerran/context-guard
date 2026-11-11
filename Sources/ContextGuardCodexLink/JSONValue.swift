import Foundation

/// A JSON value, as the Codex app server's messages carry them.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var double: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    /// A whole number that fits exactly.
    public var int: Int? {
        guard case .number(let d) = self, d.rounded() == d, abs(d) <= 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    public enum ParseError: Error, Equatable {
        case notJSON
    }

    /// One JSON document.
    public static func parse(_ data: Data) throws -> JSONValue {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ParseError.notJSON
        }
        return from(any)
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(from))
        case let o as [String: Any]:
            return .object(o.mapValues(from))
        default:
            return .null
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let d):
            guard d.isFinite else { return NSNull() }
            // Whole numbers go out as integers ("1", not "1.0").
            if d.rounded() == d, abs(d) <= 9_007_199_254_740_992 { return NSNumber(value: Int64(d)) }
            return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    /// Compact, with sorted keys.
    public func serialized() -> Data {
        (try? JSONSerialization.data(withJSONObject: foundation,
                                     options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: serialized(), as: UTF8.self) }
}
