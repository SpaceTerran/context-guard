import ContextGuardCore
import Foundation

/// The Cursor CLI's chats: one SQLite file each, `~/.cursor/chats/<folder hash>/<conversation id>/store.db`.
/// Its `meta` table's row `0` is the chat's JSON (hex-encoded): its name and its latest root blob;
/// that blob (protobuf) holds the context size and window in field 5.
public struct CursorCLIStore: Sendable {
    public var root: URL

    public init(root: URL = CursorCLIStore.defaultRoot()) {
        self.root = root
    }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".cursor/chats")
    }

    /// The chat's `store.db`, or nil if the CLI has no such chat.
    public func file(_ id: String) -> URL? {
        guard Paths.isValidSessionID(id) else { return nil }
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent(id).appendingPathComponent("store.db") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// The chat, or nil if the CLI has no such chat (or its store can't be read).
    public func chat(_ id: String) -> CursorStoredChat? {
        guard let file = file(id), let db = ReadOnlyDatabase(file) else { return nil }
        guard let hex = db.row("SELECT value FROM meta WHERE key = '0'")?.first?.text,
              let data = Self.unhex(hex),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var chat = CursorStoredChat(name: (meta["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        if let blobId = meta["latestRootBlobId"] as? String,
           let blob = db.row("SELECT data FROM blobs WHERE id = ?1", [blobId])?.first?.data,
           let context = Protobuf.message(5, in: blob) {
            chat.tokens = Protobuf.varint(1, in: context).flatMap { Int(exactly: $0) }
            chat.window = Protobuf.varint(2, in: context).flatMap { Int(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
        }
        return chat
    }

    static func unhex(_ s: String) -> Data? {
        let bytes = Array(s.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// Just enough protobuf to find a field: the first occurrence of a field number at the top level of
/// a message. Malformed input finds nothing.
enum Protobuf {
    static func varint(_ field: Int, in data: Data) -> UInt64? {
        if case .varint(let v)? = first(field, in: data) { return v }
        return nil
    }

    static func message(_ field: Int, in data: Data) -> Data? {
        if case .bytes(let d)? = first(field, in: data) { return d }
        return nil
    }

    enum Value: Equatable { case varint(UInt64), bytes(Data), fixed }

    static func first(_ field: Int, in data: Data) -> Value? {
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            guard let key = readVarint(b, &i) else { return nil }
            let number = Int(truncatingIfNeeded: key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                guard let v = readVarint(b, &i) else { return nil }
                value = .varint(v)
            case 1:
                guard b.count - i >= 8 else { return nil }
                i += 8
                value = .fixed
            case 2:
                guard let n = readVarint(b, &i), n <= UInt64(b.count - i) else { return nil }
                value = .bytes(Data(b[i..<i + Int(n)]))
                i += Int(n)
            case 5:
                guard b.count - i >= 4 else { return nil }
                i += 4
                value = .fixed
            default:
                return nil
            }
            if number == field { return value }
        }
        return nil
    }

    private static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let c = b[i]
            i += 1
            result |= UInt64(c & 0x7f) << shift
            if c < 0x80 { return result }
            shift += 7
        }
        return nil
    }
}
