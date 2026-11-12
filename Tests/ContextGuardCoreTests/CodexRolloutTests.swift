import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

final class CodexMetaTests: XCTestCase {
    let dir = TempDir()

    func meta(_ line: String) -> CodexMeta? {
        let t = Transcript(dir, name: "\(UUID().uuidString).jsonl")
        t.append(line, CodexLine.taskStarted())
        return CodexRollout.meta(path: t.path)
    }

    func testATerminalSessionIsOneToGuard() throws {
        let m = try XCTUnwrap(meta(CodexLine.meta()))
        XCTAssertEqual(m.threadId, CodexLine.thread)
        XCTAssertEqual(m.originator, "codex-tui")
        XCTAssertEqual(m.cliVersion, "0.167.1")
        XCTAssertTrue(m.isTerminalSession)
        XCTAssertTrue(try XCTUnwrap(meta(CodexLine.meta(history: "legacy"))).isTerminalSession, "Codex before 0.167")
    }

    func testOtherCodexThreadsAreNot() throws {
        let subagent: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": "x", "depth": 1]]]
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(source: subagent, threadSource: "subagent"))).isTerminalSession)
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(threadSource: "subagent"))).isTerminalSession)
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(originator: "Codex Desktop"))).isTerminalSession)
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(originator: "codex_exec", source: "exec"))).isTerminalSession)
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(history: "something-newer"))).isTerminalSession,
                       "a format this build hasn't seen isn't read")
    }

    func testASessionNamedAfterTheLinkIsATerminals() throws {
        // Codex names every session on an app server after its first client: the link, when it got
        // there before the terminal that started the server.
        XCTAssertTrue(try XCTUnwrap(meta(CodexLine.meta(originator: "context_guard"))).isTerminalSession)
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(originator: "context_guard", source: "exec"))).isTerminalSession)
        XCTAssertFalse(try XCTUnwrap(meta(CodexLine.meta(originator: "context_guard", threadSource: "subagent"))).isTerminalSession)
    }

    func testTheFirstLineIsReadWholeUpToAMegabyte() throws {
        XCTAssertNotNil(meta(CodexLine.meta(instructions: 900_000)))
        XCTAssertNil(meta(CodexLine.meta(instructions: 1_100_000)), "past the cap, nothing is guessed")
        XCTAssertNil(meta(CodexLine.taskStarted()), "not a rollout")
    }
}

final class CodexRolloutTests: XCTestCase {
    let dir = TempDir()
    var log: Transcript!

    override func setUp() {
        log = Transcript(dir, name: "rollout.jsonl")
        log.append(CodexLine.meta())
    }

    func testTheSizeIsTheLastRequestAsCodexCountsIt() {
        log.append(CodexLine.turn("Add a settings screen", reply: "Done.", tokens: 21_449))
        log.append(CodexLine.turn("Now tests", reply: "Added.", tokens: 160_000))
        let r = CodexRollout.read(path: log.path, cursor: nil)
        XCTAssertEqual(r.transcript.tokens, 160_000, "as given, not a sum")
        XCTAssertEqual(r.window, 258_400)
        XCTAssertEqual(r.model, "gpt-6-luna")
        XCTAssertFalse(r.turn.open)
        XCTAssertNotNil(r.transcript.cursor)
        XCTAssertEqual(r.transcript.cursor?.offset, log.size)
    }

    func testOnlyNewLinesAfterTheFirstRead() {
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        let first = CodexRollout.read(path: log.path, cursor: nil)
        let unchanged = CodexRollout.read(path: log.path, cursor: first.transcript.cursor, turn: first.turn)
        XCTAssertNil(unchanged.transcript.tokens)
        log.append(CodexLine.taskStarted(), CodexLine.tokens(31_000))
        let next = CodexRollout.read(path: log.path, cursor: first.transcript.cursor, turn: first.turn)
        XCTAssertEqual(next.transcript.tokens, 31_000)
        XCTAssertTrue(next.turn.open)
        XCTAssertEqual(next.transcript.from, first.transcript.cursor?.offset)
    }

    func testTurns() throws {
        log.append(CodexLine.taskStarted(at: "2026-11-11T00:10:31.574Z"))
        var r = CodexRollout.read(path: log.path, cursor: nil)
        XCTAssertTrue(r.turn.open)
        XCTAssertFalse(r.turn.hasContent)
        XCTAssertEqual(try XCTUnwrap(r.turn.startedAt).timeIntervalSince1970, 1_794_355_831.574, accuracy: 0.001)

        log.append(CodexLine.prompt("go"), CodexLine.turnAborted())
        r = CodexRollout.read(path: log.path, cursor: r.transcript.cursor, turn: r.turn)
        XCTAssertFalse(r.turn.open)
        XCTAssertTrue(r.turn.aborted)

        log.append(CodexLine.turn("again", reply: "ok", tokens: 40_000))
        r = CodexRollout.read(path: log.path, cursor: r.transcript.cursor, turn: r.turn)
        XCTAssertFalse(r.turn.aborted)
    }

    func testTheSaveMessageIsSeenInYourPromptOnly() {
        let id = "6a3c1f9e-0000-4000-8000-0000000000aa"
        log.append(CodexLine.reply("I'll watch for \(id)"))
        var r = CodexRollout.read(path: log.path, cursor: nil, markers: [id])
        XCTAssertTrue(r.transcript.markersSeen.isEmpty, "a reply quoting it doesn't count")
        log.append(CodexLine.taskStarted(), CodexLine.prompt("Save your work. [cg-1]", clientId: id))
        r = CodexRollout.read(path: log.path, cursor: r.transcript.cursor, markers: [id, "cg-1"])
        XCTAssertEqual(r.transcript.markersSeen, [id, "cg-1"])
    }

    func testAnOlderCodexsPromptsCountToo() {
        log.append(CodexLine.event(["type": "user_message", "client_id": "c-1", "message": "Save. [cg-2]"]))
        XCTAssertEqual(CodexRollout.read(path: log.path, cursor: nil, markers: ["cg-2"]).transcript.markersSeen, ["cg-2"])
    }

    func testCodexCompactingByItselfPartwayThroughATurn() {
        log.append(CodexLine.turn("big job", reply: "working", tokens: 230_000))
        log.append([CodexLine.taskStarted(), CodexLine.prompt("more"), CodexLine.toolCall(), CodexLine.tokens(241_780)]
                   + CodexLine.compacted() + [CodexLine.tokens(16_662)])
        let r = CodexRollout.read(path: log.path, cursor: nil)
        XCTAssertEqual(r.transcript.compaction, .compaction(trigger: "auto", preTokens: 241_780, postTokens: 16_662))
        XCTAssertEqual(r.transcript.tokens, 16_662)
        XCTAssertFalse(r.sizeAfterCompactionUnknown)
    }

    func testACompactionOnATurnOfItsOwnWasAskedFor() {
        log.append(CodexLine.turn("job", reply: "saved", tokens: 200_000))
        let before = CodexRollout.read(path: log.path, cursor: nil)
        log.append([CodexLine.taskStarted(), CodexLine.turnContext()] + CodexLine.compacted())
        let r = CodexRollout.read(path: log.path, cursor: before.transcript.cursor, turn: before.turn)
        XCTAssertEqual(r.transcript.compaction, .compaction(trigger: "manual", preTokens: nil, postTokens: nil))
        XCTAssertTrue(r.sizeAfterCompactionUnknown, "the size after it isn't written yet")
        XCTAssertNil(r.transcript.tokens)

        log.append(CodexLine.tokens(18_081), CodexLine.taskComplete())
        let after = CodexRollout.read(path: log.path, cursor: r.transcript.cursor, turn: r.turn)
        XCTAssertNil(after.transcript.compaction)
        XCTAssertEqual(after.transcript.tokens, 18_081)
    }

    func testTheTerminalAppsOwnCompactionTurn() {
        log.append(CodexLine.turn("job", reply: "saved", tokens: 200_000))
        let before = CodexRollout.read(path: log.path, cursor: nil)
        log.append(CodexLine.compactionTurn(after: 24_712))
        let r = CodexRollout.read(path: log.path, cursor: before.transcript.cursor, turn: before.turn)
        XCTAssertEqual(r.transcript.compaction, .compaction(trigger: "manual", preTokens: nil, postTokens: 24_712))
        XCTAssertEqual(r.transcript.tokens, 24_712)
        XCTAssertFalse(r.sizeAfterCompactionUnknown)
        XCTAssertFalse(r.turn.open)
        XCTAssertFalse(r.turn.aborted)
    }

    func testEscDuringACompactionLeavesNone() {
        log.append(CodexLine.turn("job", reply: "saved", tokens: 200_000))
        let before = CodexRollout.read(path: log.path, cursor: nil)
        log.append(CodexLine.compactionInterrupted())
        let r = CodexRollout.read(path: log.path, cursor: before.transcript.cursor, turn: before.turn)
        XCTAssertNil(r.transcript.compaction)
        XCTAssertTrue(r.turn.aborted)
        XCTAssertFalse(r.turn.open)
    }

    func testABigTailIsReadBackUntilASizeTurnsUp() {
        log.append(CodexLine.turn("one", reply: "ok", tokens: 90_000))
        log.append(CodexLine.toolOutput(String(repeating: "x", count: 600_000)))
        let r = CodexRollout.read(path: log.path, cursor: nil)
        XCTAssertEqual(r.transcript.tokens, 90_000)
    }
}

final class CodexConversationTests: XCTestCase {
    let dir = TempDir()
    var log: Transcript!
    let id = "6a3c1f9e-0000-4000-8000-0000000000aa"

    override func setUp() {
        log = Transcript(dir, name: "rollout.jsonl")
        log.append(CodexLine.meta())
        log.append(CodexLine.turn("Add a settings screen", reply: "Added it.", tokens: 150_000))
    }

    func testWhatTheSessionDidAfterTheSaveMessage() throws {
        let from = log.size
        log.append([CodexLine.taskStarted(), CodexLine.turnContext(), CodexLine.injected(),
                     CodexLine.prompt("Save your work.", clientId: id)] + CodexLine.reasoning()
                   + [CodexLine.toolCall(), CodexLine.toolOutput("main -> main"),
                      CodexLine.functionCall("shell", ["command": ["bash", "-lc", "git status"]]),
                      CodexLine.reply("Pushed. Ready for compaction."), CodexLine.replyRecord("Pushed. Ready for compaction."),
                      CodexLine.usageRecord(160_000), CodexLine.tokens(160_000), CodexLine.taskComplete()])
        let c = try XCTUnwrap(CodexConversation.read(path: log.path, from: from, after: id))
        XCTAssertEqual(c.after, id)
        XCTAssertEqual(c.text, """
        Codex used exec: await tools.exec_command({cmd: "git push"})

        Tool result: Script completed
        main -> main

        Codex used shell: git status

        Codex: Pushed. Ready for compaction.
        """)
        XCTAssertEqual(c.userPrompts, 0, "the save message itself isn't yours to count")
        XCTAssertFalse(c.text.contains("Save your work"), "the judge is given it on its own")
        XCTAssertFalse(c.text.contains("AGENTS.md"), "context Codex adds isn't the conversation")
    }

    func testSizesAndReasoningDoNotMoveTheMark() throws {
        log.append([CodexLine.taskStarted(), CodexLine.prompt("Save.", clientId: id), CodexLine.reply("Saved.")])
        let first = try XCTUnwrap(CodexConversation.read(path: log.path, from: nil, after: id))
        log.append(CodexLine.reasoning() + [CodexLine.usageRecord(1), CodexLine.tokens(161_000), CodexLine.taskComplete(),
                                            CodexLine.turnContext()])
        let again = try XCTUnwrap(CodexConversation.read(path: log.path, from: nil, after: id))
        XCTAssertEqual(again.mark, first.mark)
        XCTAssertGreaterThan(first.mark, 0)
    }

    func testYourPromptsAndInterruptionsAfterIt() throws {
        log.append([CodexLine.taskStarted(), CodexLine.prompt("Save.", clientId: id), CodexLine.turnAborted(),
                    CodexLine.taskStarted(), CodexLine.prompt("/compact"), CodexLine.taskStarted(), CodexLine.prompt("actually, also update the README")])
        let c = try XCTUnwrap(CodexConversation.read(path: log.path, from: nil, after: id))
        XCTAssertEqual(c.text, """
        The user interrupted the turn.

        User ran /compact

        User: actually, also update the README
        """)
        XCTAssertEqual(c.userPrompts, 2)
    }

    func testWithoutTheMarkerItIsEverythingRead() throws {
        let from = log.size
        log.append(CodexLine.taskStarted(), CodexLine.prompt("continue now"))
        let c = try XCTUnwrap(CodexConversation.read(path: log.path, from: from, after: nil))
        XCTAssertEqual(c.userPrompts, 1)
        XCTAssertEqual(c.text, "User: continue now")
    }

    func testAnOlderCodexsEvents() throws {
        log.append(CodexLine.event(["type": "user_message", "message": "Save. [cg-9]"]),
                   CodexLine.event(["type": "agent_message", "message": "Saved and pushed.", "phase": "final_answer"]),
                   CodexLine.replyRecord("Saved and pushed."))
        let c = try XCTUnwrap(CodexConversation.read(path: log.path, from: nil, after: "cg-9"))
        XCTAssertEqual(c.text, "Codex: Saved and pushed.")
    }
}
