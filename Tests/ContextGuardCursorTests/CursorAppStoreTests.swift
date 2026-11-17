import ContextGuardTestSupport
@testable import ContextGuardCursor
import XCTest

final class CursorAppStoreTests: XCTestCase {
    static let chat = "7c1e0a52-3b9d-4f61-9e2a-5d8c6b4a1f03"
    static let subagent = "2a9f6d10-8e47-4c3b-b1d5-0f7e3c9a6b28"
    static let fresh = "9d4b2e71-5c08-4a6f-8e3d-1b7a0c5f9e64"
    static let background = "bc-4e8a1c39-7d26-4b05-a9f1-6c3e2d8b0a57"

    /// A `state.vscdb` like Cursor's (its schema; the fields Context Guard reads, among others), in a
    /// folder whose name has a space, as "Application Support" does.
    static func makeStore(_ dir: TempDir) -> SQLiteFixture {
        let db = SQLiteFixture(dir.url.appendingPathComponent("Application Support/state.vscdb"))
        db.exec("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        db.exec("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:" + Self.chat, json([
            "_v": 16, "composerId": Self.chat, "name": "Fix the parser", "status": "completed",
            "contextTokensUsed": 115_251, "contextTokenLimit": 256_000, "contextUsagePercent": 45.02,
            "modelConfig": ["modelName": "grok-4.7", "maxMode": false], "subagentInfo": NSNull(),
            "fullConversationHeadersOnly": (0..<200).map { ["bubbleId": "b\($0)", "type": 1] },
        ]))
        db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:" + Self.subagent, json([
            "composerId": Self.subagent, "name": "Audit history", "contextTokensUsed": 71_786, "contextTokenLimit": 200_000,
            "subagentInfo": ["subagentType": 3, "parentComposerId": Self.chat],
        ]))
        db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:" + Self.fresh, json([
            "composerId": Self.fresh, "name": "", "status": "none",
        ]))
        db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:" + Self.background, json([
            "composerId": Self.background, "name": "Background task", "contextTokensUsed": 9_000, "contextTokenLimit": 200_000,
            "createdFromBackgroundAgent": ["bcId": Self.background, "shouldStreamMessages": true],
        ]))
        // Another chat's blob, stored as bytes rather than text.
        db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:0000aaaa-1111-2222-3333-444455556666",
               Data(json(["name": "Bytes", "contextTokensUsed": 5, "contextTokenLimit": 10]).utf8))
        return db
    }

    func testReadsAChatWhileCursorHasItsStoreOpen() {
        let dir = TempDir()
        let db = Self.makeStore(dir)
        XCTAssertTrue(db.exists("-shm"), "the fixture must look like a store Cursor has open")
        let read = ReadOnlyDatabase(db.url)!
        XCTAssertEqual(read.row("SELECT count(*) FROM cursorDiskKV"), [.int(5)])
        XCTAssertFalse(read.immutable)
        let store = CursorAppStore(file: db.url)
        XCTAssertEqual(store.chat(Self.chat), CursorStoredChat(tokens: 115_251, window: 256_000, name: "Fix the parser"))
        XCTAssertEqual(store.chat("0000aaaa-1111-2222-3333-444455556666"),
                       CursorStoredChat(tokens: 5, window: 10, name: "Bytes"))
    }

    func testSeesWritesCursorHasNotFoldedIntoTheFileYet() {
        let dir = TempDir()
        let db = Self.makeStore(dir)
        db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:" + Self.chat, json([
            "name": "Fix the parser", "contextTokensUsed": 130_000, "contextTokenLimit": 256_000,
        ]))
        XCTAssertEqual(CursorAppStore(file: db.url).chat(Self.chat)?.tokens, 130_000)
    }

    func testReadsAStoreCursorClosed() {
        let dir = TempDir()
        let db = Self.makeStore(dir)
        db.close()
        XCTAssertFalse(db.exists("-shm"))
        XCTAssertEqual(CursorAppStore(file: db.url).chat(Self.chat)?.tokens, 115_251)
        let read = ReadOnlyDatabase(db.url)!
        XCTAssertEqual(read.row("SELECT count(*) FROM cursorDiskKV"), [.int(5)])
        XCTAssertTrue(read.immutable, "read-only can't open a closed WAL file; it's read as it stands")
        // Reading never leaves files behind in Cursor's folder.
        XCTAssertFalse(db.exists("-shm"))
        XCTAssertFalse(db.exists("-wal"))
    }

    func testHelpersAndNewChats() {
        let dir = TempDir()
        let store = CursorAppStore(file: Self.makeStore(dir).url)
        XCTAssertEqual(store.chat(Self.subagent), CursorStoredChat(tokens: 71_786, window: 200_000, name: "Audit history", helper: true))
        XCTAssertEqual(store.chat(Self.background)?.helper, true)
        XCTAssertEqual(store.chat(Self.fresh), CursorStoredChat())
    }

    func testNoChatNoStoreOrABadId() {
        let dir = TempDir()
        let store = CursorAppStore(file: Self.makeStore(dir).url)
        XCTAssertNil(store.chat("9a9a9a9a-0000-0000-0000-000000000000"))
        XCTAssertNil(store.chat("x' OR 1=1 --"))
        XCTAssertNil(CursorAppStore(file: dir.file("missing.vscdb")).chat(Self.chat))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.file("missing.vscdb").path))
        // Not a database.
        try! Data("not sqlite".utf8).write(to: dir.file("junk.vscdb"))
        XCTAssertNil(CursorAppStore(file: dir.file("junk.vscdb")).chat(Self.chat))
    }

    func testDefaultFile() {
        XCTAssertEqual(CursorAppStore.defaultFile(home: URL(fileURLWithPath: "/Users/me")).path,
                       "/Users/me/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
}
