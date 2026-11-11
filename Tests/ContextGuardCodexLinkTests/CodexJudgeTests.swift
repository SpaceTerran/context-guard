import XCTest
@testable import ContextGuardCodexLink

final class CodexJudgeTests: XCTestCase {
    let daemon = FakeDaemon()
    let waiters = TurnWaiters()

    override func setUp() {
        let waiters = self.waiters
        daemon.onEvent = { waiters.handle($0) }
    }

    func ask(timeout: TimeInterval = 2) -> Result<String, CodexLinkError> {
        CodexJudge.ask("Has it saved?", model: "gpt-6-luna", cwd: "/tmp/judge", mcpServers: ["docs"],
                       daemon: daemon, waiters: waiters, callTimeout: 1, timeout: timeout)
    }

    func testTheSmallestModelOffered() {
        XCTAssertEqual(CodexJudge.pickModel([.init(id: "gpt-6.1"), .init(id: "gpt-5.6-luna"), .init(id: "gpt-6-luna")]), "gpt-6-luna")
        XCTAssertEqual(CodexJudge.pickModel([.init(id: "gpt-6-luna", hidden: true), .init(id: "gpt-5.6-luna")]), "gpt-5.6-luna",
                       "a hidden one isn't offered")
        XCTAssertNil(CodexJudge.pickModel([.init(id: "gpt-6.1"), .init(id: "codex-auto-review", hidden: true)]))
    }

    func testItsThreadCanDoNothingButAnswer() {
        let p = CodexJudge.threadParams(model: "gpt-6-luna", cwd: "/tmp/judge", mcpServers: ["docs", "linear"])
        XCTAssertEqual(p["model"]?.string, "gpt-6-luna")
        XCTAssertEqual(p["ephemeral"]?.bool, true, "nothing saved")
        XCTAssertEqual(p["sandbox"]?.string, "read-only")
        XCTAssertEqual(p["cwd"]?.string, "/tmp/judge")
        XCTAssertEqual(p["baseInstructions"]?.string, CodexJudge.instructions)
        for empty in ["environments", "dynamicTools", "runtimeWorkspaceRoots", "selectedCapabilityRoots"] {
            XCTAssertEqual(p[empty], [], empty)
        }
        let config = p["config"]
        for feature in ["shell_tool", "unified_exec", "hooks", "plugins", "apps", "memories", "multi_agent", "standalone_web_search"] {
            XCTAssertEqual(config?["features.\(feature)"]?.bool, false, feature)
        }
        XCTAssertEqual(config?["web_search"]?.string, "disabled")
        XCTAssertEqual(config?["mcp_servers"], ["docs": ["enabled": false], "linear": ["enabled": false]])
        XCTAssertNil(CodexJudge.threadParams(model: "m", cwd: "/", mcpServers: [])["config"]?["mcp_servers"])
    }

    func testItsTurnAsksForTheVerdictShape() {
        let p = CodexJudge.turnParams(threadId: "t", prompt: "Has it saved?")
        XCTAssertEqual(p["outputSchema"], CodexJudge.schema)
        XCTAssertEqual(p["effort"]?.string, "low")
        XCTAssertEqual(p["input"]?[0]?["text"]?.string, "Has it saved?")
        XCTAssertEqual(CodexJudge.schema["properties"]?["verdict"]?["enum"], ["ready", "working", "needs_user"])
    }

    func testTheAnswerIsTheFinalMessage() {
        let turn: JSONValue = ["items": [
            ["type": "agentMessage", "phase": "commentary", "text": "thinking"],
            ["type": "agentMessage", "phase": "final_answer", "text": "{\"verdict\":\"ready\"}"],
            ["type": "agentMessage", "phase": "commentary", "text": "after"],
        ]]
        XCTAssertEqual(CodexJudge.answer(in: turn), "{\"verdict\":\"ready\"}")
        XCTAssertEqual(CodexJudge.answer(in: ["items": [["type": "agentMessage", "text": "only"]]]), "only")
        XCTAssertNil(CodexJudge.answer(in: ["items": [["type": "userMessage"]]]))
    }

    func testAQuestionAndItsAnswer() throws {
        XCTAssertEqual(try ask().get(), #"{"verdict":"ready","reason":"pushed and saved"}"#)
        XCTAssertEqual(daemon.calls.map(\.method), ["thread/start", "turn/start", "thread/unsubscribe"])
        let start = try XCTUnwrap(daemon.calls("thread/start").first)
        XCTAssertEqual(start["config"]?["mcp_servers"], ["docs": ["enabled": false]])
        let turn = try XCTUnwrap(daemon.calls("turn/start").first)
        let thread = try XCTUnwrap(daemon.calls("thread/unsubscribe").first?["threadId"]?.string)
        XCTAssertEqual(turn["threadId"]?.string, thread)
    }

    func testNoAnswerInTimeStopsItsTurn() throws {
        daemon.judge = .silent
        let started = Date()
        XCTAssertEqual(ask(timeout: 0.2).failure, .timeout("the judge"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        let interrupt = try XCTUnwrap(daemon.calls("turn/interrupt").first)
        XCTAssertNotNil(interrupt["turnId"]?.string)
        XCTAssertEqual(daemon.calls.last?.method, "thread/unsubscribe", "let go of it either way")
    }

    func testATurnThatFailedIsNoAnswer() {
        daemon.judge = .ends("failed")
        XCTAssertEqual(ask().failure, .closed("the model refused"))
    }

    func testAnEmptyAnswerIsNoAnswer() {
        daemon.judge = .answer("")
        guard case .protocolError = ask().failure else { return XCTFail("expected a failure") }
    }

    func testTheAppServerRefusingTheThread() {
        daemon.failing["thread/start"] = .rpc(code: -32600, message: "model not available")
        XCTAssertEqual(ask().failure, .rpc(code: -32600, message: "model not available"))
        XCTAssertEqual(daemon.calls.map(\.method), ["thread/start"])
    }

    func testTheConnectionEndingWhileItWaits() {
        daemon.judge = .silent
        let waiters = self.waiters
        daemon.onCall = { method, _ in
            if method == "turn/start" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { waiters.handle(.closed("the app server went away")) }
            }
        }
        XCTAssertEqual(ask().failure, .closed("the app server went away"))
    }

    func testItsThreadClosingWhileItWaits() {
        daemon.judge = .silent
        let waiters = self.waiters
        daemon.onCall = { method, params in
            if method == "turn/start", let id = params["threadId"] {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    waiters.handle(.notification(method: "thread/closed", params: ["threadId": id]))
                }
            }
        }
        XCTAssertEqual(ask().failure, .closed("its thread closed"))
    }

    func testWaitersOnlyHearTheirOwnTurns() {
        let w = waiters.register("judge-1")
        XCTAssertFalse(waiters.handle(.notification(method: "turn/completed", params: ["threadId": "yours", "turn": [:]])))
        XCTAssertFalse(waiters.handle(.notification(method: "item/completed", params: ["threadId": "judge-1", "item": ["type": "reasoning"]])))
        XCTAssertTrue(waiters.handle(.notification(method: "item/completed",
                                                   params: ["threadId": "judge-1", "item": ["type": "agentMessage", "text": "seen"]])))
        XCTAssertTrue(waiters.handle(.notification(method: "turn/completed", params: ["threadId": "judge-1", "turn": ["status": "completed"]])))
        guard case .finished(_, let last) = w.wait(timeout: 1) else { return XCTFail("expected it finished") }
        XCTAssertEqual(last, "seen", "the message seen on the way, for a turn that lists none")
        waiters.remove("judge-1")
        XCTAssertFalse(waiters.handle(.closed("gone")), "nobody waits any more")
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
