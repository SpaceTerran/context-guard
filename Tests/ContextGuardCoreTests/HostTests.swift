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
        let file = Self.claudeFile.replacingOccurrences(of: #""guarded""#, with: #""sentVia" : "turn",\#n  "guarded""#)
        XCTAssertEqual(try decode(file).sentVia, .wake)
        XCTAssertEqual(try decode(file.replacingOccurrences(of: #""turn""#, with: #""step""#)).sentVia, .step)
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
