import XCTest
@testable import ContextGuardCodexLink

final class CodexAPITests: XCTestCase {
    func testAThreadAsTheAppServerDescribesIt() throws {
        let v = try JSONValue.parse(#"""
        {"id":"t1","path":"/r/rollout.jsonl","cwd":"/code","name":"Settings","ephemeral":false,"model":"gpt-6-luna",
         "originator":"codex-tui","createdAt":1794350000,"updatedAt":1794355000,
         "status":{"type":"active","activeFlags":["waitingOnApproval"]}}
        """#)
        let t = try XCTUnwrap(CodexThreadInfo.parse(v))
        XCTAssertEqual(t, CodexThreadInfo(id: "t1", path: "/r/rollout.jsonl", cwd: "/code", name: "Settings", status: "active",
                                          flags: ["waitingOnApproval"], ephemeral: false, model: "gpt-6-luna",
                                          originator: "codex-tui", recencyAt: 1_794_355_000, createdAt: 1_794_350_000))
        XCTAssertNil(CodexThreadInfo.parse(["id": ""]))
        let bare = try XCTUnwrap(CodexThreadInfo.parse(["id": "t2"]))
        XCTAssertEqual(bare.status, "notLoaded")
        XCTAssertTrue(bare.ephemeral, "a thread that doesn't say is left alone")
    }

    func testTheSettingsThatMatter() throws {
        let facts = CodexConfigFacts.parse(["config": [
            "model_auto_compact_token_limit": 180_000,
            "model_post_turn_compact_threshold_percent": 70,
            "mcp_servers": ["zeta": [:], "alpha": ["command": "x"]],
        ]])
        XCTAssertEqual(facts, CodexConfigFacts(autoCompactLimit: 180_000, postTurnCompactPercent: 70, mcpServers: ["alpha", "zeta"]))
        XCTAssertEqual(CodexConfigFacts.parse(["config": ["model_auto_compact_token_limit": .null, "mcp_servers": .null]]), CodexConfigFacts())
        XCTAssertEqual(CodexConfigFacts.parse(["config": ["model_auto_compact_token_limit": 0,
                                                          "model_post_turn_compact_threshold_percent": 0]]), CodexConfigFacts(),
                       "not limits")
        XCTAssertEqual(CodexConfigFacts.parse(.null), CodexConfigFacts())
    }

    func testOurMessageIdsAreOursAndStable() {
        let save = CodexClientID.make(nonce: "cg-862a4887a7", kind: "save")
        XCTAssertEqual(save, CodexClientID.make(nonce: "cg-862a4887a7", kind: "save"))
        XCTAssertNotEqual(save, CodexClientID.make(nonce: "cg-862a4887a7", kind: "continue"))
        XCTAssertNotNil(UUID(uuidString: save), "shaped like the ids Codex makes")
        XCTAssertTrue(save.hasPrefix(CodexClientID.prefix))
        XCTAssertTrue(CodexClientID.isOurs(save))
        XCTAssertFalse(CodexClientID.isOurs(UUID().uuidString.lowercased()))
        XCTAssertFalse(CodexClientID.isOurs(nil))
    }

    func testListsAreReadPageByPage() throws {
        let daemon = FakeDaemon()
        daemon.pageSize = 2
        for i in 0..<5 { daemon.add(.init(id: "t\(i)", path: "/r/\(i)", cwd: "/code")) }
        XCTAssertEqual(try daemon.loadedThreadIds(timeout: 1), ["t0", "t1", "t2", "t3", "t4"])
        XCTAssertEqual(daemon.calls("thread/loaded/list").map { $0["cursor"]?.string }, [nil, "2", "4"])
        XCTAssertEqual(try daemon.models(timeout: 1).map(\.id), ["gpt-5.6-luna", "gpt-6-luna"])
    }

    func testWhatCountsAsARefusalOrAMissingMethod() {
        XCTAssertTrue(CodexLinkError.rpc(code: -32601, message: "Method not found").isMissingMethod)
        XCTAssertTrue(CodexLinkError.rpc(code: -32600, message: "Invalid request: unknown variant `thread/queue/add`, expected one of …").isMissingMethod)
        XCTAssertFalse(CodexLinkError.rpc(code: -32600, message: "thread not found").isMissingMethod)
        XCTAssertTrue(CodexLinkError.rpc(code: -32600, message: "thread not found").isRefusal)
        XCTAssertFalse(CodexLinkError.timeout("thread/queue/add").isRefusal, "it may have happened")
        XCTAssertFalse(CodexLinkError.closed("gone").isRefusal)
        XCTAssertFalse(CodexLinkError.timeout("x").isMissingMethod)
    }

    func testTheSocketIsFoundInCodexsHome() {
        #if os(Windows)
        XCTAssertEqual(CodexSocketConnector.defaultSocketPath(["CODEX_HOME": "C:/ch/"]), "C:\\ch\\app-server-control\\app-server-control.sock")
        XCTAssertEqual(CodexSocketConnector.defaultSocketPath([:]), NSHomeDirectory() + "\\.codex\\app-server-control\\app-server-control.sock")
        XCTAssertNil(CodexSocketConnector(socketPath: "C:\\nonexistent\\x.sock").socketTime())
        // A file that isn't a socket isn't one.
        XCTAssertNil(CodexSocketConnector(socketPath: ProcessInfo.processInfo.arguments[0]).socketTime())
        #else
        XCTAssertEqual(CodexSocketConnector.defaultSocketPath(["CODEX_HOME": "/tmp/ch"]), "/tmp/ch/app-server-control/app-server-control.sock")
        XCTAssertTrue(CodexSocketConnector.defaultSocketPath([:]).hasSuffix("/.codex/app-server-control/app-server-control.sock"))
        XCTAssertNil(CodexSocketConnector(socketPath: "/nonexistent/x.sock").socketTime())
        // A file that isn't a socket isn't one.
        XCTAssertNil(CodexSocketConnector(socketPath: "/etc/hosts").socketTime())
        #endif
    }

    func testAListeningSocketIsFound() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cg-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("app-server-control.sock").path
        XCTAssertNil(CodexSocketConnector(socketPath: path).socketTime(), "not there yet")
        let listener = try SocketListener(path: path)
        XCTAssertNotNil(CodexSocketConnector(socketPath: path).socketTime())
        XCTAssertNoThrow(try SocketStream.connect(unixPath: path).close())
        listener.close()
        XCTAssertNil(CodexSocketConnector(socketPath: path).socketTime(), "gone with its listener")
        let file = dir.appendingPathComponent("plain").path
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data("x".utf8)))
        XCTAssertNil(CodexSocketConnector(socketPath: file).socketTime(), "a plain file")
    }

    func testTheSocketsTimeIsWhenItsServerStarted() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cg-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("app-server-control.sock").path
        let connector = CodexSocketConnector(socketPath: path)
        let before = Date()
        let first = try SocketListener(path: path)
        let made = try XCTUnwrap(connector.socketTime())
        XCTAssertLessThan(abs(made.timeIntervalSince(before)), 2, "about now")
        first.close()
        Thread.sleep(forTimeInterval: 0.05)
        // The next server's socket in its place: Windows gives it the creation time of the one
        // just deleted, and its time must still be its own.
        let second = try SocketListener(path: path)
        defer { second.close() }
        XCTAssertGreaterThan(try XCTUnwrap(connector.socketTime()), made)
    }

    #if !os(Windows)
    func testASocketLinkedFromCodexsHomeIsFound() throws {
        // Codex 0.167.1: app-server-control.sock is a symlink to the socket in /private/tmp.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cg-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("s").path
        let listener = try SocketListener(path: real)
        defer { listener.close() }
        let link = dir.appendingPathComponent("app-server-control.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertNotNil(CodexSocketConnector(socketPath: real).socketTime())
        XCTAssertNotNil(CodexSocketConnector(socketPath: link).socketTime())
        XCTAssertNoThrow(try SocketStream.connect(unixPath: link).close())

        let toFile = dir.appendingPathComponent("to-file").path
        try FileManager.default.createSymbolicLink(atPath: toFile, withDestinationPath: "/etc/hosts")
        XCTAssertNil(CodexSocketConnector(socketPath: toFile).socketTime())
        let dangling = dir.appendingPathComponent("dangling").path
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: dir.appendingPathComponent("gone").path)
        XCTAssertNil(CodexSocketConnector(socketPath: dangling).socketTime())
    }
    #endif

    func testAConnectorWithNoAppServerFailsToConnect() {
        XCTAssertThrowsError(try CodexSocketConnector(socketPath: "/nonexistent/x.sock").connect(onEvent: { _ in }))
    }
}

final class JSONValueTests: XCTestCase {
    func testItReadsAndWritesJSON() throws {
        let v = try JSONValue.parse(#"{"a":[1,true,null,"x",2.5],"b":{"c":-3}}"#)
        XCTAssertEqual(v["a"]?[0]?.int, 1)
        XCTAssertEqual(v["a"]?[1]?.bool, true)
        XCTAssertEqual(v["a"]?[2]?.isNull, true)
        XCTAssertEqual(v["a"]?[3]?.string, "x")
        XCTAssertEqual(v["a"]?[4]?.double, 2.5)
        XCTAssertNil(v["a"]?[4]?.int, "not a whole number")
        XCTAssertNil(v["a"]?[9])
        XCTAssertEqual(v["b"]?["c"]?.int, -3)
        XCTAssertEqual(v.text, #"{"a":[1,true,null,"x",2.5],"b":{"c":-3}}"#)
        XCTAssertEqual(try JSONValue.parse(v.text), v)
    }

    func testBooleansAndNumbersStayApart() throws {
        let v = try JSONValue.parse("[true,1,false,0]")
        XCTAssertEqual(v, [true, 1, false, 0])
        XCTAssertNil(v[1]?.bool)
        XCTAssertNil(v[0]?.int)
    }

    func testTextThatIsntJSON() {
        XCTAssertThrowsError(try JSONValue.parse("not json"))
        XCTAssertEqual(try JSONValue.parse("\"/a/b\"").text, "\"/a/b\"", "slashes aren't escaped")
    }
}
