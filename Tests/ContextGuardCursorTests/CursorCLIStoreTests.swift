import ContextGuardTestSupport
@testable import ContextGuardCursor
import XCTest

/// Protobuf the way the CLI writes its root blob.
enum Proto {
    static func varint(_ v: UInt64) -> Data {
        var v = v
        var out = Data()
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    static func field(_ n: UInt64, _ v: UInt64) -> Data { varint(n << 3) + varint(v) }
    static func field(_ n: UInt64, _ d: Data) -> Data { varint(n << 3 | 2) + varint(UInt64(d.count)) + d }
    static func fixed64(_ n: UInt64) -> Data { varint(n << 3 | 1) + Data(repeating: 7, count: 8) }
    static func fixed32(_ n: UInt64) -> Data { varint(n << 3 | 5) + Data(repeating: 7, count: 4) }

    /// A root blob: message ids, then the context {1: used, 2: window, 3: breakdown}, then more.
    static func root(tokens: UInt64, window: UInt64) -> Data {
        var d = Data()
        for i in 0..<6 { d += field(1, Data(repeating: UInt8(i), count: 32)) }
        d += field(5, field(1, tokens) + field(2, window) + field(3, Data("breakdown".utf8)))
        d += field(8, Data(repeating: 1, count: 32)) + fixed64(9) + field(10, 1) + fixed32(11)
        d += field(26, 1_794_629_684_789)
        return d
    }
}

final class CursorCLIStoreTests: XCTestCase {
    static let chat = "5f2c8e14-0b7a-4d39-86e1-a4d9c3b7f052"
    static let folder = "3b8e1f6a0c94d27e5a1b6c8d0f2e4a79"

    /// A chat's `store.db` like the CLI's: `meta` row `0` is hex JSON; blobs keyed by hash.
    @discardableResult
    static func makeChat(_ root: URL, id: String = CursorCLIStoreTests.chat, meta: [String: Any]? = nil,
                  blob: Data? = Proto.root(tokens: 17_458, window: 256_000)) -> SQLiteFixture {
        let db = SQLiteFixture(root.appendingPathComponent(Self.folder).appendingPathComponent(id).appendingPathComponent("store.db"))
        db.exec("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)")
        db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        let rootId = "a1f0c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1"
        let m = meta ?? ["agentId": id, "latestRootBlobId": rootId, "name": "README Summary", "mode": "default",
                         "isRunEverything": false, "createdAt": 1_794_629_671_957, "lastUsedModel": "default",
                         "blobEncryptionKey": "AAAA"]
        db.run("INSERT INTO meta VALUES ('0', ?)", Data(json(m).utf8).map { String(format: "%02x", $0) }.joined())
        db.run("INSERT INTO blobs VALUES (?, ?)", "0000000000000000000000000000000000000000000000000000000000000000",
               Proto.root(tokens: 1, window: 2))
        if let blob { db.run("INSERT INTO blobs VALUES (?, ?)", rootId, blob) }
        return db
    }

    static func store(_ dir: TempDir) -> CursorCLIStore {
        // Other folders (other workspaces), and files that aren't folders.
        let root = dir.url.appendingPathComponent("chats")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("6d0a9e3b71c4f8e25b9a0d1c7e3f4b68/8e3b5a1c-6f20-4d97-b0c4-2a7e9d1f5c36"),
                                                 withIntermediateDirectories: true)
        try! Data().write(to: root.appendingPathComponent(".DS_Store"))
        return CursorCLIStore(root: root)
    }

    func testReadsALiveChat() {
        let dir = TempDir()
        let store = Self.store(dir)
        let db = Self.makeChat(store.root)
        XCTAssertTrue(db.exists("-shm"))
        XCTAssertEqual(store.file(Self.chat)?.resolvingSymlinksInPath().path, db.url.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.chat(Self.chat), CursorStoredChat(tokens: 17_458, window: 256_000, name: "README Summary"))
    }

    func testReadsAChatTheCLIClosed() {
        let dir = TempDir()
        let store = Self.store(dir)
        let db = Self.makeChat(store.root)
        db.close()
        XCTAssertFalse(db.exists("-shm"))
        XCTAssertEqual(store.chat(Self.chat)?.tokens, 17_458)
        XCTAssertFalse(db.exists("-shm"))
        XCTAssertFalse(db.exists("-wal"))
    }

    func testANewChatHasNoSizeYet() {
        let dir = TempDir()
        let store = Self.store(dir)
        Self.makeChat(store.root, meta: ["agentId": Self.chat, "name": ""], blob: nil)
        XCTAssertEqual(store.chat(Self.chat), CursorStoredChat())
    }

    func testNoChat() {
        let dir = TempDir()
        let store = Self.store(dir)
        XCTAssertNil(store.chat(Self.chat))
        XCTAssertNil(store.chat("8e3b5a1c-6f20-4d97-b0c4-2a7e9d1f5c36"), "a folder without a store")
        XCTAssertNil(store.chat("../x"))
        XCTAssertNil(CursorCLIStore(root: dir.file("nowhere")).chat(Self.chat))
        // A meta row that isn't hex JSON.
        Self.makeChat(store.root, meta: [:]).run("UPDATE meta SET value = 'zz' WHERE key = '0'")
        XCTAssertNil(store.chat(Self.chat))
    }

    func testABlobThatIsNotTheContextGivesNoSize() {
        let dir = TempDir()
        let store = Self.store(dir)
        Self.makeChat(store.root, blob: Data([0xff, 0xff, 0xff]))
        XCTAssertEqual(store.chat(Self.chat), CursorStoredChat(name: "README Summary"))
    }

    func testProtobuf() {
        let msg = Proto.root(tokens: 300_000, window: 1_000_000)
        XCTAssertEqual(Protobuf.varint(26, in: msg), 1_794_629_684_789)
        XCTAssertEqual(Protobuf.varint(10, in: msg), 1)
        XCTAssertNil(Protobuf.varint(5, in: msg), "field 5 is a message")
        XCTAssertNil(Protobuf.varint(99, in: msg))
        XCTAssertEqual(Protobuf.message(5, in: msg).flatMap { Protobuf.varint(2, in: $0) }, 1_000_000)
        // Cut short: a length past the end, a varint that never ends, a group.
        XCTAssertNil(Protobuf.first(5, in: Proto.varint(5 << 3 | 2) + Proto.varint(10) + Data([1, 2])))
        XCTAssertNil(Protobuf.first(1, in: Data([0x08, 0xff, 0xff])))
        XCTAssertNil(Protobuf.first(1, in: Data([0x0b])))
        XCTAssertNil(Protobuf.first(1, in: Data()))
    }

    func testUnhex() {
        XCTAssertEqual(CursorCLIStore.unhex("7b7D"), Data("{}".utf8))
        XCTAssertNil(CursorCLIStore.unhex("7b7"))
        XCTAssertNil(CursorCLIStore.unhex("zz"))
    }
}
