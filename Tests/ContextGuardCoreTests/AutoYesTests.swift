import XCTest
@testable import ContextGuardCore

/// No answer within `autoYesSeconds` counts as Yes; "Watch This Session" off stops all of it.
final class AutoYesRuleTests: XCTestCase {
    let now = Date()

    var config: Config {
        var c = Config()
        c.enabledAt = now.addingTimeInterval(-3_600)
        return c
    }

    func asking(askedAgo: TimeInterval) -> SessionState {
        var s = SessionState.guarded(310_000, phase: .asking, cycle: 1)
        s.askedAt = now.addingTimeInterval(-askedAgo)
        s.askedTokens = 310_000
        return s
    }

    func testAnUnansweredQuestionCountsAsYesAfterTheCountdown() {
        var s = asking(askedAgo: 59)
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .asking)
        s = asking(askedAgo: 60)
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.sendReason, .yes)
        XCTAssertEqual(s.askTimedOut, true)

        let text = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-t", now: now)
        XCTAssertEqual(text?.contains("its popup asked them when this session reached 310k tokens, and they set it to send by itself when they don't answer within 60 seconds"), true)
        XCTAssertEqual(text?.contains("clicked Yes"), false)
    }

    func testTheCountdownStartsOverWhenContextGuardIsTurnedBackOn() {
        var c = config
        c.enabledAt = now.addingTimeInterval(-10)
        var s = asking(askedAgo: 3_600)
        XCTAssertEqual(Engine.autoYesDeadline(s, config: c, now: now), now.addingTimeInterval(50))
        Engine.advance(&s, config: c, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testTurningOnStampsTheTimeButStayingOnDoesNot() {
        var c = Config()
        c.setEnabled(false, now: now)
        XCTAssertNil(c.enabledAt)
        c.setEnabled(true, now: now)
        XCTAssertEqual(c.enabledAt, now)
        c.setEnabled(true, now: now.addingTimeInterval(500))
        XCTAssertEqual(c.enabledAt, now, "already on")
    }

    /// A config from before the countdown existed holds it until the app stamps one, so updating
    /// never answers a question that has been up for hours.
    func testAConfigWithoutATurnedOnTimeNeverCountsDown() {
        var c = config
        c.enabledAt = nil
        var s = asking(askedAgo: 3_600)
        Engine.advance(&s, config: c, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testZeroSecondsMeansWaitForAnAnswer() {
        var c = config
        c.autoYesSeconds = 0
        var s = asking(askedAgo: 3_600)
        XCTAssertNil(Engine.autoYesDeadline(s, config: c, now: now))
        Engine.advance(&s, config: c, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testNoCountdownWhileOff() {
        var c = config
        c.enabled = false
        var s = asking(askedAgo: 3_600)
        Engine.advance(&s, config: c, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testClickingYesInTimeIsAPlainYes() {
        var s = asking(askedAgo: 5)
        Engine.apply(Answer(cycle: 1, action: .yes, source: .popup, at: now), to: &s)
        Engine.advance(&s, config: config, now: now)
        XCTAssertNil(s.askTimedOut)
        let text = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-t", now: now)
        XCTAssertEqual(text?.contains("they clicked Yes on its popup"), true)
    }

    func testATimedOutSendKeepsItsWordingWhenResent() {
        var s = asking(askedAgo: 61)
        Engine.advance(&s, config: config, now: now)
        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-1", now: now)
        Engine.noteStop(&s)
        Engine.noteStop(&s)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.askTimedOut, true)
    }

    func testPassingTheLaterThresholdWhileOffAsksAgainWithAFreshCountdown() {
        var s = SessionState.guarded(510_000, phase: .later, cycle: 1)
        s.askedAt = now.addingTimeInterval(-7_200)
        var off = config
        off.enabled = false
        Engine.advance(&s, config: off, now: now)
        XCTAssertEqual(s.phase, .asking)
        XCTAssertEqual(s.askedAt, now)
    }

    func testAnUnwatchedSessionDropsItsQuestionAndAsksAgainOnceWatched() {
        var s = asking(askedAgo: 3_600)
        Engine.advance(&s, config: config, watched: false, now: now)
        XCTAssertEqual(s.phase, .watching)
        XCTAssertNil(s.askedAt)
        Engine.advance(&s, config: config, watched: false, now: now)
        XCTAssertEqual(s.phase, .watching, "never asks while unwatched")

        Engine.advance(&s, config: config, watched: true, now: now)
        XCTAssertEqual(s.phase, .asking)
        XCTAssertEqual(s.cycle, 2)
        XCTAssertEqual(s.askedAt, now, "a fresh countdown")
    }

    func testAnUnwatchedSessionDropsAWaitAndNeverSendsAtTheLaterThreshold() {
        var s = SessionState.guarded(520_000, phase: .later, cycle: 1)
        Engine.advance(&s, config: config, watched: false, now: now)
        XCTAssertEqual(s.phase, .watching)
        XCTAssertNil(Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-x", now: now))
    }

    func testCompactNowStillWorksUnwatched() {
        var s = SessionState.guarded(120_000)
        Engine.apply(Answer(cycle: 0, action: .yes, source: .menu, at: now), to: &s)
        Engine.advance(&s, config: config, watched: false, now: now)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertNotNil(Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-m", now: now))
    }

    func testNoCountdownForAnUnwatchedSession() {
        XCTAssertNil(Engine.autoYesDeadline(asking(askedAgo: 3_600), config: config, watched: false, now: now))
    }

    func testOldConfigFileReadsWithTheNewDefaults() throws {
        let data = Data(#"{"schemaVersion":1,"enabled":true,"askAt":250000,"laterAt":400000,"message":"save"}"#.utf8)
        let c = try FileIO.decoder().decode(Config.self, from: data)
        XCTAssertEqual(c.askAt, 250_000)
        XCTAssertEqual(c.autoYesSeconds, 60)
        XCTAssertEqual(c.continueMessage, "continue now")
        XCTAssertNil(c.enabledAt)
    }

    /// The "Compact by itself" switch is gone: a file that still has it loads, and saving drops it.
    func testAConfigWithTheOldCompactSwitchLoadsAndSavesWithoutIt() throws {
        let data = Data(#"{"schemaVersion":1,"enabled":true,"autoCompact":false,"continueMessage":"go on"}"#.utf8)
        let c = try FileIO.decoder().decode(Config.self, from: data)
        XCTAssertEqual(c.continueMessage, "go on")
        let saved = try XCTUnwrap(String(data: try FileIO.encoder().encode(c), encoding: .utf8))
        XCTAssertFalse(saved.contains("autoCompact"))
    }

    func testSettingsAreKeptInRange() {
        var c = Config()
        c.autoYesSeconds = -5
        c.continueMessage = "  "
        XCTAssertEqual(c.normalized.autoYesSeconds, 0)
        XCTAssertEqual(c.normalized.continueMessage, "continue now")
        c.autoYesSeconds = 99_999
        XCTAssertEqual(c.normalized.autoYesSeconds, 3_600)
    }
}

/// The same rules through the hooks and the background waiter, against real files.
final class AutoYesHookTests: HookTestCase {
    func testABusySessionSendsAtTheNextStepOnceTheCountdownEnds() throws {
        try configure()
        transcript.append(Line.context(310_000))
        setStatus("busy")
        XCTAssertEqual(runner.handle(event("PostToolBatch")), .silent)
        XCTAssertEqual(state?.phase, .asking)

        clock.advance(30)
        XCTAssertEqual(runner.handle(event("PostToolBatch")), .silent)
        clock.advance(31)
        guard case .addContext(_, let text) = runner.handle(event("PostToolBatch")) else { return XCTFail("expected the save message") }
        XCTAssertTrue(text.contains("don't answer within 60 seconds"))
        XCTAssertEqual(state?.askTimedOut, true)
    }

    func testAnIdleSessionIsWokenWhenTheCountdownEnds() throws {
        // State files keep whole seconds, so a countdown can end up to a second early: 2 s here.
        try configure { $0.autoYesSeconds = 2 }
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        XCTAssertEqual(state?.phase, .asking)

        let result = startWaiter(token: token)
        usleep(300_000)
        XCTAssertNil(result.value, "still counting down")
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertTrue(out.text?.contains("don't answer within 2 seconds.") ?? false)
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(state?.sentVia, .wake)
    }

    func testStoppingWatchingDropsTheQuestionAndKeepsTheWaiter() throws {
        try configure { $0.autoYesSeconds = 1 }
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        let result = startWaiter(token: token)
        try watch(false)
        usleep(1_500_000)
        XCTAssertNil(result.value, "no countdown once unwatched; it stays for Compact Now")
        XCTAssertEqual(state?.phase, .watching, "the question went away without waiting for a turn")

        try answer(.yes, from: .menu)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 2, "Compact Now still reaches it")
    }

    func testWatchingAgainAsksAgainAtTheNextEvent() throws {
        try configure()
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        try watch(false)
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.phase, .watching)
        try watch(true)
        _ = runner.handle(event("PostToolBatch"))
        XCTAssertEqual(state?.phase, .asking)
        XCTAssertEqual(state?.cycle, 2)
    }

    /// The mark belongs to the Claude process, so it lasts through /clear (a new session id).
    func testTheMarkFollowsTheTabNotTheSession() throws {
        try configure()
        transcript.append(Line.context(310_000))
        _ = runner.handle(event("PostToolBatch"))
        try watch(false)

        let other = "99999999-2222-3333-4444-555555555555"
        registry.set(RegistryEntry(pid: claude, sessionId: other, kind: "interactive", entrypoint: "cli", status: "idle"))
        let t2 = Transcript(dir, name: "t2.jsonl")
        t2.append(Line.context(320_000))
        _ = runner.handle(HookInput(event: "PostToolBatch", sessionId: other, transcriptPath: t2.path))
        XCTAssertEqual(SessionState.load(other, paths)?.phase, .watching)
        XCTAssertEqual(SessionCatalog.load(paths, registry: registry, probe: probe).first { $0.id == other }?.muted, true)
    }

    func testClosedTabsLoseTheirMark() throws {
        try configure()
        transcript.append(Line.context(100_000))
        _ = runner.handle(event("PostToolBatch"))
        try watch(false)
        let file = paths.muteFile(pid: claude, start: start)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        Mute.prune(paths, probe: probe)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "still running")
        probe.set(claude, nil)
        Mute.prune(paths, probe: probe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// A session that hasn't said which Claude process runs it can't be marked, and says so.
    func testStoppingWatchingAnUnknownProcessFails() throws {
        var s = SessionState(sessionId: sid, now: clock.now)
        s.claudePid = claude
        XCTAssertThrowsError(try Mute.set(true, for: s, paths)) { XCTAssertTrue($0 is Mute.UnknownProcess) }
        XCTAssertNoThrow(try Mute.set(false, for: s, paths), "watching it again has nothing to undo")
        XCTAssertFalse(Mute.isMuted(s, paths))
    }

    func testAReusedPidIsNotMuted() throws {
        try configure()
        transcript.append(Line.context(100_000))
        _ = runner.handle(event("PostToolBatch"))
        try watch(false)
        XCTAssertTrue(Mute.isMuted(pid: claude, start: start, paths))
        XCTAssertFalse(Mute.isMuted(pid: claude, start: ProcessStart(seconds: start.seconds, microseconds: 99), paths))
    }

    /// Waiters still running the previous build read the state file the new build writes, and the
    /// new build reads files the previous one wrote.
    func testStateFilesFromTheBuildBeforeStillRead() throws {
        let old = """
        {"schemaVersion":1,"sessionId":"\(sid)","tokens":310000,"updatedAt":"2026-11-04T10:00:00Z","guarded":true,
         "phase":"sent","cycle":2,"sendReason":"yes","sentNonce":"cg-old","stopsSinceSent":0,"resendCount":0,
         "awaitingCompactionRecord":false,"ended":false,"claudePid":4242}
        """
        try paths.ensureDirectories()
        try Data(old.utf8).write(to: paths.stateFile(sid))
        let s = try XCTUnwrap(state)
        XCTAssertEqual(s.phase, .sent)
        XCTAssertNil(s.followUp)
        XCTAssertNil(s.askTimedOut)

        var newer = s
        newer.askTimedOut = true
        newer.followUp = FollowUp(nonce: "cg-old", now: Date())
        try newer.save(paths)
        struct PreviousBuild: Decodable { var sessionId: String; var phase: String; var tokens: Int }
        let back = try FileIO.decoder().decode(PreviousBuild.self, from: Data(contentsOf: paths.stateFile(sid)))
        XCTAssertEqual(back.phase, "sent")
    }
}
