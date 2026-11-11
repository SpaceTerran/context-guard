import XCTest
@testable import ContextGuardCodexLink

final class CodexAPITests: XCTestCase {
    func testAThreadAsTheAppServerDescribesIt() throws {
        let v = try JSONValue.parse(#"""
        {"id":"t1","path":"/r/rollout.jsonl","cwd":"/code","name":"Settings","ephemeral":false,"model":"gpt-6-luna",
         "originator":"codex-tui","updatedAt":1794355000,"status":{"type":"active","activeFlags":["waitingOnApproval"]}}
        """#)
        let t = try XCTUnwrap(CodexThreadInfo.parse(v))
        XCTAssertEqual(t, CodexThreadInfo(id: "t1", path: "/r/rollout.jsonl", cwd: "/code", name: "Settings", status: "active",
                                          flags: ["waitingOnApproval"], ephemeral: false, model: "gpt-6-luna",
                                          originator: "codex-tui", recencyAt: 1_794_355_000))
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
        XCTAssertEqual(CodexSocketConnector.defaultSocketPath(["CODEX_HOME": "/tmp/ch"]), "/tmp/ch/app-server-control/app-server-control.sock")
        XCTAssertTrue(CodexSocketConnector.defaultSocketPath([:]).hasSuffix("/.codex/app-server-control/app-server-control.sock"))
        XCTAssertFalse(CodexSocketConnector(socketPath: "/nonexistent/x.sock").available())
        // A file that isn't a socket isn't one.
        XCTAssertFalse(CodexSocketConnector(socketPath: "/etc/hosts").available())
    }

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
