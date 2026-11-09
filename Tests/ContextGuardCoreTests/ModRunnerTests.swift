import XCTest
@testable import ContextGuardCore

/// The whole follow-up through the hooks and the mod's two calls, against real files.
final class ModRunnerTests: HookTestCase {
    func tick(draft: Bool = false, agents: Int = 0) -> ModAction { mod.tick(ModFacts(sessionId: sid, agents: agents, draft: draft)) }

    /// The mod notes the conversation's turn ending, and a few seconds pass.
    func turnEnded() throws {
        mod.turn(ModTurn(sessionId: sid, active: false))
        clock.advance(3)
        try settle()
    }

    /// Asks to save, then Haiku calls it ready while agents it started run on in the background.
    func readyWithAgentsRunning() throws -> String {
        let nonce = try askToSave()
        try turnEnded()
        setStatus("busy")
        guard case .judge(_, let mark, _) = tick(agents: 2) else {
            XCTFail("background work doesn't keep Haiku from judging")
            return nonce
        }
        XCTAssertTrue(report(.judged, nonce: nonce, mark: mark, text: #"{"verdict":"ready","reason":"pushed"}"#))
        return nonce
    }

    func report(_ kind: ModReport.Kind, nonce: String, mark: UInt64? = nil, text: String? = nil) -> Bool {
        mod.report(ModReport(sessionId: sid, nonce: nonce, kind: kind, mark: mark, text: text))
    }

    /// Asks at 310k, you click Yes, the save message goes out at the next step, and the session saves
    /// and says it's ready. Returns the save message's tag.
    func askToSave(_ reply: String = "Pushed and saved. Ready for compaction.") throws -> String {
        try configure()
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        try answer(.yes)
        guard case .addContext(_, let text) = runner.handle(event("PostToolBatch")) else {
            XCTFail("expected the save message")
            return ""
        }
        let nonce = try XCTUnwrap(text.range(of: #"cg-[0-9a-f]+"#, options: .regularExpression).map { String(text[$0]) })
        transcript.append(Line.attachment(text), Line.toolUse("Bash", ["command": "git push"]), Line.toolResult("main -> main"),
                          Line.reply(reply), Line.bookkeeping())
        _ = runner.handle(event("Stop"))
        XCTAssertNotNil(state?.confirmedAt)
        try settle()
        return nonce
    }

    func testFromSaveMessageToContinue() throws {
        let nonce = try askToSave()
        guard case .judge(let n, let mark, let prompt) = tick() else { return XCTFail("expected Haiku to be asked") }
        XCTAssertEqual(n, nonce)
        XCTAssertTrue(prompt.contains("Claude used Bash: git push"))
        XCTAssertTrue(prompt.contains("Claude: Pushed and saved. Ready for compaction."))
        XCTAssertFalse(prompt.contains("reached 310k"), "the save message itself is quoted as the user's message, not repeated")
        XCTAssertEqual(state?.followUp?.stage, .checking)

        XCTAssertTrue(report(.judged, nonce: nonce, mark: mark, text: #"{"verdict":"ready","reason":"pushed"}"#))
        XCTAssertEqual(tick(), .compact(nonce: nonce))
        XCTAssertEqual(state?.followUp?.stage, .compacting)
        XCTAssertEqual(state?.followUp?.compactFrom, transcript.size)

        // The compaction, as Claude Code runs it: SessionStart(compact) first, then the record.
        setStatus("busy")
        _ = runner.handle(event("SessionStart", source: "compact"))
        XCTAssertEqual(state?.phase, .watching)
        XCTAssertEqual(state?.followUp?.stage, .continuing)
        transcript.append(Line.compaction(pre: 311_000, post: 24_000), Line.compactSummary())
        XCTAssertFalse(mod.report(ModReport(sessionId: sid, nonce: nonce, kind: .compacted, tokensBefore: 311_000, tokensAfter: 24_000)))
        try settle()
        XCTAssertEqual(tick(), .none, "still compacting")

        setStatus("idle")
        XCTAssertEqual(tick(), .continue(nonce: nonce, text: "continue now"))
        let f = try XCTUnwrap(state?.followUp)
        XCTAssertEqual(f.stage, .done)
        XCTAssertEqual(f.tokensBefore, 311_000)
        XCTAssertEqual(f.tokensAfter, 24_000)
        XCTAssertEqual(tick(), .none)
    }

    func testAPromptOfYoursDuringTheCompactionMeansNoContinue() throws {
        let nonce = try askToSave()
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("expected a judge") }
        _ = report(.judged, nonce: nonce, mark: mark, text: #"{"verdict":"ready"}"#)
        XCTAssertEqual(tick(), .compact(nonce: nonce))
        _ = runner.handle(event("SessionStart", source: "compact"))
        transcript.append(Line.compaction(pre: 311_000, post: 24_000), Line.compactSummary(), Line.prompt("now do the next thing"))
        try settle()
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(state?.followUp?.stage, .tookOver)
    }

    func testAQuestionToYouWaitsAndYourAnswerLetsItCompact() throws {
        let nonce = try askToSave("Pushed. Should I also delete the old branch?")
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("expected a judge") }
        XCTAssertFalse(report(.judged, nonce: nonce, mark: mark, text: #"{"verdict":"needs_user","reason":"asks about the branch"}"#))
        XCTAssertEqual(state?.followUp?.stage, .needsYou)
        XCTAssertEqual(tick(), .none)

        transcript.append(Line.prompt("yes delete it"), Line.reply("Deleted. Ready."))
        _ = runner.handle(event("Stop"))
        try settle()
        guard case .judge(_, let mark2, let prompt) = tick() else { return XCTFail("your answer is judged") }
        XCTAssertGreaterThan(mark2, mark)
        XCTAssertTrue(prompt.contains("User: yes delete it"))
        XCTAssertTrue(report(.judged, nonce: nonce, mark: mark2, text: #"{"verdict":"ready"}"#))
        XCTAssertEqual(tick(), .compact(nonce: nonce))
    }

    func testNothingWhileTheSessionIsBusyOrJustWrote() throws {
        let nonce = try askToSave()
        setStatus("busy")
        XCTAssertEqual(tick(), .none)
        mod.turn(ModTurn(sessionId: sid, active: true))
        XCTAssertEqual(tick(), .none, "the mod says a turn is running")
        setStatus("waiting")
        XCTAssertEqual(tick(), .none, "a permission prompt is up")
        setStatus("idle")
        transcript.append(Line.reply("one more line"))
        XCTAssertEqual(tick(), .none, "the transcript was written a moment ago")
        try settle()
        guard case .judge(let n, _, _) = tick() else { return XCTFail("expected a judge") }
        XCTAssertEqual(n, nonce)
    }

    /// Agents it left running don't hold it: they keep running through the compaction, and what
    /// they bring back reaches the compacted session.
    func testBackgroundAgentsDoNotHoldIt() throws {
        let nonce = try readyWithAgentsRunning()
        XCTAssertEqual(tick(agents: 2), .compact(nonce: nonce))
        XCTAssertEqual(state?.followUp?.stage, .compacting)
    }

    /// Nor does a command or monitor running in the background (Claude Code's status `shell`).
    func testABackgroundCommandDoesNotHoldIt() throws {
        let nonce = try askToSave()
        try turnEnded()
        setStatus("shell")
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("a background command doesn't keep Haiku from judging") }
        XCTAssertTrue(report(.judged, nonce: nonce, mark: mark, text: #"{"verdict":"ready","reason":"pushed"}"#))
        XCTAssertEqual(tick(), .compact(nonce: nonce))
    }

    /// After compacting, the continue message goes out between turns, background work or not.
    func testTheContinueMessageGoesOutWithBackgroundWorkRunning() throws {
        let nonce = try readyWithAgentsRunning()
        XCTAssertEqual(tick(agents: 2), .compact(nonce: nonce))
        XCTAssertFalse(report(.compacted, nonce: nonce))
        XCTAssertEqual(tick(agents: 2), .continue(nonce: nonce, text: Config.defaultContinueMessage))
        XCTAssertEqual(state?.followUp?.stage, .done)
    }

    func testTurnRecordsNeedNoLockAndLeaveTheStateAlone() throws {
        _ = try askToSave()
        let before = try Data(contentsOf: paths.stateFile(sid))
        // A hook reading a long transcript holds the lock.
        let lock = try XCTUnwrap(FileLock.acquire(paths.lockFile(sid), timeout: 1))
        defer { lock.release() }
        mod.turn(ModTurn(sessionId: sid, active: true))
        XCTAssertEqual(TurnRecord.load(sid, paths)?.active, true)
        XCTAssertEqual(try Data(contentsOf: paths.stateFile(sid)), before)

        mod.turn(ModTurn(sessionId: "not-a-known-session", active: true))
        mod.turn(ModTurn(sessionId: "../../etc", active: true))
        XCTAssertNil(TurnRecord.load("not-a-known-session", paths))
    }

    func testADraftHoldsTheCompaction() throws {
        let nonce = try askToSave()
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("expected a judge") }
        _ = report(.judged, nonce: nonce, mark: mark, text: #"{"verdict":"ready"}"#)
        XCTAssertEqual(tick(draft: true), .none)
        XCTAssertEqual(state?.followUp?.stage, .draft)
        XCTAssertEqual(tick(), .compact(nonce: nonce))
    }

    func testStoppingWatchingEndsIt() throws {
        _ = try askToSave()
        guard case .judge = tick() else { return XCTFail("expected a judge") }
        try watch(false)
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(state?.followUp?.stage, .stopped)
    }

    func testAnotherConversationInTheSameProcessIsNotTouched() throws {
        _ = try askToSave()
        registry.set(RegistryEntry(pid: claude, sessionId: "someone-else", kind: "interactive", entrypoint: "cli", status: "idle"))
        XCTAssertEqual(tick(), .none, "after /clear this process runs a different conversation")
    }

    func testTheEveryTenSecondsCaseTouchesNothing() throws {
        try configure()
        transcript.append(Line.context(120_000))
        _ = runner.handle(event("Stop"))
        let before = try Data(contentsOf: paths.stateFile(sid))
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(try Data(contentsOf: paths.stateFile(sid)), before)
        XCTAssertEqual(mod.tick(ModFacts(sessionId: "../../etc")), .none)
        XCTAssertEqual(mod.tick(ModFacts(sessionId: "not-a-known-session")), .none)
    }

    func testTheModReadsPlainJSON() throws {
        let judge = ModAction.judge(nonce: "cg-1", mark: 42, prompt: "p").json
        XCTAssertEqual(judge["action"] as? String, "judge")
        XCTAssertEqual(judge["model"] as? String, "haiku")
        XCTAssertEqual(judge["timeoutMs"] as? Int, 30_000)
        XCTAssertEqual((judge["mark"] as? NSNumber)?.uint64Value, 42)
        XCTAssertNotNil(try JSONSerialization.data(withJSONObject: judge))
        XCTAssertEqual(ModAction.continue(nonce: "cg-1", text: "go").json["text"] as? String, "go")
        XCTAssertEqual(ModAction.none.json["action"] as? String, "none")

        let report = try JSONDecoder().decode(ModReport.self, from: Data(#"{"sessionId":"s","nonce":"cg-1","kind":"judged","mark":42,"text":"{}"}"#.utf8))
        XCTAssertEqual(report.kind, .judged)
        XCTAssertEqual(report.mark, 42)
        let facts = try JSONDecoder().decode(ModFacts.self, from: Data(#"{"sessionId":"s"}"#.utf8))
        XCTAssertNil(facts.draft)
    }
}
