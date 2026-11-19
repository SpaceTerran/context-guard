import ContextGuardCore
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
            "promptTokenBreakdown": breakdown(115_251, of: 256_000),
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
            "name": "Fix the parser", "promptTokenBreakdown": breakdown(130_000, of: 256_000),
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

    /// Cursor has kept a chat's size two ways: `contextTokensUsed` of `contextTokenLimit`, and
    /// `promptTokenBreakdown`. Chats from one build have both, from another only the breakdown.
    func testReadsAChatsSizeWhereverCursorKeptIt() {
        let dir = TempDir()
        let db = Self.makeStore(dir)
        let store = CursorAppStore(file: db.url)
        func put(_ id: String, _ fields: [String: Any]) {
            db.run("INSERT INTO cursorDiskKV VALUES (?, ?)", "composerData:" + id,
                   json(["composerId": id, "name": "Sized"].merging(fields) { $1 }))
        }
        func size(_ id: String) -> [Int?] { [store.chat(id)?.tokens, store.chat(id)?.window] }

        put("a0000000-0000-0000-0000-000000000001", ["contextTokensUsed": 71_786, "contextTokenLimit": 200_000])
        XCTAssertEqual(size("a0000000-0000-0000-0000-000000000001"), [71_786, 200_000], "the older fields alone")

        put("a0000000-0000-0000-0000-000000000002", [
            "promptTokenBreakdown": breakdown(111_603, of: 256_000), "contextUsagePercent": 43.6,
        ])
        XCTAssertEqual(store.chat("a0000000-0000-0000-0000-000000000002"),
                       CursorStoredChat(tokens: 111_603, window: 256_000, name: "Sized"), "the breakdown alone")

        put("a0000000-0000-0000-0000-000000000003", [
            "contextTokensUsed": 90_000, "contextTokenLimit": 200_000, "promptTokenBreakdown": breakdown(52_758, of: 256_000),
        ])
        XCTAssertEqual(size("a0000000-0000-0000-0000-000000000003"), [52_758, 256_000], "both, and they differ: the breakdown")

        put("a0000000-0000-0000-0000-000000000004", [
            "contextTokensUsed": 40_000, "contextTokenLimit": 200_000, "promptTokenBreakdown": breakdown(0, of: 0),
        ])
        XCTAssertEqual(size("a0000000-0000-0000-0000-000000000004"), [40_000, 200_000],
                       "an empty breakdown: the older fields, tokens and window together")

        put("a0000000-0000-0000-0000-000000000005", ["promptTokenBreakdown": breakdown(0, of: 0)])
        XCTAssertEqual(size("a0000000-0000-0000-0000-000000000005"), [0, nil], "a subagent's empty breakdown")

        put("a0000000-0000-0000-0000-000000000006", ["promptTokenBreakdown": NSNull(), "contextUsagePercent": 12.5])
        XCTAssertEqual(store.chat("a0000000-0000-0000-0000-000000000006"), CursorStoredChat(name: "Sized"),
                       "neither: a share alone gives no tokens or window")
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

    func testAnArchivedOrDeletedChatIsNoLongerOpen() {
        let dir = TempDir()
        let db = Self.makeStore(dir)
        let store = CursorAppStore(file: db.url)
        XCTAssertEqual(store.standing(Self.chat), .open, "a store without composerHeaders (before Cursor 3.30)")

        // Cursor 3.30's table, as it stands on disk.
        db.exec("""
            CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, \
            lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, \
            value TEXT, subagentTypeName TEXT)
            """)
        db.run("INSERT INTO composerHeaders (composerId, isArchived) VALUES (?, 0)", Self.chat)
        XCTAssertEqual(store.standing(Self.chat), .open)
        XCTAssertEqual(store.standing(Self.fresh), .open, "no header row yet")

        db.exec("UPDATE composerHeaders SET isArchived = 1")
        XCTAssertEqual(store.standing(Self.chat), .archived)
        XCTAssertEqual(store.standing(CursorChatRef(id: Self.chat, name: nil, surface: .app, pid: 1)), .archived)
        XCTAssertNil(store.standing(CursorChatRef(id: Self.chat, name: nil, surface: .cli, pid: 1)),
                     "a CLI chat ends with its cursor-agent")

        XCTAssertEqual(store.standing("9a9a9a9a-0000-0000-0000-000000000000"), .deleted)
        XCTAssertNil(store.standing("x' OR 1=1 --"))
        XCTAssertNil(CursorAppStore(file: dir.file("missing.vscdb")).standing(Self.chat), "can't tell")
        try! Data("not sqlite".utf8).write(to: dir.file("junk.vscdb"))
        XCTAssertNil(CursorAppStore(file: dir.file("junk.vscdb")).standing(Self.chat), "can't tell")
    }

    func testCountsOtherChatsListedUnderTheSameName() {
        let dir = TempDir()
        let db = Self.makeStore(dir)
        let store = CursorAppStore(file: db.url)
        XCTAssertNil(store.namesakes(of: Self.chat, named: "Fix the parser"), "no composerHeaders (before Cursor 3.30): can't tell")

        db.exec("""
            CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, \
            lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, \
            subagentTypeName TEXT, value TEXT)
            """)
        func header(_ id: String, _ name: String?, archived: Int? = 0, subagent: Int? = 0) {
            let value = name.map { json(["composerId": id, "name": $0, "unifiedMode": "agent"]) } ?? json(["composerId": id])
            let flags = [archived, subagent].map { $0.map(String.init) ?? "NULL" }.joined(separator: ", ")
            db.run("INSERT INTO composerHeaders (composerId, isArchived, isSubagent, value) VALUES (?, \(flags), ?)", id, value)
        }
        header(Self.chat, "Fix the parser")
        header(Self.fresh, nil)
        XCTAssertEqual(store.namesakes(of: Self.chat, named: "Fix the parser"), 0, "itself doesn't count")

        header("11111111-2222-4333-8444-555555555555", "Fix the parser", archived: 1)
        header("22222222-3333-4444-8555-666666666666", "Fix the parser", subagent: 1)
        header("33333333-4444-4555-8666-777777777777", "Fix the parser test")
        XCTAssertEqual(store.namesakes(of: Self.chat, named: "Fix the parser"), 0,
                       "archived chats, subagents' and other names aren't in the app's list under it")

        header("44444444-5555-4666-8777-888888888888", "Fix the parser", archived: nil, subagent: nil)
        XCTAssertEqual(store.namesakes(of: Self.chat, named: "Fix the parser"), 1)

        XCTAssertNil(store.namesakes(of: "x' OR 1=1 --", named: "Fix the parser"))
        XCTAssertNil(store.namesakes(of: Self.chat, named: ""))
        XCTAssertNil(CursorAppStore(file: dir.file("missing.vscdb")).namesakes(of: Self.chat, named: "Fix the parser"))
    }

    func testDefaultFile() {
        XCTAssertEqual(CursorAppStore.defaultFile(home: URL(fileURLWithPath: "/Users/me")).path,
                       "/Users/me/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
}

/// `promptTokenBreakdown` as Cursor writes it.
private func breakdown(_ used: Int, of max: Int) -> [String: Any] {
    ["totalUsedTokens": used, "maxTokens": max,
     "categories": used == 0 ? [] : [["id": "conversation", "label": "Conversation", "estimatedTokens": used]]]
}
