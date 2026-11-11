import XCTest
@testable import ContextGuardCore

final class HookRunnerTests: HookTestCase {
    // MARK: -

    func testAsksAtTheThresholdThenDeliversYesAtTheNextStepOnce() throws {
        transcript.append(Line.title("Refactor the billing API"), Line.context(310_000))
        XCTAssertEqual(runner.handle(event("PostToolBatch")), .silent)
        XCTAssertEqual(state?.phase, .asking)
        XCTAssertEqual(state?.title, "Refactor the billing API")
        XCTAssertEqual(state?.name, "code-a6")
        XCTAssertEqual(state?.guarded, true)

        try answer(.yes)
        guard case .addContext(let ev, let text) = runner.handle(event("PostToolBatch")) else { return XCTFail("expected delivery") }
        XCTAssertEqual(ev, "PostToolBatch")
        XCTAssertTrue(text.contains("they clicked Yes on its popup when this session reached 310k tokens"))
        XCTAssertTrue(text.contains(Config.defaultMessage))
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(runner.handle(event("PostToolBatch")), .silent)

        // The step's added context lands in the transcript: confirmed.
        transcript.append(Line.attachment(text), Line.context(312_000))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertNotNil(state?.confirmedAt)
    }

    func testSubagentEventsAreIgnoredEntirely() {
        transcript.append(Line.context(310_000))
        XCTAssertEqual(runner.handle(event("PostToolBatch", agent: "task-7")), .silent)
        XCTAssertNil(state)
    }

    func testAutomatedAndTerminalLessSessionsAreOnlyTracked() {
        transcript.append(Line.context(310_000))
        registry.set(RegistryEntry(pid: claude, sessionId: sid, kind: "interactive", entrypoint: "sdk-cli"))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.tokens, 310_000)
        XCTAssertEqual(state?.phase, .watching)
        XCTAssertEqual(state?.guarded, false)

        registry.set(RegistryEntry(pid: claude, sessionId: sid, kind: "interactive", entrypoint: "cli"))
        probe.set(claude, ProcessIdentity(start: start, hasTTY: false))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.guarded, false)
    }

    func testIdleSessionWaitsInTheBackgroundAndWakesOnYes() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        XCTAssertEqual(state?.phase, .asking)
        XCTAssertEqual(state?.waiterToken, token)

        let result = startWaiter(token: token)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNil(result.value, "still waiting for an answer")
        try answer(.yes)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertTrue(out.text?.contains(Config.defaultMessage) ?? false)
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(state?.sentVia, .wake)
        XCTAssertNil(state?.waiterToken)
    }

    /// Seen live: Compact Now on an idle session below the ask threshold sat queued until
    /// you typed again, because no waiter was left behind outside a question or a Wait.
    func testCompactNowWakesAnIdleSessionBelowTheThreshold() throws {
        transcript.append(Line.context(120_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("every turn leaves a waiter") }
        XCTAssertEqual(state?.phase, .watching)

        let result = startWaiter(token: token)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNil(result.value, "nothing to send yet")
        try answer(.yes, from: .menu)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertTrue(out.text?.contains("Compact Now") ?? false)
        XCTAssertEqual(state?.sendReason, .manual)
        XCTAssertEqual(state?.sentVia, .wake)

        // The woken turn ends: the next waiter is ready for another send.
        transcript.append(Line.context(121_000))
        guard case .wait = runner.handle(event("Stop")) else { return XCTFail("expected the next waiter") }
    }

    func testCompactNowWakesAnIdleSessionWhileOff() throws {
        try Config(enabled: false).save(paths)
        transcript.append(Line.context(350_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("Off still leaves a waiter") }
        XCTAssertEqual(state?.phase, .watching, "Off: no question")

        let result = startWaiter(token: token)
        try answer(.yes, from: .menu)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertEqual(state?.sentVia, .wake)
    }

    func testUnguardedSessionsLeaveNoWaiter() {
        transcript.append(Line.context(120_000))
        registry.set(RegistryEntry(pid: claude, sessionId: sid, kind: "interactive", entrypoint: "sdk-cli"))
        XCTAssertEqual(runner.handle(event("Stop")), .silent, "automated sessions must exit right away")
    }

    func testWaitAnswerKeepsTheWaiterAndTheLaterThresholdSendsAtTheNextStep() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        let result = startWaiter(token: token)
        try answer(.later)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(state?.phase, .later)
        XCTAssertNil(result.value, "keeps waiting in case of Compact Now")

        // Work resumes; the next Stop replaces the waiter, and 500k sends at a step.
        transcript.append(Line.context(420_000))
        _ = runner.handle(event("PostToolBatch"))
        transcript.append(Line.context(505_000))
        guard case .addContext = runner.handle(event("PostToolBatch")) else { return XCTFail("expected the automatic send") }
        XCTAssertEqual(state?.sendReason, .later)
        XCTAssertNil(result.value, "stays until the turn's Stop replaces it")
        guard case .wait = runner.handle(event("Stop")) else { return XCTFail("expected a fresh waiter") }
        XCTAssertEqual(try XCTUnwrap(result.wait(5)).exitCode, 0, "replaced")
    }

    func testYesWhileATurnRunsIsLeftForItsNextStepNotWokenMidTurn() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        let result = startWaiter(token: token)
        // You type again: the old waiter is still alive while the new turn runs.
        setStatus("busy")
        try answer(.yes)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNil(result.value, "a wake now would land inside a tool result")
        XCTAssertEqual(state?.phase, .queued, "the waiter records the answer")

        guard case .addContext = runner.handle(event("PostToolBatch")) else { return XCTFail("expected the step delivery") }
        XCTAssertEqual(state?.sentVia, .step)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNil(result.value, "sent, so nothing to wake; it stays until the turn's Stop replaces it")
        setStatus("idle")
        guard case .wait = runner.handle(event("Stop")) else { return XCTFail("expected a fresh waiter") }
        XCTAssertEqual(try XCTUnwrap(result.wait(5)).exitCode, 0, "replaced")
    }

    func testYesHeldForABusyTurnWakesOnceItEndsWithoutAStop() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        let result = startWaiter(token: token)
        setStatus("waiting")
        try answer(.yes)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNil(result.value, "blocked on a permission prompt is still mid-turn")
        // Esc ends the turn without a Stop event.
        setStatus("idle")
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertEqual(state?.sentVia, .wake)
    }

    func testYesWakesASessionWithACommandRunningInTheBackground() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        let result = startWaiter(token: token)
        setStatus("shell")
        try answer(.yes)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2, "between turns: the wake starts a new one")
        XCTAssertEqual(state?.sentVia, .wake)
    }

    func testYesWakesASessionWhoseAgentsRunBetweenTurns() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        mod.turn(ModTurn(sessionId: sid, active: false))
        clock.advance(3)
        setStatus("busy")
        let result = startWaiter(token: token)
        try answer(.yes)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertEqual(state?.sentVia, .wake)
    }

    func testYesWaitsOutATurnThatStartedWhileAgentsRun() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        // A background agent's result started a new turn.
        mod.turn(ModTurn(sessionId: sid, active: true))
        clock.advance(3)
        setStatus("busy")
        let result = startWaiter(token: token)
        try answer(.yes)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNil(result.value, "a wake now would land inside a tool result")
        mod.turn(ModTurn(sessionId: sid, active: false))
        clock.advance(3)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2, "the turn ended; its agents still run")
    }

    func testTheNewestWaiterWins() {
        transcript.append(Line.context(310_000))
        guard case .wait(let first) = runner.handle(event("Stop")) else { return XCTFail() }
        let result = startWaiter(token: first)
        guard case .wait(let second) = runner.handle(event("Stop")) else { return XCTFail() }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(result.wait(5)?.exitCode, 0)
        XCTAssertEqual(state?.waiterToken, second)
    }

    func testWaiterNeverWakesADifferentConversationInTheSameProcess() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail() }
        let result = startWaiter(token: token)
        // /clear: same Claude process, new session id.
        registry.set(RegistryEntry(pid: claude, sessionId: "99999999-0000-0000-0000-000000000000", kind: "interactive", entrypoint: "cli"))
        try answer(.yes)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertNil(out.text)
        XCTAssertEqual(state?.phase, .queued, "kept for this conversation's next run")
    }

    func testWaiterExitsWhenClaudeQuits() {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail() }
        let result = startWaiter(token: token)
        probe.set(claude, nil)
        XCTAssertEqual(result.wait(5)?.exitCode, 0)
    }

    func testWaiterExitsWhenTheSessionEnds() {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail() }
        let result = startWaiter(token: token)
        _ = runner.handle(event("SessionEnd"))
        XCTAssertEqual(result.wait(5)?.exitCode, 0)
        XCTAssertEqual(state?.ended, true)
    }

    func testWaiterGivesUpAtItsDeadline() {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail() }
        let result = startWaiter(token: token, maxDuration: 0.2)
        XCTAssertEqual(result.wait(5)?.exitCode, 0)
        XCTAssertNil(state?.waiterToken)
    }

    func testYesWithASendAlreadyQueuedWakesStraightFromStop() throws {
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        try answer(.yes)
        guard case .wake(let text) = runner.handle(event("Stop")) else { return XCTFail("expected a wake") }
        XCTAssertTrue(text.contains(Config.defaultMessage))
    }

    func testCompactingReArmsTheSession() {
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.phase, .asking)
        transcript.append(Line.compaction(pre: 311_000, post: 24_000))
        _ = runner.handle(event("SessionStart", source: "compact"))
        XCTAssertEqual(state?.phase, .watching)
        XCTAssertEqual(state?.tokens, 24_000)
        XCTAssertEqual(state?.lastCompaction?.interruptedPhase, .asking)
    }

    /// Seen live: Claude Code runs SessionStart(compact) before it writes the compaction record.
    func testCompactionRecordWrittenAfterSessionStartStillReArms() throws {
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.phase, .asking)

        _ = runner.handle(event("SessionStart", source: "compact"))
        XCTAssertEqual(state?.phase, .watching, "must not ask again at the old size")
        XCTAssertEqual(state?.tokens, 0)
        XCTAssertEqual(state?.lastCompaction?.preTokens, 310_000)
        XCTAssertEqual(state?.lastCompaction?.interruptedPhase, .asking)

        transcript.append(Line.compaction(pre: 310_500, post: 13_036, trigger: "manual"))
        _ = runner.handle(event("Stop"))
        let s = try XCTUnwrap(state)
        XCTAssertEqual(s.phase, .watching)
        XCTAssertEqual(s.tokens, 13_036)
        XCTAssertFalse(s.awaitingCompactionRecord)
        XCTAssertEqual(s.lastCompaction?.trigger, "manual")
        XCTAssertEqual(s.lastCompaction?.postTokens, 13_036)
        XCTAssertEqual(s.lastCompaction?.interruptedPhase, .asking, "recorded once, not overwritten")
        XCTAssertEqual(s.cycle, 1)
    }

    func testResumeUsesTheReportedContextSize() {
        _ = runner.handle(event("SessionStart", source: "resume", contextTokens: 333_000))
        XCTAssertEqual(state?.tokens, 333_000)
        XCTAssertEqual(state?.phase, .asking)
    }

    func testOffKeepsTrackingButNeverAsks() throws {
        try Config(enabled: false).save(paths)
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.tokens, 310_000)
        XCTAssertEqual(state?.phase, .watching)
        guard case .wait = runner.handle(event("Stop")) else { return XCTFail("Off still leaves a waiter, for Compact Now") }
        XCTAssertEqual(state?.phase, .watching, "and the waiter doesn't ask either")
    }

    func testCorruptStateIsRebuilt() throws {
        try paths.ensureDirectories()
        try Data("{not json".utf8).write(to: paths.stateFile(sid))
        transcript.append(Line.context(120_000))
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.tokens, 120_000)
    }

    func testCatalogShowsLiveSessionsAndPendingAnswers() throws {
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        try answer(.later)
        var info = try XCTUnwrap(SessionCatalog.load(paths, registry: registry, probe: probe).first)
        XCTAssertTrue(info.isLive)
        XCTAssertEqual(info.effectivePhase, .later)
        XCTAssertEqual(info.title, "code-a6", "no AI title yet: the session name stands in")
        XCTAssertEqual(info.subtitle, "/Users/x/code")

        transcript.append(Line.title("Fix the build"))
        _ = runner.handle(event("PostToolBatch"))
        info = try XCTUnwrap(SessionCatalog.load(paths, registry: registry, probe: probe).first)
        XCTAssertEqual(info.title, "Fix the build")
        XCTAssertEqual(info.subtitle, "code-a6 · /Users/x/code")

        registry.set(RegistryEntry(pid: claude, sessionId: "someone-else", kind: "interactive", entrypoint: "cli"))
        XCTAssertEqual(SessionCatalog.load(paths, registry: registry, probe: probe).first?.isLive, false)
    }

    func testCatalogTellsATurnFromBackgroundWork() throws {
        transcript.append(Line.context(120_000))
        _ = runner.handle(event("Stop"))
        setStatus("busy")
        XCTAssertEqual(SessionCatalog.load(paths, registry: registry, probe: probe).first?.activity, .busy)
        try TurnRecord(active: false, at: Date().addingTimeInterval(-10)).save(for: sid, paths)
        let info = try XCTUnwrap(SessionCatalog.load(paths, registry: registry, probe: probe).first)
        XCTAssertEqual(info.activity, .background(BackgroundWork()))
        XCTAssertTrue(info.isIdle, "a wake starts a new turn")
    }

    func testPruningRemovesTheTurnRecordToo() throws {
        transcript.append(Line.context(120_000))
        _ = runner.handle(event("Stop"))
        mod.turn(ModTurn(sessionId: sid, active: false))
        probe.set(claude, nil)
        let sessions = SessionCatalog.load(paths, registry: registry, probe: probe)
        SessionCatalog.prune(paths, sessions: sessions, olderThan: 60, now: Date().addingTimeInterval(3_600), probe: probe)
        XCTAssertNil(state)
        XCTAssertNil(TurnRecord.load(sid, paths))
    }
}

/// A result filled in from another thread.
final class XCTestExpectation_Result: @unchecked Sendable {
    private let lock = NSCondition()
    private var result: HookRunner.WaiterResult?

    func finish(_ r: HookRunner.WaiterResult) {
        lock.lock()
        result = r
        lock.broadcast()
        lock.unlock()
    }

    var value: HookRunner.WaiterResult? {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func wait(_ seconds: TimeInterval) -> HookRunner.WaiterResult? {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while result == nil, lock.wait(until: deadline) {}
        return result
    }
}
