import XCTest
@testable import ContextGuardCore

/// Claude Code session files read and write exactly as before there was a second tool, and each
/// tool's runners leave the other tool's sessions alone.
final class HostTests: HookTestCase {
    /// A state file as the build before Codex support wrote it (a real one, with demo values).
    static let claudeFile = #"""
    {
      "appliedAnswerId" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "awaitingCompactionRecord" : false,
      "claudePid" : 43374,
      "claudeStart" : {
        "microseconds" : 925814,
        "seconds" : 1794349141
      },
      "cursor" : {
        "inode" : 288705418,
        "offset" : 5579964
      },
      "cwd" : "\/Users\/demo\/code",
      "cycle" : 1,
      "ended" : false,
      "followUp" : {
        "compactAttempts" : 1,
        "compactFrom" : 4161334,
        "compactStartedAt" : "2026-11-10T23:55:25Z",
        "compactedAt" : "2026-11-10T23:56:37Z",
        "continueFailures" : 0,
        "continuedAt" : "2026-11-10T23:56:44Z",
        "judgeFailures" : 0,
        "nonce" : "cg-5169c6a2b1",
        "note" : "Compacted: 316k to 29k.",
        "stage" : "done",
        "stageAt" : "2026-11-10T23:56:44Z",
        "startedAt" : "2026-11-10T23:54:14Z",
        "tokensAfter" : 29181,
        "tokensBefore" : 315512,
        "verdict" : "ready",
        "verdictAt" : "2026-11-10T23:55:24Z",
        "verdictMark" : 4149738,
        "workingRepeats" : 0
      },
      "guarded" : true,
      "lastCompaction" : {
        "at" : "2026-11-10T23:56:37Z",
        "postTokens" : 29181,
        "preTokens" : 315512,
        "trigger" : "manual"
      },
      "lastEvent" : "PostToolBatch",
      "name" : "demo-session",
      "phase" : "watching",
      "resendCount" : 0,
      "schemaVersion" : 1,
      "sessionId" : "11111111-2222-3333-4444-555555555555",
      "stopsSinceSent" : 0,
      "title" : "Add a settings screen",
      "tokens" : 133662,
      "tokensAt" : "2026-11-10T23:59:05Z",
      "transcriptPath" : "\/Users\/demo\/.claude\/projects\/-Users-demo-code\/11111111-2222-3333-4444-555555555555.jsonl",
      "updatedAt" : "2026-11-10T23:59:05Z",
      "waiterPid" : 52756,
      "waiterSince" : "2026-11-10T23:55:15Z",
      "waiterStart" : {
        "microseconds" : 879212,
        "seconds" : 1794354914
      },
      "waiterToken" : "FFFFFFFF-1111-2222-3333-444444444444"
    }
    """#

    func decode(_ json: String) throws -> SessionState {
        try FileIO.decoder().decode(SessionState.self, from: Data(json.utf8))
    }

    func testAClaudeFileFromBeforeReadsAsClaudeAndWritesBackTheSameBytes() throws {
        let s = try decode(Self.claudeFile)
        XCTAssertEqual(s.hostKind, .claude)
        XCTAssertNil(s.host)
        XCTAssertEqual(s.followUp?.stage, .done)
        let written = try FileIO.encoder().encode(s)
        XCTAssertEqual(String(decoding: written, as: UTF8.self), Self.claudeFile)
    }

    func testANewClaudeSessionLeavesTheToolOut() throws {
        let written = try FileIO.encoder().encode(SessionState(sessionId: sid, now: clock.now))
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("host"))
    }

    func testACodexSessionRecordsItsTool() throws {
        let written = try FileIO.encoder().encode(SessionState(sessionId: sid, host: .codex, now: clock.now))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains(#""host" : "codex""#))
        XCTAssertEqual(try FileIO.decoder().decode(SessionState.self, from: written).hostKind, .codex)
    }

    func testAToolThisBuildDoesNotKnowIsNotAnyToolItKnows() throws {
        let s = try decode(Self.claudeFile.replacingOccurrences(of: #""guarded""#, with: #""host" : "newtool",\#n  "guarded""#))
        XCTAssertEqual(s.host, "newtool")
        XCTAssertNil(s.hostKind)
    }

    func testADeliveryChannelFromANewerBuildReadsAsAWake() throws {
        let file = Self.claudeFile.replacingOccurrences(of: #""guarded""#, with: #""sentVia" : "pigeon",\#n  "guarded""#)
        XCTAssertEqual(try decode(file).sentVia, .wake)
        XCTAssertEqual(try decode(file.replacingOccurrences(of: #""pigeon""#, with: #""step""#)).sentVia, .step)
        XCTAssertEqual(try decode(file.replacingOccurrences(of: #""pigeon""#, with: #""turn""#)).sentVia, .turn)
    }

    // MARK: Runners

    /// A big, guarded session of `host` with its save message queued, as another tool's driver left it.
    func otherToolsSession(_ host: String) throws -> Data {
        try configure()
        transcript.append(Line.context(310_000))
        var file = Self.claudeFile
            .replacingOccurrences(of: #""guarded""#, with: #""host" : "\#(host)",\#n  "guarded""#)
            .replacingOccurrences(of: #""phase" : "watching""#, with: #""phase" : "queued""#)
            .replacingOccurrences(of: #""claudePid" : 43374"#, with: #""claudePid" : \#(claude)"#)
        file = file.replacingOccurrences(of: #""\/Users\/demo\/.claude\/projects\/-Users-demo-code\/11111111-2222-3333-4444-555555555555.jsonl""#,
                                         with: "\"\(transcript.path)\"")
        try paths.ensureDirectories()
        let data = Data(file.utf8)
        try data.write(to: paths.stateFile(sid))
        XCTAssertNotNil(state, "the fixture is a valid state file")
        return data
    }

    func testClaudesHooksLeaveOtherToolsSessionsAlone() throws {
        for host in ["codex", "newtool"] {
            let before = try otherToolsSession(host)
            try answer(.yes, from: .menu)
            for name in ["SessionStart", "UserPromptSubmit", "PostToolBatch", "Stop", "SessionEnd"] {
                XCTAssertEqual(runner.handle(event(name)), .silent, "\(host): \(name)")
            }
            XCTAssertEqual(try Data(contentsOf: paths.stateFile(sid)), before, "\(host): the file is untouched")
        }
    }

    /// Saved and judged ready by Haiku, then the file says another tool runs the session: the mod
    /// neither compacts it nor records its turns.
    func testTheModLeavesOtherToolsSessionsAlone() throws {
        for host in ["codex", "newtool"] {
            try? FileManager.default.removeItem(at: paths.sessionsDir)
            try? FileManager.default.removeItem(at: paths.turnFile(sid))
            try configure()
            transcript.append(Line.context(310_000))
            _ = runner.handle(event("PostToolBatch"))
            try answer(.yes)
            guard case .addContext(_, let text) = runner.handle(event("PostToolBatch")) else { return XCTFail("expected the save message") }
            transcript.append(Line.attachment(text), Line.reply("Pushed and saved. Ready for compaction."), Line.bookkeeping())
            _ = runner.handle(event("Stop"))
            try settle()
            guard case .judge(let nonce, let mark, _) = mod.tick(ModFacts(sessionId: sid, agents: 0, draft: false)) else {
                return XCTFail("\(host): a Claude session is judged")
            }

            var s = try XCTUnwrap(state)
            s.host = host
            try s.save(paths)
            let before = try Data(contentsOf: paths.stateFile(sid))
            XCTAssertFalse(mod.report(ModReport(sessionId: sid, nonce: nonce, kind: .judged, mark: mark,
                                                text: #"{"verdict":"ready","reason":"saved"}"#)), host)
            try settle()
            XCTAssertEqual(mod.tick(ModFacts(sessionId: sid, agents: 0, draft: false)), ModAction.none, host)
            mod.turn(ModTurn(sessionId: sid, active: true))
            XCTAssertNil(TurnRecord.load(sid, paths), host)
            XCTAssertEqual(try Data(contentsOf: paths.stateFile(sid)), before, "\(host): the file is untouched")
        }
    }

    func testTheSameClaudeSessionIsStillHandled() throws {
        let before = try otherToolsSession("codex")
        try Data(String(decoding: before, as: UTF8.self).replacingOccurrences(of: #""host" : "codex",\#n  "#, with: "").utf8)
            .write(to: paths.stateFile(sid))
        XCTAssertEqual(state?.hostKind, .claude)
        guard case .addContext = runner.handle(event("PostToolBatch")) else {
            return XCTFail("a Claude session with its message queued gets it at the next step")
        }
    }
}

final class RequeueTests: XCTestCase {
    let now = Date()
    let config = Config()

    func sent(_ reason: SendReason = .yes, timedOut: Bool? = nil) -> SessionState {
        var s = SessionState.guarded(310_000, phase: .queued, cycle: 1)
        s.sendReason = reason
        s.askTimedOut = timedOut
        _ = Engine.claimDelivery(&s, via: .wake, config: config, nonce: "cg-1", now: now)
        return s
    }

    func testAnUnconfirmedSendIsQueuedAgainForTheSameReason() {
        var s = sent(.yes, timedOut: true)
        XCTAssertTrue(Engine.requeueUnconfirmed(&s))
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.sendReason, .yes)
        XCTAssertEqual(s.askTimedOut, true)
        XCTAssertEqual(s.resendCount, 1)
        XCTAssertNil(s.sentNonce)
        XCTAssertEqual(s.stopsSinceSent, 0)
    }

    func testOnlyOnceACycle() {
        var s = sent(.manual)
        XCTAssertTrue(Engine.requeueUnconfirmed(&s))
        _ = Engine.claimDelivery(&s, via: .wake, config: config, nonce: "cg-2", now: now)
        XCTAssertFalse(Engine.requeueUnconfirmed(&s))
        XCTAssertEqual(s.phase, .sent)
        XCTAssertEqual(s.sentNonce, "cg-2")
    }

    func testAConfirmedOrUnsentMessageStaysPut() {
        var s = sent()
        s.confirmedAt = now
        XCTAssertFalse(Engine.requeueUnconfirmed(&s))
        XCTAssertEqual(s.phase, .sent)

        var waiting = SessionState.guarded(310_000, phase: .queued, cycle: 1)
        XCTAssertFalse(Engine.requeueUnconfirmed(&waiting))
        XCTAssertEqual(waiting.resendCount, 0)
    }
}

final class ThresholdTests: XCTestCase {
    func codex(window: Int?, autoCompactAt: Int? = nil) -> SessionState {
        var s = SessionState(sessionId: "s1", host: .codex, now: Date())
        s.codex = CodexFacts(window: window, autoCompactAt: autoCompactAt)
        return s
    }

    func testClaudeCodeKeepsTheTokenCountsAsSet() {
        let c = Config(askAt: 250_000, laterAt: 400_000)
        XCTAssertEqual(c.resolved(for: SessionState.guarded(10)), c)
    }

    func testCodexAsksAtAShareOfTheSessionsOwnWindow() {
        let c = Config()
        let most = c.resolved(for: codex(window: 258_400))
        XCTAssertEqual(most.askAt, 155_040, "60%")
        XCTAssertEqual(most.laterAt, 206_720, "80%")
        let big = c.resolved(for: codex(window: 475_000))
        XCTAssertEqual(big.askAt, 285_000)
        XCTAssertEqual(big.laterAt, 380_000)
        XCTAssertEqual(c.askAt, Config.defaultAskAt, "Claude Code's own numbers are unchanged")
    }

    func testWaitStaysBelowWhereCodexCompactsByItself() {
        // Its default: 90% of the model's window, of which the session reports 95%.
        XCTAssertEqual(CodexFacts(window: 258_400).compactsItselfAt, 244_800)
        let late = Config(codexAskPercent: 85, codexLaterPercent: 90).normalized
        let r = late.resolved(for: codex(window: 258_400))
        XCTAssertEqual(r.laterAt, 244_800 - 25_840, "90% would be too close to 244.8k")
        // A low limit of your own wins, with room for the save to finish first.
        let low = Config().resolved(for: codex(window: 258_400, autoCompactAt: 180_000))
        XCTAssertEqual(low.laterAt, 180_000 - 25_840)
        XCTAssertEqual(low.askAt, 180_000 - 25_840 - 12_920, "asking stays before Wait")
        XCTAssertEqual(Config().resolved(for: codex(window: 258_400)).laterAt, 206_720, "80% has room enough")
    }

    func testAnUnknownWindowKeepsTheTokenCounts() {
        let c = Config()
        XCTAssertEqual(c.resolved(for: codex(window: nil)), c)
        XCTAssertEqual(c.resolved(for: codex(window: 0)), c)
    }

    func testPercentagesAreKeptSensible() {
        let c = Config(codexAskPercent: 2, codexLaterPercent: 1).normalized
        XCTAssertEqual(c.codexAskPercent, 10)
        XCTAssertEqual(c.codexLaterPercent, 15)
        let high = Config(codexAskPercent: 99, codexLaterPercent: 150).normalized
        XCTAssertEqual(high.codexAskPercent, 85)
        XCTAssertEqual(high.codexLaterPercent, 90)
    }

    func testASettingsFileWithoutThemReadsTheDefaults() throws {
        let old = #"{"schemaVersion":1,"enabled":true,"askAt":300000,"laterAt":500000,"codexAskPercent":"sixty"}"#
        let c = try FileIO.decoder().decode(Config.self, from: Data(old.utf8))
        XCTAssertEqual(c.codexAskPercent, 60)
        XCTAssertEqual(c.codexLaterPercent, 80)
        XCTAssertEqual(c.askAt, 300_000)
    }

    func testCodexFactsThatDoNotReadAreLeftUnknown() throws {
        let f = try FileIO.decoder().decode(CodexFacts.self, from: Data(#"{"window":"big","model":"gpt-6-luna","flags":["waitingOnApproval"]}"#.utf8))
        XCTAssertNil(f.window)
        XCTAssertEqual(f.model, "gpt-6-luna")
        XCTAssertEqual(f.flags, ["waitingOnApproval"])
    }
}

final class WordingTests: XCTestCase {
    let now = Date()

    func session(_ host: SessionHost) -> SessionState {
        var s = SessionState(sessionId: "s1", host: host, now: now)
        s.guarded = true
        s.tokens = 160_000
        s.phase = .queued
        s.sendReason = .yes
        s.askedTokens = 160_000
        return s
    }

    func testCodexGetsTheMessageAsYourOwnWords() {
        var s = session(.codex)
        let text = Engine.claimDelivery(&s, via: .wake, config: Config(message: "Save your work."), nonce: "cg-1", now: now)
        XCTAssertEqual(text, "Save your work. [cg-1]")
        var c = session(.claude)
        XCTAssertTrue(Engine.claimDelivery(&c, via: .wake, config: Config(message: "Save your work."), nonce: "cg-1", now: now)?
            .hasPrefix("Context Guard (a Claude Code hook") ?? false)
    }

    func testTheJudgeIsToldWhichToolTheSessionRunsIn() {
        XCTAssertTrue(JudgePrompt.make(message: "m", conversation: "c", idleFor: 0, host: .codex).hasPrefix("You are checking on a Codex session"))
        XCTAssertTrue(JudgePrompt.make(message: "m", conversation: "c", idleFor: 0).hasPrefix("You are checking on a Claude Code session"))
    }

    func testNotesNameTheTool() {
        var s = session(.codex)
        s.followUp = FollowUp(nonce: "cg-1", now: now)
        Compactor.compacted(&s, trigger: "auto", preTokens: 245_000, postTokens: 30_000, now: now)
        XCTAssertEqual(s.followUp?.note, "Codex compacted it by itself")

        var f = FollowUp(nonce: "cg-1", now: now)
        for _ in 0..<Compactor.maxJudgeFailures { Compactor.failJudge(&f, "timed out", host: .codex, now: now) }
        XCTAssertEqual(f.note, "The judge model didn't answer (timed out)")
        var h = FollowUp(nonce: "cg-1", now: now)
        for _ in 0..<Compactor.maxJudgeFailures { Compactor.failJudge(&h, "timed out", now: now) }
        XCTAssertEqual(h.note, "Haiku didn't answer (timed out)")
    }
}

final class DeliveryRecoveryTests: XCTestCase {
    let now = Date()
    let config = Config()

    func sent(at: Date) -> SessionState {
        var s = SessionState.guarded(160_000, phase: .queued, cycle: 1)
        s.sendReason = .manual
        _ = Engine.claimDelivery(&s, via: .wake, config: config, nonce: "cg-1", now: at)
        return s
    }

    func testARefusedSendGoesBackToQueuedAndKeepsItsResend() {
        var s = sent(at: now)
        Engine.unclaim(&s)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.sendReason, .manual)
        XCTAssertEqual(s.resendCount, 0)
        XCTAssertNil(s.sentNonce)
        _ = Engine.claimDelivery(&s, via: .wake, config: config, nonce: "cg-2", now: now)
        XCTAssertTrue(Engine.requeueUnconfirmed(&s), "the resend is still there")
    }

    func testAConfirmedSendIsNeverUnclaimed() {
        var s = sent(at: now)
        s.confirmedAt = now
        Engine.unclaim(&s)
        XCTAssertEqual(s.phase, .sent)
    }

    func testASendThatNeverArrivedIsQueuedOnceMore() {
        var s = sent(at: now.addingTimeInterval(-31))
        XCTAssertFalse(Engine.deliveryLost(&s, idleFor: 29, turnSinceSend: false, now: now), "not idle long enough")
        XCTAssertFalse(Engine.deliveryLost(&s, idleFor: 31, turnSinceSend: true, now: now), "a turn started: it may be on its way")
        XCTAssertTrue(Engine.deliveryLost(&s, idleFor: 31, turnSinceSend: false, now: now))
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.resendCount, 1)

        _ = Engine.claimDelivery(&s, via: .wake, config: config, nonce: "cg-2", now: now.addingTimeInterval(-40))
        XCTAssertFalse(Engine.deliveryLost(&s, idleFor: 40, turnSinceSend: false, now: now), "only once")
    }

    func testAJustSentMessageIsNotLost() {
        var s = sent(at: now.addingTimeInterval(-5))
        XCTAssertFalse(Engine.deliveryLost(&s, idleFor: 600, turnSinceSend: false, now: now))
        XCTAssertEqual(s.phase, .sent)
    }

    func testStoppingTheCompactionStopsTheFollowUp() {
        var s = SessionState.guarded(160_000, phase: .sent, cycle: 1)
        s.sentNonce = "cg-1"
        var f = FollowUp(nonce: "cg-1", now: now)
        f.stage = .compacting
        f.verdict = .ready
        s.followUp = f
        XCTAssertFalse(Compactor.apply(ModReport(sessionId: "s1", nonce: "cg-1", kind: .compactInterrupted), to: &s, now: now))
        XCTAssertEqual(s.followUp?.stage, .stopped)
        XCTAssertEqual(s.followUp?.note, "you stopped the compaction")
        XCTAssertFalse(s.followUp?.isActive ?? true)

        var later = s
        later.followUp?.stage = .continuing
        XCTAssertFalse(Compactor.apply(ModReport(sessionId: "s1", nonce: "cg-1", kind: .compactInterrupted), to: &later, now: now))
        XCTAssertEqual(later.followUp?.stage, .continuing, "only while compacting")
    }
}
