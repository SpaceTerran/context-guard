import XCTest
@testable import ContextGuardCore

/// A Codex session through `CodexRunner`, against real files: the rollout as Codex writes it and
/// the thread as the app server reports it.
final class CodexRunnerTests: XCTestCase {
    let dir = TempDir()
    let clock = TestClock()
    let id = CodexLine.thread
    var paths: Paths!
    var log: Transcript!
    var status = "idle"
    var attached: Bool? = true

    override func setUp() {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        log = Transcript(dir, name: "rollout-\(CodexLine.thread).jsonl")
        log.append(CodexLine.meta())
    }

    var runner: CodexRunner {
        let clock = self.clock
        return CodexRunner(paths: paths, clock: { clock.now })
    }

    var thread: CodexThreadLook {
        CodexThreadLook(threadId: id, path: log.path, cwd: "/Users/demo/code", name: "Settings screen", status: status,
                        attached: attached)
    }

    var state: SessionState? { SessionState.load(id, paths) }

    @discardableResult
    func tick() -> CodexCommand { runner.tick(thread) }

    func configure(_ change: (inout Config) -> Void = { _ in }) throws {
        var c = Config()
        c.enabledAt = clock.now.addingTimeInterval(-3_600)
        change(&c)
        try c.save(paths)
    }

    /// Makes the rollout look untouched for `seconds`.
    func settle(_ seconds: TimeInterval = 5) throws {
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-seconds)], ofItemAtPath: log.path)
    }

    func answer(_ action: Answer.Action, from source: Answer.Source = .popup) throws {
        try Answer(cycle: state?.cycle ?? 0, action: action, source: source, at: clock.now).save(for: id, paths)
    }

    /// A session at 160k (62% of 258.4k) that you said Yes to, with the save message sent and in its
    /// rollout. Returns the save message's tag.
    func askAndSend() throws -> String {
        try configure()
        log.append(CodexLine.turn("Add a settings screen", reply: "Added it.", tokens: 160_000))
        try settle()
        tick()
        XCTAssertEqual(state?.phase, .asking)
        try answer(.yes)
        guard case .deliver(let nonce, let text) = tick() else {
            XCTFail("expected the save message")
            return ""
        }
        XCTAssertEqual(text, "\(Config.defaultMessage) [\(nonce)]")
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(state?.sentVia, .turn)
        status = "active"
        log.append(CodexLine.taskStarted(), CodexLine.prompt(text))
        tick()
        XCTAssertNotNil(state?.confirmedAt)
        return nonce
    }

    func testANewTerminalSessionIsWatchedOnceItsWindowIsKnown() throws {
        try configure()
        tick()
        let s = try XCTUnwrap(state)
        XCTAssertEqual(s.hostKind, .codex)
        XCTAssertEqual(s.codex?.terminal, true)
        XCTAssertEqual(s.title, "Settings screen")
        XCTAssertFalse(s.guarded, "no window yet")

        log.append(CodexLine.turn("hi", reply: "hello", tokens: 21_449))
        tick()
        XCTAssertEqual(state?.codex?.window, 258_400)
        XCTAssertTrue(state?.guarded ?? false)
        XCTAssertEqual(state?.tokens, 21_449)
        XCTAssertEqual(state?.codex?.model, "gpt-6-luna")
    }

    func testOtherCodexThreadsAreOnlyTracked() throws {
        try configure()
        log = Transcript(dir, name: "desktop.jsonl")
        log.append(CodexLine.meta(originator: "Codex Desktop"))
        log.append(CodexLine.turn("big", reply: "ok", tokens: 200_000))
        tick()
        XCTAssertEqual(state?.codex?.terminal, false)
        XCTAssertFalse(state?.guarded ?? true)
        XCTAssertEqual(state?.phase, .watching, "never asked")
    }

    func testItsOwnHelpersAreLeftOut() {
        XCTAssertEqual(runner.tick(CodexThreadLook(threadId: id, status: "active", ephemeral: true)), .none)
        XCTAssertNil(state)
    }

    func testItAsksAtItsShareOfTheWindowAndSendsOnlyBetweenTurns() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 150_000))
        tick()
        XCTAssertEqual(state?.phase, .watching, "below 60%")
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        tick()
        XCTAssertEqual(state?.phase, .asking)
        XCTAssertEqual(state?.askedTokens, 160_000)

        try answer(.yes)
        status = "active"
        XCTAssertEqual(tick(), .none, "not into a running turn")
        XCTAssertEqual(state?.phase, .queued)
        status = "idle"
        guard case .deliver = tick() else { return XCTFail("sent once the turn ends") }
        XCTAssertEqual(tick(), .none, "sent once")
    }

    func testNothingGoesToASessionNoTerminalShows() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        attached = false
        tick()
        try answer(.yes)
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(state?.phase, .queued)
        attached = nil
        guard case .deliver = tick() else { return XCTFail("sent when it can't be told") }
    }

    func testFromTheSaveMessageToContinue() throws {
        let nonce = try askAndSend()
        log.append(CodexLine.toolCall(), CodexLine.toolOutput("main -> main"), CodexLine.reply("Pushed and saved. Ready for compaction."),
                   CodexLine.tokens(165_000), CodexLine.taskComplete())
        XCTAssertEqual(tick(), .none, "busy until the app server says idle")
        status = "idle"
        try settle()
        guard case .judge(let n, let mark, let prompt) = tick() else { return XCTFail("expected the judge to be asked") }
        XCTAssertEqual(n, nonce)
        XCTAssertTrue(prompt.hasPrefix("You are checking on a Codex session"))
        XCTAssertTrue(prompt.contains("Codex: Pushed and saved. Ready for compaction."))
        XCTAssertTrue(prompt.contains("Tool result: Script completed\nmain -> main"))

        XCTAssertTrue(runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark,
                                              text: #"{"verdict":"ready","reason":"pushed and saved"}"#)))
        XCTAssertEqual(tick(), .compact(nonce: nonce))
        XCTAssertEqual(state?.followUp?.stage, .compacting)
        XCTAssertEqual(tick(), .none, "compacting once")

        status = "active"
        log.append([CodexLine.taskStarted()] + CodexLine.compacted() + [CodexLine.tokens(18_081), CodexLine.taskComplete()])
        tick()
        XCTAssertEqual(state?.followUp?.stage, .continuing)
        XCTAssertEqual(state?.followUp?.tokensBefore, 165_000)
        XCTAssertEqual(state?.followUp?.tokensAfter, 18_081)
        XCTAssertEqual(state?.phase, .watching, "the next cycle starts")
        XCTAssertEqual(state?.tokens, 18_081)

        status = "idle"
        try settle()
        XCTAssertEqual(tick(), .continue(nonce: nonce, text: "continue now"))
        XCTAssertEqual(state?.followUp?.stage, .done)
    }

    func testTheSizeAfterACompactionWrittenLater() throws {
        let nonce = try askAndSend()
        log.append(CodexLine.reply("Ready."), CodexLine.taskComplete())
        status = "idle"
        try settle()
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("expected the judge") }
        runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: #"{"verdict":"ready"}"#))
        XCTAssertEqual(tick(), .compact(nonce: nonce))

        log.append([CodexLine.taskStarted()] + CodexLine.compacted())
        tick()
        XCTAssertEqual(state?.tokens, 0, "unknown, not the size before")
        XCTAssertEqual(state?.phase, .watching)
        log.append(CodexLine.tokens(17_500), CodexLine.taskComplete())
        tick()
        XCTAssertEqual(state?.tokens, 17_500)
        XCTAssertEqual(state?.lastCompaction?.postTokens, 17_500)
        XCTAssertEqual(state?.followUp?.tokensAfter, 17_500)
        XCTAssertFalse(state?.awaitingCompactionRecord ?? true)
    }

    func testEscDuringTheCompactionStopsIt() throws {
        let nonce = try askAndSend()
        log.append(CodexLine.reply("Ready."), CodexLine.taskComplete())
        status = "idle"
        try settle()
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("expected the judge") }
        runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: #"{"verdict":"ready"}"#))
        XCTAssertEqual(tick(), .compact(nonce: nonce))

        clock.advance(2)
        log.append(CodexLine.taskStarted(at: ISO8601DateFormatter().string(from: clock.now)), CodexLine.turnAborted())
        try settle()
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(state?.followUp?.stage, .stopped)
        XCTAssertEqual(state?.followUp?.note, "you stopped the compaction")
        XCTAssertEqual(tick(), .none, "the ready verdict doesn't compact again")
    }

    func testAnInterruptedTurnBeforeTheCompactionIsNotTheCompaction() throws {
        let nonce = try askAndSend()
        log.append(CodexLine.reply("Ready."), CodexLine.turnAborted())
        status = "idle"
        try settle()
        guard case .judge(_, let mark, _) = tick() else { return XCTFail("expected the judge") }
        runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: #"{"verdict":"ready"}"#))
        XCTAssertEqual(tick(), .compact(nonce: nonce))
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(state?.followUp?.stage, .compacting)
    }

    func testARefusedSendIsSentAgainWithoutUsingTheResend() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        tick()
        try answer(.yes)
        guard case .deliver(let nonce, _) = tick() else { return XCTFail("expected the save message") }
        runner.refused(threadId: id, nonce: nonce)
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertEqual(state?.resendCount, 0)
        guard case .deliver(let again, _) = tick() else { return XCTFail("sent again") }
        XCTAssertNotEqual(again, nonce)
        runner.refused(threadId: id, nonce: nonce)
        XCTAssertEqual(state?.phase, .sent, "a refusal of the old one doesn't touch the new one")
    }

    func testASendThatNeverShowsUpIsSentOnceMore() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        tick()
        try answer(.yes)
        guard case .deliver = tick() else { return XCTFail("expected the save message") }
        try settle(40)
        clock.advance(31)
        guard case .deliver = tick() else { return XCTFail("idle and quiet for 30 s with no turn: lost") }
        XCTAssertEqual(state?.resendCount, 1)
        clock.advance(40)
        try settle(40)
        XCTAssertEqual(tick(), .none, "only once")
    }

    func testTurnsEndingWithoutItCountAsStops() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        tick()
        try answer(.yes)
        guard case .deliver = tick() else { return XCTFail("expected the save message") }
        func turnEnds() -> CodexCommand {
            status = "active"
            log.append(CodexLine.taskStarted(at: ISO8601DateFormatter().string(from: clock.now)))
            tick()
            status = "idle"
            return tick()
        }
        XCTAssertEqual(turnEnds(), .none)
        XCTAssertEqual(state?.stopsSinceSent, 1)
        guard case .deliver = turnEnds() else { return XCTFail("two turns ended without it: sent once more, right away") }
        XCTAssertEqual(state?.resendCount, 1)
        XCTAssertEqual(turnEnds(), .none)
        XCTAssertEqual(turnEnds(), .none, "only once")
    }

    func testAClosedSessionEndsAfterAWhileAndOpensAgainOnResume() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        tick()
        status = "notLoaded"
        tick()
        clock.advance(60)
        tick()
        XCTAssertFalse(state?.ended ?? true, "the app server may be restarting")
        clock.advance(31)
        tick()
        XCTAssertTrue(state?.ended ?? false)
        XCTAssertEqual(runner.openSessions().count, 0)
        status = "idle"
        tick()
        XCTAssertFalse(state?.ended ?? true)
        XCTAssertNil(state?.codex?.unloadedAt)
    }

    func testNotWatchingStopsAskingButCompactNowStillWorks() throws {
        try configure()
        tick()
        try Mute.set(true, for: XCTUnwrap(state), paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codexMuteFile(id).path))
        log.append(CodexLine.turn("two", reply: "ok", tokens: 200_000))
        tick()
        XCTAssertEqual(state?.phase, .watching)
        try answer(.yes, from: .menu)
        guard case .deliver = tick() else { return XCTFail("Compact Now is your own request") }
        try Mute.set(false, for: XCTUnwrap(state), paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexMuteFile(id).path))
    }

    func testAClaudeCodeSessionIsNeverTouched() throws {
        try paths.ensureDirectories()
        var s = SessionState(sessionId: id, now: clock.now)
        s.guarded = true
        s.phase = .queued
        try s.save(paths)
        let before = try Data(contentsOf: paths.stateFile(id))
        XCTAssertEqual(tick(), .none)
        runner.refused(threadId: id, nonce: "cg-1")
        XCTAssertFalse(runner.report(ModReport(sessionId: id, nonce: "cg-1", kind: .judged, mark: 1, text: #"{"verdict":"ready"}"#)))
        XCTAssertEqual(try Data(contentsOf: paths.stateFile(id)), before)
    }

    func testCodexCompactingByItselfBeforeItSaved() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        tick()
        XCTAssertEqual(state?.phase, .asking)
        log.append([CodexLine.taskStarted(), CodexLine.prompt("keep going"), CodexLine.toolCall(), CodexLine.tokens(240_000)]
                   + CodexLine.compacted() + [CodexLine.tokens(20_000)])
        tick()
        XCTAssertEqual(state?.lastCompaction?.trigger, "auto")
        XCTAssertEqual(state?.lastCompaction?.interruptedPhase, .asking)
        XCTAssertEqual(state?.lastCompaction?.preTokens, 240_000)
        XCTAssertEqual(state?.phase, .watching)
        XCTAssertEqual(state?.tokens, 20_000)
    }

    func testTheSessionListSeesItLiveOnlyWhileTheLinkIsUp() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        tick()
        func info() throws -> SessionInfo {
            try XCTUnwrap(SessionCatalog.load(paths, registry: FakeRegistry(), probe: FakeProbe()).first { $0.id == id })
        }
        XCTAssertFalse(try info().isLive, "no link")
        try CodexLinkStatus(at: Date(), connected: true).save(paths)
        XCTAssertTrue(try info().isLive)
        XCTAssertTrue(try info().reachableNow)
        XCTAssertEqual(try info().host, .codex)
        try CodexLinkStatus(at: Date().addingTimeInterval(-60), connected: true).save(paths)
        XCTAssertFalse(try info().isLive, "a link that stopped writing is gone")
    }
}
