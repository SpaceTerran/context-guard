import XCTest
@testable import ContextGuardCore

/// The steps after a save message, as pure rules: Haiku's verdict, compacting, the continue message.
final class CompactorTests: XCTestCase {
    /// Whole seconds: the state file keeps dates to the second.
    var now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let nonce = "cg-abc"

    var config: Config {
        var c = Config()
        c.enabledAt = now.addingTimeInterval(-3_600)
        return c
    }

    /// A session whose save message reached it a moment ago.
    func askedToSave() -> SessionState {
        var s = SessionState.guarded(310_000, phase: .sent, cycle: 1)
        s.sentNonce = nonce
        s.sentAt = now.addingTimeInterval(-30)
        s.confirmedAt = now.addingTimeInterval(-20)
        s.sendReason = .yes
        return s
    }

    func conversation(_ text: String = "Claude: Pushed; ready for compaction.", mark: UInt64 = 1_000) -> Conversation {
        Conversation(text: text, mark: mark, userPrompts: 0, after: nonce)
    }

    /// Between turns and quiet; `background` is work it left running.
    func idle(_ c: Conversation? = nil, draft: Bool = false, size: UInt64 = 5_000, background: BackgroundWork? = nil) -> SessionLook {
        SessionLook(activity: background.map { .background($0) } ?? .idle, quiet: true, draft: draft,
                    conversation: c ?? conversation(), transcriptSize: size)
    }

    /// Between turns, with agents or a shell command still running in the background.
    func background(_ c: Conversation? = nil, agents: Int = 0, shells: Bool = false, size: UInt64 = 5_000) -> SessionLook {
        idle(c, size: size, background: BackgroundWork(agents: agents, shells: shells))
    }

    /// Walks a session to Haiku's "ready".
    func ready() -> SessionState {
        var s = askedToSave()
        _ = tick(&s, idle())
        _ = judged(&s, #"{"verdict":"ready","reason":"pushed"}"#)
        return s
    }

    // Each step saves the state and the next one reads it back, as each `context-guard mod` run does:
    // a field the file drops shows up here, not only in a live session.

    func tick(_ s: inout SessionState, _ look: SessionLook, config: Config? = nil, watched: Bool = true) -> ModAction {
        defer { s = saved(s) }
        return Compactor.tick(&s, config: config ?? self.config, watched: watched, look: look, now: now)
    }

    func judged(_ s: inout SessionState, _ reply: String, mark: UInt64 = 1_000) -> Bool {
        defer { s = saved(s) }
        return Compactor.apply(ModReport(sessionId: s.sessionId, nonce: nonce, kind: .judged, mark: mark, text: reply), to: &s, now: now)
    }

    func report(_ s: inout SessionState, _ kind: ModReport.Kind, error: String? = nil) {
        defer { s = saved(s) }
        Compactor.apply(ModReport(sessionId: s.sessionId, nonce: nonce, kind: kind, error: error), to: &s, now: now)
    }

    /// The state as the next run reads it from its file.
    func saved(_ s: SessionState) -> SessionState {
        do {
            return try FileIO.decoder().decode(SessionState.self, from: FileIO.encoder().encode(s))
        } catch {
            XCTFail("the state doesn't save and load: \(error)")
            return s
        }
    }

    /// Walks a session to the point where the mod is compacting it.
    func compacting() -> SessionState {
        var s = askedToSave()
        _ = tick(&s, idle())
        _ = judged(&s, #"{"verdict":"ready","reason":"pushed"}"#)
        XCTAssertEqual(tick(&s, idle()), .compact(nonce: nonce))
        return s
    }

    // MARK: Starting

    func testNothingHappensBeforeTheSaveMessageIsConfirmed() {
        var s = askedToSave()
        s.confirmedAt = nil
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertNil(s.followUp)
    }

    func testAConfirmedSaveMessageStartsAndAsksHaiku() {
        var s = askedToSave()
        guard case .judge(let n, let mark, let prompt) = tick(&s, idle()) else { return XCTFail("expected a judge") }
        XCTAssertEqual(n, nonce)
        XCTAssertEqual(mark, 1_000)
        XCTAssertTrue(prompt.contains(Config.defaultMessage))
        XCTAssertTrue(prompt.contains("Claude: Pushed; ready for compaction."))
        XCTAssertTrue(prompt.contains(#""verdict": "ready" | "working" | "needs_user""#))
        XCTAssertEqual(s.followUp?.stage, .checking)
        XCTAssertEqual(s.followUp?.nonce, nonce)
    }

    func testEveryKindOfSaveMessageIsFollowed() {
        for reason in [SendReason.yes, .later, .manual] {
            var s = askedToSave()
            s.sendReason = reason
            guard case .judge = tick(&s, idle()) else { return XCTFail("expected a judge for \(reason)") }
        }
    }

    func testAnOldSaveMessageIsLeftAlone() {
        var s = askedToSave()
        s.confirmedAt = now.addingTimeInterval(-601)
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertNil(s.followUp)
    }

    func testNoFollowUpWhenOffOrUnwatched() {
        var off = config
        off.enabled = false
        for (c, watched) in [(off, true), (config, false)] {
            var s = askedToSave()
            XCTAssertEqual(tick(&s, idle(), config: c, watched: watched), .none)
            XCTAssertNil(s.followUp)
        }
        var s = askedToSave()
        s.guarded = false
        XCTAssertEqual(tick(&s, idle()), .none)
    }

    // MARK: Judging

    func testHaikuIsAskedOnlyBetweenTurnsOnceTheTranscriptIsQuiet() {
        var s = askedToSave()
        var look = idle()
        look.activity = .busy
        XCTAssertEqual(tick(&s, look), .none, "a turn is running")
        look = idle()
        look.quiet = false
        XCTAssertEqual(tick(&s, look), .none)
        var other = idle()
        other.conversation?.after = "cg-other"
        XCTAssertEqual(tick(&s, other), .none, "a conversation read for another save message")
        XCTAssertEqual(tick(&s, idle(conversation(mark: 0))), .none, "it hasn't said anything yet")
        guard case .judge = tick(&s, idle()) else { return XCTFail("expected a judge") }
    }

    func testOneQuestionAtATime() {
        var s = askedToSave()
        guard case .judge = tick(&s, idle()) else { return XCTFail("expected a judge") }
        XCTAssertEqual(tick(&s, idle()), .none, "the first is still out")
        now += 91
        guard case .judge = tick(&s, idle()) else { return XCTFail("an abandoned question is asked again") }
    }

    func testReadyCompactsAndMarksItFirst() {
        var s = askedToSave()
        _ = tick(&s, idle())
        XCTAssertTrue(judged(&s, #"{"verdict": "ready", "reason": "pushed and saved"}"#), "tick again right away")
        XCTAssertEqual(s.followUp?.note, "pushed and saved")
        XCTAssertEqual(tick(&s, idle(size: 7_777)), .compact(nonce: nonce))
        XCTAssertEqual(s.followUp?.stage, .compacting)
        XCTAssertEqual(s.followUp?.compactAttempts, 1)
        XCTAssertEqual(s.followUp?.compactFrom, 7_777)
        XCTAssertEqual(tick(&s, idle()), .none, "never compacts twice")
    }

    func testReadyWaitsWhileThereIsADraft() {
        var s = askedToSave()
        _ = tick(&s, idle())
        _ = judged(&s, #"{"verdict":"ready","reason":"done"}"#)
        XCTAssertEqual(tick(&s, idle(draft: true)), .none)
        XCTAssertEqual(s.followUp?.stage, .draft)
        XCTAssertEqual(tick(&s, idle()), .compact(nonce: nonce), "the draft was cleared")
    }

    func testAVerdictGoesStaleWhenTheConversationMoves() {
        var s = askedToSave()
        _ = tick(&s, idle())
        _ = judged(&s, #"{"verdict":"ready","reason":"done"}"#)
        guard case .judge(_, let mark, _) = tick(&s, idle(conversation("Claude: one more push", mark: 2_000))) else {
            return XCTFail("a new line means a new verdict")
        }
        XCTAssertEqual(mark, 2_000)
    }

    func testWorkingIsLookedAtAgainAfterFiveIdleMinutes() {
        var s = askedToSave()
        _ = tick(&s, idle())
        XCTAssertFalse(judged(&s, #"{"verdict":"working","reason":"CI is still running"}"#))
        XCTAssertEqual(s.followUp?.stage, .working)
        XCTAssertEqual(s.followUp?.note, "CI is still running")
        now += 299
        XCTAssertEqual(tick(&s, idle()), .none)
        now += 1
        var look = idle()
        look.lastWrite = now.addingTimeInterval(-400)
        guard case .judge(_, _, let prompt) = tick(&s, look) else { return XCTFail("expected a second look") }
        XCTAssertTrue(prompt.contains("It has been idle for 6 minutes."))
    }

    func testStillWorkingAfterHalfAnHourGoesToYou() {
        var s = askedToSave()
        _ = tick(&s, idle())
        _ = judged(&s, #"{"verdict":"working","reason":"waiting"}"#)
        for _ in 0..<6 {
            now += 300
            guard case .judge = tick(&s, idle()) else { return XCTFail("expected another look") }
            _ = judged(&s, #"{"verdict":"working","reason":"waiting"}"#)
        }
        now += 300
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertEqual(s.followUp?.stage, .needsYou)
    }

    func testAQuestionForYouWaitsForYourAnswer() {
        var s = askedToSave()
        _ = tick(&s, idle())
        _ = judged(&s, #"{"verdict":"needs_user","reason":"asked which branch"}"#)
        XCTAssertEqual(s.followUp?.stage, .needsYou)
        now += 3_600
        XCTAssertEqual(tick(&s, idle()), .none)
        guard case .judge = tick(&s, idle(conversation("User: main\n\nClaude: pushed to main, ready", mark: 3_000))) else {
            return XCTFail("your answer moved the conversation")
        }
    }

    func testAnUnreadableAnswerIsAskedAgainLater() {
        var s = askedToSave()
        _ = tick(&s, idle())
        XCTAssertFalse(judged(&s, "I think it's probably ready!"))
        XCTAssertEqual(s.followUp?.stage, .checking)
        XCTAssertEqual(s.followUp?.judgeFailures, 1)
        XCTAssertEqual(tick(&s, idle()), .none, "backs off")
        now += 15
        guard case .judge = tick(&s, idle()) else { return XCTFail("expected a retry") }
    }

    func testHaikuFailingOverAndOverStops() {
        var s = askedToSave()
        for _ in 0..<8 {
            guard case .judge = tick(&s, idle()) else { return XCTFail("expected a judge") }
            report(&s, .judgeFailed, error: "timed out")
            now += 600
        }
        XCTAssertEqual(s.followUp?.stage, .failed)
        XCTAssertEqual(s.followUp?.note, "Haiku didn't answer (timed out)")
    }

    func testRepliesAreReadLeniently() {
        XCTAssertEqual(JudgeReply.parse("```json\n{\"verdict\": \"Needs User\", \"reason\": \"asks a question\"}\n```"),
                       JudgeReply(verdict: .needsUser, reason: "asks a question"))
        XCTAssertEqual(JudgeReply.parse(#"{"verdict":"needs-user"}"#)?.verdict, .needsUser)
        XCTAssertEqual(JudgeReply.parse(#"Sure: {"verdict":"READY","reason":""}"#), JudgeReply(verdict: .ready, reason: nil))
        XCTAssertNil(JudgeReply.parse(#"{"verdict":"maybe"}"#))
        XCTAssertNil(JudgeReply.parse("ready"))
        XCTAssertNil(JudgeReply.parse(""))
    }

    func testReportsForAnotherSaveMessageAreIgnored() {
        var s = askedToSave()
        _ = tick(&s, idle())
        let before = s
        Compactor.apply(ModReport(sessionId: s.sessionId, nonce: "cg-other", kind: .judged, mark: 1_000, text: #"{"verdict":"ready"}"#), to: &s, now: now)
        XCTAssertEqual(s, before)
    }

    // MARK: Background work

    func testBackgroundWorkDoesNotKeepHaikuFromJudging() {
        var s = askedToSave()
        guard case .judge = tick(&s, background(agents: 2)) else { return XCTFail("expected a judge") }
    }

    /// Work it left running doesn't hold it: it keeps running through the compaction, and what it
    /// brings back reaches the compacted session.
    func testReadyCompactsWithBackgroundAgentsRunning() {
        var s = ready()
        XCTAssertEqual(tick(&s, background(agents: 2, size: 9_000)), .compact(nonce: nonce))
        XCTAssertEqual(s.followUp?.stage, .compacting)
        XCTAssertEqual(s.followUp?.compactFrom, 9_000)
    }

    func testReadyCompactsWithABackgroundCommandRunning() {
        var s = ready()
        XCTAssertEqual(tick(&s, background(shells: true)), .compact(nonce: nonce))
    }

    /// A session that says it can't be ready until its agent is back is held by its own words.
    func testASessionWaitingOnItsAgentIsHeldUntilItSaysReady() {
        var s = askedToSave()
        _ = tick(&s, background(agents: 1))
        _ = judged(&s, #"{"verdict":"working","reason":"waiting for its agent's review"}"#)
        XCTAssertEqual(tick(&s, background(agents: 1)), .none)
        XCTAssertEqual(s.followUp?.stage, .working)
        // The agent reported back and the session finished saving: the conversation moved.
        let moved = conversation("Claude: the review is in and committed. Ready.", mark: 2_000)
        guard case .judge(_, let mark, _) = tick(&s, idle(moved)) else { return XCTFail("a new line means a new verdict") }
        _ = judged(&s, #"{"verdict":"ready","reason":"committed"}"#, mark: mark)
        XCTAssertEqual(tick(&s, idle(moved)), .compact(nonce: nonce))
    }

    /// Earlier builds held a ready session in a "background" stage. Read from such a file, it's
    /// checking again and compacts at the next tick.
    func testAFollowUpHeldByAnEarlierBuildCompacts() throws {
        var s = ready()
        let data = try FileIO.encoder().encode(s)
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""stage" : "checking""#, with: #""stage" : "background""#)
        XCTAssertTrue(text.contains(#""stage" : "background""#))
        s = try FileIO.decoder().decode(SessionState.self, from: Data(text.utf8))
        XCTAssertEqual(s.followUp?.stage, .checking)
        XCTAssertEqual(tick(&s, background(agents: 1)), .compact(nonce: nonce))
    }

    func testCompactNowWhileCheckingMakesItYours() {
        var s = askedToSave()
        _ = tick(&s, idle())
        Engine.apply(Answer(cycle: s.cycle, action: .yes, source: .popup, at: now), to: &s)
        XCTAssertEqual(s.followUp?.manual, true)
        XCTAssertEqual(s.phase, .sent)
        _ = judged(&s, #"{"verdict":"ready","reason":"pushed"}"#)
        XCTAssertEqual(tick(&s, background(shells: true)), .compact(nonce: nonce))
    }

    func testCompactNowOnASaveMessageNotYetSeenIsLeftAlone() {
        var s = askedToSave()
        s.confirmedAt = nil
        let before = s
        Engine.apply(Answer(cycle: s.cycle, action: .yes, source: .menu, at: now), to: &s)
        XCTAssertEqual(s.phase, before.phase)
        XCTAssertNil(s.followUp)
    }

    func testTheContinueMessageGoesOutWithBackgroundWorkRunning() {
        var s = compacting()
        Engine.compactionStarted(&s, now: now)
        XCTAssertEqual(tick(&s, background(agents: 1)), .continue(nonce: nonce, text: "continue now"))
    }

    // MARK: Compacting

    func testOurCompactionMovesOnToTheContinueMessage() {
        var s = compacting()
        Engine.compactionStarted(&s, now: now)
        XCTAssertEqual(s.phase, .watching, "re-armed as usual")
        XCTAssertEqual(s.followUp?.stage, .continuing, "and the follow-up survives it")
        XCTAssertEqual(s.followUp?.tokensBefore, 310_000)

        var busy = idle()
        busy.activity = .busy
        XCTAssertEqual(tick(&s, busy), .none, "never interrupts the compaction")
        XCTAssertEqual(tick(&s, idle()), .continue(nonce: nonce, text: "continue now"))
        XCTAssertEqual(s.followUp?.stage, .done)
        XCTAssertNotNil(s.followUp?.continuedAt)
        XCTAssertEqual(tick(&s, idle()), .none, "only once")
    }

    func testTheContinueMessageIsTheConfiguredOne() {
        var s = compacting()
        Engine.compacted(&s, trigger: "manual", preTokens: 311_000, postTokens: 22_000, now: now)
        var c = config
        c.continueMessage = "carry on"
        XCTAssertEqual(tick(&s, idle(), config: c), .continue(nonce: nonce, text: "carry on"))
        XCTAssertEqual(s.followUp?.tokensAfter, 22_000)
    }

    func testTheModsReportAlsoMovesItOn() {
        var s = compacting()
        Compactor.apply(ModReport(sessionId: s.sessionId, nonce: nonce, kind: .compacted, tokensBefore: 312_000, tokensAfter: 21_000), to: &s, now: now)
        XCTAssertEqual(s.followUp?.stage, .continuing)
        XCTAssertEqual(s.followUp?.tokensAfter, 21_000)
        Engine.compactionStarted(&s, now: now)
        XCTAssertEqual(s.followUp?.stage, .continuing, "the hook seeing it afterwards changes nothing")
    }

    func testTheSizeAfterComesFromTheLateCompactionRecord() {
        var s = compacting()
        Engine.compactionStarted(&s, now: now)
        XCTAssertNil(s.followUp?.tokensAfter)
        var r = TranscriptReading()
        r.compaction = .compaction(trigger: "manual", preTokens: 311_000, postTokens: 19_000)
        r.latest = r.compaction
        Engine.observe(&s, r, config: config, now: now)
        XCTAssertEqual(s.followUp?.tokensAfter, 19_000)
        XCTAssertEqual(s.followUp?.tokensBefore, 311_000)
    }

    func testATurnThatBeatTheCompactionIsJudgedAgain() {
        var s = compacting()
        report(&s, .compactFailed, error: "a turn is running")
        XCTAssertEqual(s.followUp?.stage, .checking)
        guard case .judge = tick(&s, idle(conversation("User: wait, one more thing", mark: 4_000))) else {
            return XCTFail("expected a new verdict")
        }
    }

    func testCompactingThatKeepsFailingGivesUp() {
        var s = compacting()
        report(&s, .compactSkipped)
        XCTAssertEqual(tick(&s, idle()), .compact(nonce: nonce), "same verdict, same conversation: try again")
        report(&s, .compactSkipped)
        XCTAssertEqual(tick(&s, idle()), .compact(nonce: nonce))
        report(&s, .compactSkipped)
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertEqual(s.followUp?.stage, .failed)
    }

    func testACompactionThatNeverHappenedIsCheckedAgain() {
        var s = compacting()
        now += 601
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertEqual(s.followUp?.stage, .checking)
        s.phase = .sent
        guard case .judge = tick(&s, idle()) else { return XCTFail("expected a new verdict") }
    }

    func testClaudeCodeCompactingByItselfFirstEndsItWithoutAContinue() {
        var s = askedToSave()
        _ = tick(&s, idle())
        Engine.compacted(&s, trigger: "auto", preTokens: 400_000, postTokens: 30_000, now: now)
        XCTAssertEqual(s.followUp?.stage, .stopped)
        XCTAssertEqual(s.followUp?.note, "Claude Code compacted it by itself")
        XCTAssertEqual(tick(&s, idle()), .none)
    }

    // MARK: Continuing

    func testSendingSomethingFirstMeansYouTookOver() {
        var s = compacting()
        Engine.compactionStarted(&s, now: now)
        var look = idle()
        look.promptSinceCompacting = true
        XCTAssertEqual(tick(&s, look), .none)
        XCTAssertEqual(s.followUp?.stage, .tookOver)
    }

    func testTypingMeansYouTookOver() {
        var s = compacting()
        Engine.compactionStarted(&s, now: now)
        XCTAssertEqual(tick(&s, idle(draft: true)), .none)
        XCTAssertEqual(s.followUp?.stage, .tookOver)
    }

    func testAContinueThatFailedIsTriedAgainThenGivenUp() {
        var s = compacting()
        Engine.compactionStarted(&s, now: now)
        for _ in 0..<2 {
            XCTAssertEqual(tick(&s, idle()), .continue(nonce: nonce, text: "continue now"))
            report(&s, .continueFailed, error: "rejected")
            XCTAssertEqual(s.followUp?.stage, .continuing)
        }
        XCTAssertEqual(tick(&s, idle()), .continue(nonce: nonce, text: "continue now"))
        report(&s, .continueFailed, error: "rejected")
        XCTAssertEqual(s.followUp?.stage, .failed)
    }

    // MARK: Stopping

    func testANewSaveMessageReplacesTheOldFollowUp() {
        var s = askedToSave()
        _ = tick(&s, idle())
        s.sentNonce = "cg-new"
        s.confirmedAt = now
        var look = idle()
        look.conversation?.after = "cg-new"
        guard case .judge(let n, _, _) = tick(&s, look) else { return XCTFail("expected a judge for the new one") }
        XCTAssertEqual(n, "cg-new")
        XCTAssertEqual(s.followUp?.nonce, "cg-new")
    }

    func testANewQuestionStopsIt() {
        var s = askedToSave()
        _ = tick(&s, idle())
        s.phase = .asking
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertEqual(s.followUp?.stage, .stopped)
    }

    func testTurningThingsOffMidWayStopsIt() {
        var off = config
        off.enabled = false
        var compacted = compacting()
        Engine.compactionStarted(&compacted, now: now)
        XCTAssertEqual(tick(&compacted, idle(), config: off), .none)
        XCTAssertEqual(compacted.followUp?.stage, .stopped)
        XCTAssertEqual(compacted.followUp?.note, "Context Guard is off")

        var s = askedToSave()
        _ = tick(&s, idle())
        XCTAssertEqual(tick(&s, idle(), watched: false), .none)
        XCTAssertEqual(s.followUp?.stage, .stopped)
        XCTAssertEqual(s.followUp?.note, "you stopped watching this session")
        XCTAssertEqual(tick(&s, idle()), .none, "watching again doesn't restart this save message's follow-up")
    }

    // MARK: Compact Now

    func testCompactNowCompactsWhileOffAndUnwatched() {
        var off = config
        off.enabled = false
        for (c, watched) in [(off, true), (config, false), (off, false)] {
            var s = askedToSave()
            s.sendReason = .manual
            guard case .judge = tick(&s, idle(), config: c, watched: watched) else { return XCTFail("Compact Now starts while off or unwatched") }
            XCTAssertEqual(s.followUp?.manual, true)
            _ = judged(&s, #"{"verdict":"ready","reason":"pushed"}"#)
            XCTAssertEqual(tick(&s, idle(), config: c, watched: watched), .compact(nonce: nonce))
            Engine.compactionStarted(&s, now: now)
            XCTAssertEqual(s.followUp?.stage, .continuing, "the compaction keeps the follow-up going")
            XCTAssertEqual(tick(&s, idle(), config: c, watched: watched), .continue(nonce: nonce, text: "continue now"))
            XCTAssertEqual(s.followUp?.stage, .done)
        }
    }

    func testTurningOffOrUnwatchingDoesNotStopCompactNow() {
        var off = config
        off.enabled = false
        for (c, watched) in [(off, true), (config, false)] {
            var s = askedToSave()
            s.sendReason = .manual
            _ = tick(&s, idle())
            _ = tick(&s, idle(), config: c, watched: watched)
            XCTAssertEqual(s.followUp?.stage, .checking, "turning off or unwatching doesn't stop it")
            _ = judged(&s, #"{"verdict":"ready","reason":"pushed"}"#)
            XCTAssertEqual(tick(&s, idle(), config: c, watched: watched), .compact(nonce: nonce))
        }
    }

    func testAnEndedSessionStopsCompactNow() {
        var s = askedToSave()
        s.sendReason = .manual
        _ = tick(&s, idle())
        s.ended = true
        XCTAssertEqual(tick(&s, idle()), .none)
        XCTAssertEqual(s.followUp?.stage, .stopped)
    }

    func testAFollowUpFromBeforeCompactNowCountsAsAutomatic() throws {
        let json = #"{"nonce":"cg-1","stage":"checking","startedAt":"2026-11-04T10:00:00Z","stageAt":"2026-11-04T10:00:00Z","workingRepeats":0,"judgeFailures":0,"compactAttempts":0,"continueFailures":0}"#
        let f = try FileIO.decoder().decode(FollowUp.self, from: Data(json.utf8))
        XCTAssertNil(f.manual)
    }

    func testEveryFollowUpFieldIsSavedAndLoaded() throws {
        var f = FollowUp(nonce: nonce, manual: true, now: now)
        f.stage = .continuing
        f.stageAt = now.addingTimeInterval(1)
        f.note = "pushed"
        f.verdict = .ready
        f.verdictAt = now.addingTimeInterval(2)
        f.verdictMark = 7
        f.workingRepeats = 1
        f.judgeAskedAt = now.addingTimeInterval(3)
        f.judgeFailures = 1
        f.nextJudgeAt = now.addingTimeInterval(4)
        f.compactAttempts = 1
        f.compactFrom = 8
        f.compactStartedAt = now.addingTimeInterval(5)
        f.compactedAt = now.addingTimeInterval(6)
        f.tokensBefore = 310_000
        f.tokensAfter = 24_000
        f.continuedAt = now.addingTimeInterval(7)
        f.continueFailures = 1
        XCTAssertEqual(try FileIO.decoder().decode(FollowUp.self, from: FileIO.encoder().encode(f)), f)
    }

    func testAFollowUpFromANewerBuildStillReads() throws {
        let json = #"{"nonce":"cg-1","stage":"somethingNew","startedAt":"2026-11-04T10:00:00Z"}"#
        let f = try FileIO.decoder().decode(FollowUp.self, from: Data(json.utf8))
        XCTAssertEqual(f.stage, .stopped)
        XCTAssertFalse(f.isActive)
    }
}
