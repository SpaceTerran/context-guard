import ContextGuardCore
import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCodexLink

/// `context-guard codex` against an app server in memory and a real rollout file: what it sends,
/// when, and what it leaves alone.
final class CodexLinkTests: XCTestCase {
    let dir = TempDir()
    let clock = TestClock()
    let id = CodexLine.thread
    let daemon = FakeDaemon()
    let terminals = FakeTerminals([CodexTerminalProcess(pid: 4242, cwd: "/Users/demo/code", args: ["codex"])])
    var paths: Paths!
    var log: Transcript!
    var link: CodexLink!

    override func setUp() {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        log = Transcript(dir, name: "rollout-\(id).jsonl")
        log.append(CodexLine.meta())
        daemon.add(.init(id: id, path: log.path, cwd: "/Users/demo/code", name: "Settings screen"))
        makeLink()
    }

    func makeLink(onlyCwd: String? = nil) {
        var o = CodexLink.Options(onlyCwd: onlyCwd)
        o.inline = true
        o.judgeTimeout = 2
        let clock = self.clock
        link = CodexLink(paths: paths, connector: FakeConnector(daemon), terminals: terminals, options: o, clock: { clock.now })
        daemon.onEvent = { [weak link] in link?.handle($0) }
    }

    var state: SessionState? { SessionState.load(id, paths) }

    func pass() throws { try link.pass(daemon, now: clock.now) }

    func configure() throws {
        var c = Config()
        c.enabledAt = clock.now.addingTimeInterval(-3_600)
        try c.save(paths)
    }

    /// The rollout untouched for a few seconds.
    func settle(_ seconds: TimeInterval = 5) throws {
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-seconds)], ofItemAtPath: log.path)
    }

    func answerYes() throws {
        try Answer(cycle: state?.cycle ?? 0, action: .yes, source: .popup, at: clock.now).save(for: id, paths)
    }

    /// The prompts Context Guard queued, oldest first.
    var queued: [(text: String, clientId: String)] {
        daemon.calls("thread/queue/add").map { ($0["input"]?[0]?["text"]?.string ?? "", $0["clientUserMessageId"]?.string ?? "") }
    }

    /// At 160k you said Yes; the save message went out and Codex ran it. Returns its nonce.
    func sendTheSaveMessage() throws -> String {
        try configure()
        log.append(CodexLine.turn("Add a settings screen", reply: "Added it.", tokens: 160_000))
        try settle()
        try pass()
        XCTAssertEqual(state?.phase, .asking)
        XCTAssertTrue(queued.isEmpty, "nothing before you answer")
        try answerYes()
        try pass()
        let nonce = try XCTUnwrap(state?.sentNonce)
        XCTAssertEqual(state?.phase, .sent)
        let sent = try XCTUnwrap(queued.last)
        XCTAssertEqual(sent.text, "\(Config.defaultMessage) [\(nonce)]")
        XCTAssertEqual(sent.clientId, CodexClientID.make(nonce: nonce, kind: "save"))
        // Codex runs it as your next prompt.
        log.append(CodexLine.taskStarted(), CodexLine.prompt(sent.text, clientId: sent.clientId))
        try pass()
        XCTAssertNotNil(state?.confirmedAt)
        return nonce
    }

    /// The session saved and went idle.
    func finishSaving() throws {
        log.append(CodexLine.toolCall(), CodexLine.toolOutput("main -> main"), CodexLine.reply("Pushed and saved. Ready for compaction."),
                   CodexLine.tokens(165_000), CodexLine.taskComplete())
        daemon.setStatus(id, "idle")
        try settle()
    }

    func testFromAskingToContinue() throws {
        let nonce = try sendTheSaveMessage()
        try finishSaving()
        try pass()

        // The judge, on a throwaway thread of its own, then the compaction, in one pass.
        let judge = try XCTUnwrap(daemon.calls("thread/start").first)
        XCTAssertEqual(judge["model"]?.string, "gpt-6-luna", "the session's model when the link hasn't picked one")
        XCTAssertEqual(judge["ephemeral"]?.bool, true)
        XCTAssertEqual(judge["cwd"]?.string, link.judgeFolder.path)
        XCTAssertEqual(judge["config"]?["mcp_servers"], ["docs": ["enabled": false]])
        let question = try XCTUnwrap(daemon.calls("turn/start").first?["input"]?[0]?["text"]?.string)
        XCTAssertTrue(question.contains("Pushed and saved. Ready for compaction."))
        XCTAssertEqual(daemon.calls("thread/unsubscribe").count, 1)
        XCTAssertEqual(daemon.calls("thread/compact/start").map { $0["threadId"]?.string }, [id])
        XCTAssertEqual(state?.followUp?.stage, .compacting)
        XCTAssertEqual(state?.followUp?.note, "pushed and saved")

        try pass()
        XCTAssertEqual(daemon.calls("thread/compact/start").count, 1, "once")

        log.append(CodexLine.compactionTurn(after: 18_000))
        daemon.setStatus(id, "idle")
        try settle()
        try pass()
        XCTAssertEqual(state?.tokens, 18_000)
        XCTAssertEqual(queued.last?.text, "continue now")
        XCTAssertEqual(queued.last?.clientId, CodexClientID.make(nonce: nonce, kind: "continue"))
        XCTAssertEqual(state?.followUp?.stage, .done)
        try pass()
        XCTAssertEqual(queued.count, 2, "the save message and continue, once each")
        XCTAssertTrue(daemon.calls("thread/queue/start").isEmpty, "both started by themselves")
    }

    // MARK: - Codex holding its queue (after Esc)

    /// At 160k, you said Yes, with Codex holding its queue.
    func yesWhileCodexHoldsItsQueue() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        try pass()
        try answerYes()
        daemon.pause(id)
    }

    func testASaveMessageCodexHoldsIsStarted() throws {
        try yesWhileCodexHoldsItsQueue()
        try pass()
        let item = try XCTUnwrap(daemon.calls("thread/queue/add").first)
        XCTAssertEqual(state?.phase, .sent)
        let started = try XCTUnwrap(daemon.calls("thread/queue/start").first)
        XCTAssertEqual(started["threadId"]?.string, id)
        XCTAssertNotNil(started["queuedSubmissionId"]?.string, "ours by its id, nothing else")
        XCTAssertTrue(daemon.queue(id).isEmpty)
        XCTAssertEqual(item["clientUserMessageId"]?.string, CodexClientID.make(nonce: try XCTUnwrap(state?.sentNonce), kind: "save"))
    }

    func testYoursHeldAheadOfItStayFirst() throws {
        try yesWhileCodexHoldsItsQueue()
        let yours = daemon.queueYours(id)
        try pass()
        XCTAssertTrue(daemon.calls("thread/queue/start").isEmpty, "yours are yours to send")
        XCTAssertEqual(daemon.queue(id).count, 2)
        XCTAssertEqual(daemon.queue(id).first?["id"]?.string, yours)

        // Never seen: sent once more, still behind yours.
        clock.advance(31)
        try settle(40)
        try pass()
        XCTAssertEqual(state?.resendCount, 1)
        XCTAssertEqual(daemon.calls("thread/queue/add").count, 2)
        XCTAssertEqual(daemon.queue(id).map { $0["id"]?.string }.first, yours)
        XCTAssertEqual(daemon.queue(id).count, 2, "the older copy taken out")
        XCTAssertTrue(daemon.calls("thread/queue/start").isEmpty)
    }

    func testOneATurnTookIsLeftAlone() throws {
        try yesWhileCodexHoldsItsQueue()
        daemon.onCall = { [daemon, id] method, _ in
            if method == "thread/queue/list", !daemon.calls("thread/queue/add").isEmpty { daemon.setStatus(id, "active") }
        }
        try pass()
        XCTAssertTrue(daemon.calls("thread/queue/start").isEmpty, "a turn started since")
    }

    func testACodexThatCantStartItLeavesItQueued() throws {
        try yesWhileCodexHoldsItsQueue()
        daemon.failing["thread/queue/start"] = .rpc(code: -32600, message: "Invalid request: unknown variant `thread/queue/start`")
        try pass()
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertNil(link.currentObserveOnly, "only that one step is missing")
        XCTAssertEqual(daemon.queue(id).count, 1)
    }

    func testAContinueMessageCodexHoldsIsStarted() throws {
        let nonce = try sendTheSaveMessage()
        try finishSaving()
        try pass()
        log.append(CodexLine.compactionTurn(after: 18_000))
        daemon.setStatus(id, "idle")
        daemon.pause(id)
        try settle()
        try pass()
        XCTAssertEqual(queued.last?.clientId, CodexClientID.make(nonce: nonce, kind: "continue"))
        XCTAssertEqual(daemon.calls("thread/queue/start").count, 1)
        XCTAssertTrue(daemon.queue(id).isEmpty)
    }

    func testATurnStartedWhileItWasJudgedHoldsTheCompaction() throws {
        _ = try sendTheSaveMessage()
        try finishSaving()
        // You type while the judge thinks.
        daemon.onCall = { [daemon, id] method, params in
            if method == "turn/start", params["threadId"]?.string != id { daemon.setStatus(id, "active") }
        }
        try pass()
        XCTAssertEqual(daemon.calls("thread/start").count, 1)
        XCTAssertTrue(daemon.calls("thread/compact/start").isEmpty, "it would have cut your turn off")
        XCTAssertEqual(state?.followUp?.stage, .checking)
        XCTAssertEqual(state?.followUp?.compactAttempts, 0)
        XCTAssertEqual(state?.codex?.status, "active", "looked at again after the judge, not as it was before")
    }

    func testATurnStartingJustBeforeTheCompactionPutsItOff() throws {
        let nonce = try sendTheSaveMessage()
        try finishSaving()
        // Your turn starts between the link's last look and the compaction: the read just before
        // compacting sees it.
        var readsAfterJudge = -1
        daemon.onCall = { [daemon, id] method, params in
            if method == "turn/start", params["threadId"]?.string != id { readsAfterJudge = 0 }
            if method == "thread/read", params["threadId"]?.string == id, readsAfterJudge >= 0 {
                readsAfterJudge += 1
                if readsAfterJudge == 2 { daemon.setStatus(id, "active") }
            }
        }
        try pass()
        XCTAssertTrue(daemon.calls("thread/compact/start").isEmpty)
        XCTAssertEqual(state?.followUp?.stage, .checking)
        XCTAssertNil(state?.followUp?.compactStartedAt)
        XCTAssertEqual(state?.followUp?.compactAttempts, 0, "not a try")

        // Your turn ends; it's judged again with what it added.
        daemon.onCall = nil
        log.append(CodexLine.taskStarted(), CodexLine.prompt("one more thing"), CodexLine.reply("Done that too."), CodexLine.taskComplete())
        daemon.setStatus(id, "idle")
        try settle()
        try pass()
        XCTAssertEqual(daemon.calls("thread/start").count, 2)
        XCTAssertTrue(try XCTUnwrap(daemon.calls("turn/start").last?["input"]?[0]?["text"]?.string).contains("Done that too."))
        XCTAssertEqual(daemon.calls("thread/compact/start").count, 1)
        XCTAssertEqual(state?.followUp?.nonce, nonce)
    }

    func testARefusedSaveMessageGoesBackToWaiting() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        try pass()
        try answerYes()
        daemon.failing["thread/queue/add"] = .rpc(code: -32600, message: "thread not found")
        try pass()
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertEqual(state?.resendCount, 0, "a refusal isn't a lost send")
        XCTAssertNil(link.currentObserveOnly)

        daemon.failing = [:]
        try pass()
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(queued.count, 2)
        XCTAssertNotEqual(queued[0].clientId, queued[1].clientId, "a new message")
    }

    func testASendThatMayHaveGoneInIsLeftAsSent() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        try pass()
        try answerYes()
        daemon.failing["thread/queue/add"] = .timeout("thread/queue/add")
        try pass()
        XCTAssertEqual(state?.phase, .sent, "the rollout shows whether it did")
    }

    func testACodexWithoutTheQueueIsOnlyWatched() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        try pass()
        try answerYes()
        daemon.failing["thread/queue/add"] = .rpc(code: -32600, message: "Invalid request: unknown variant `thread/queue/add`, expected one of …")
        try pass()
        XCTAssertEqual(link.currentObserveOnly, "this Codex has no thread/queue/add")
        XCTAssertEqual(CodexLinkStatus.load(paths)?.observeOnly, "this Codex has no thread/queue/add")
        XCTAssertEqual(state?.phase, .queued)

        daemon.failing = [:]
        try pass()
        XCTAssertEqual(queued.count, 1, "nothing more is sent")
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertEqual(state?.codex?.attached, false)
    }

    func testAnOlderMessageOfOursStuckInTheQueueIsTakenOut() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        try pass()
        try answerYes()
        let yours = daemon.queueYours(id)
        let old = daemon.queueItem(id, clientId: CodexClientID.make(nonce: "cg-0000000001", kind: "save"))
        try pass()
        XCTAssertEqual(daemon.calls("thread/queue/delete").map { $0["queuedSubmissionId"]?.string }, [old])
        XCTAssertTrue(daemon.queue(id).contains { $0["id"]?.string == yours }, "yours stays")
        XCTAssertEqual(queued.count, 1)
    }

    func testNothingGoesToASessionNoTerminalShows() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        terminals.set([CodexTerminalProcess(pid: 4242, cwd: "/Users/demo/elsewhere", args: ["codex"])])
        try pass()
        try answerYes()
        try pass()
        XCTAssertEqual(state?.codex?.attached, false)
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertTrue(queued.isEmpty)

        terminals.set([CodexTerminalProcess(pid: 4243, cwd: "/Users/demo/other", args: ["codex", "resume", id])])
        try pass()
        XCTAssertEqual(state?.phase, .sent, "a resume names it")
    }

    func testOnlyTheFolderAskedFor() throws {
        let work = dir.file("work")
        let other = dir.file("work-2")
        for d in [work.appendingPathComponent("app"), other] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let inApp = "01a1c7f0-0000-7000-8000-00000000000a"
        let outside = "01a1c7f0-0000-7000-8000-00000000000b"
        for (thread, cwd) in [(inApp, work.appendingPathComponent("app").path), (outside, other.path)] {
            let r = Transcript(dir, name: "rollout-\(thread).jsonl")
            r.append(CodexLine.meta(id: thread, cwd: cwd))
            daemon.add(.init(id: thread, path: r.path, cwd: cwd))
        }
        makeLink(onlyCwd: work.path)
        try pass()
        XCTAssertNotNil(SessionState.load(inApp, paths), "a folder below it")
        XCTAssertNil(SessionState.load(outside, paths), "a folder whose name only starts the same")
        XCTAssertNil(state, "/Users/demo/code")
    }

    func testItsOwnAndPathlessThreadsAreLeftOut() throws {
        daemon.add(.init(id: "01a1c7f0-0000-7000-8000-0000000000e1", path: "/r/x.jsonl", cwd: "/Users/demo/code", ephemeral: true))
        daemon.add(.init(id: "01a1c7f0-0000-7000-8000-0000000000e2", path: nil, cwd: "/Users/demo/code"))
        try pass()
        XCTAssertNotNil(state)
        XCTAssertNil(SessionState.load("01a1c7f0-0000-7000-8000-0000000000e1", paths))
        XCTAssertNil(SessionState.load("01a1c7f0-0000-7000-8000-0000000000e2", paths))
    }

    func testASessionGoneFromTheAppServerClosesAfterAWhile() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        try pass()
        daemon.unload(id)
        try pass()
        XCTAssertEqual(state?.codex?.loaded, false)
        XCTAssertFalse(state?.ended ?? true)
        clock.advance(CodexRunner.closedAfter + 1)
        try pass()
        XCTAssertEqual(state?.ended, true)
    }

    func testWithNoTerminalAndNoAppServerItsSessionsClose() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        try pass()
        link.closeAbandoned()
        XCTAssertEqual(state?.codex?.loaded, false)
        clock.advance(CodexRunner.closedAfter + 1)
        link.closeAbandoned()
        XCTAssertEqual(state?.ended, true)
    }

    func testCodexsOwnSettingsReachTheSession() throws {
        daemon.config = ["model_auto_compact_token_limit": 180_000, "model_post_turn_compact_threshold_percent": 70, "mcp_servers": .null]
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        try pass()
        XCTAssertEqual(state?.codex?.autoCompactAt, 180_000)
        XCTAssertEqual(state?.codex?.postTurnCompactPercent, 70)
        XCTAssertEqual(daemon.calls("config/read").first?["cwd"]?.string, "/Users/demo/code")
        try pass()
        XCTAssertEqual(daemon.calls("config/read").count, 1, "read again only after a minute")
        clock.advance(61)
        try pass()
        XCTAssertEqual(daemon.calls("config/read").count, 2)
    }

    func testLosingTheAppServerEndsThePass() {
        daemon.failing["thread/loaded/list"] = .closed("gone")
        XCTAssertThrowsError(try pass())
    }
}

/// The link's loop: connecting, the judge model it picks, its status file, letting go.
final class CodexLinkLoopTests: XCTestCase {
    let dir = TempDir()
    let daemon = FakeDaemon()
    var paths: Paths!

    override func setUp() {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
    }

    func running(_ connector: FakeConnector, terminals: FakeTerminals, idleDisconnect: TimeInterval = 300,
                 until done: (CodexLinkStatus?) -> Bool) -> (CodexLink, Bool) {
        var o = CodexLink.Options()
        o.pass = 0.02
        o.idleDisconnect = idleDisconnect
        o.backoff = [0.02]
        let link = CodexLink(paths: paths, connector: connector, terminals: terminals, options: o)
        let ended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            link.run()
            ended.signal()
        }
        let deadline = Date().addingTimeInterval(3)
        var reached = false
        while Date() < deadline {
            if done(CodexLinkStatus.load(paths)) {
                reached = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        link.stop()
        XCTAssertEqual(ended.wait(timeout: .now() + 3), .success, "stops when told")
        return (link, reached)
    }

    let codex = FakeTerminals([CodexTerminalProcess(pid: 4242, cwd: "/Users/demo/code", args: ["codex"])])

    func testItConnectsAndSaysSo() {
        let connector = FakeConnector(daemon)
        let (_, reached) = running(connector, terminals: codex) { $0?.connected == true }
        XCTAssertTrue(reached)
        let status = CodexLinkStatus.load(paths)
        XCTAssertEqual(status?.judgeModel, "gpt-6-luna", "the smallest offered, whatever the list's order")
        XCTAssertEqual(status?.serverVersion, "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)")
        XCTAssertEqual(status?.connected, false, "let go when stopped")
        XCTAssertEqual(status?.stopped, true)
        XCTAssertNil(status?.lastError, "closing it isn't an error")
        XCTAssertTrue(daemon.closed)
        XCTAssertEqual(daemon.calls.first?.method, "initialize")
    }

    func testNoTerminalNoConnection() {
        let connector = FakeConnector(daemon)
        let (_, reached) = running(connector, terminals: FakeTerminals()) { $0 != nil }
        XCTAssertTrue(reached)
        XCTAssertEqual(connector.connects, 0)
        XCTAssertEqual(CodexLinkStatus.load(paths)?.connected, false)
    }

    func testNoAppServerNoConnection() {
        let connector = FakeConnector(daemon)
        connector.isAvailable = false
        let (_, reached) = running(connector, terminals: codex) { $0 != nil }
        XCTAssertTrue(reached)
        XCTAssertEqual(connector.connects, 0)
    }

    func testAHandshakeThatFailsIsTriedAgainAndSaysWhy() {
        daemon.failing["initialize"] = .rpc(code: -32600, message: "not now")
        let connector = FakeConnector(daemon)
        let (_, reached) = running(connector, terminals: codex) { _ in connector.connects >= 3 }
        XCTAssertTrue(reached)
        XCTAssertEqual(CodexLinkStatus.load(paths)?.lastError, "not now (-32600)")
        XCTAssertEqual(CodexLinkStatus.load(paths)?.connected, false)
    }

    func testItLetsGoWhenTheTerminalsAreGone() {
        let terminals = FakeTerminals(codex.terminals())
        let connector = FakeConnector(daemon)
        let (_, reached) = running(connector, terminals: terminals, idleDisconnect: 0.1) { status in
            if status?.connected == true { terminals.set([]) }
            return self.daemon.closed
        }
        XCTAssertTrue(reached, "disconnected with no Codex terminal")
        XCTAssertEqual(connector.connects, 1, "and waits for one before connecting again")
    }

    func testStoppingSaysSoAtOnce() {
        // The process may end before run() gets back to writing: stop() itself writes.
        let link = CodexLink(paths: paths, connector: FakeConnector(daemon), terminals: codex)
        link.stop()
        let status = CodexLinkStatus.load(paths)
        XCTAssertEqual(status?.stopped, true)
        XCTAssertEqual(status?.isRunning(now: Date()), false)
    }

    func testAnEventFromAnOldConnectionIsIgnored() {
        let link = CodexLink(paths: paths, connector: FakeConnector(daemon), terminals: codex)
        let old = link.newConnection()
        _ = link.newConnection()
        link.handle(.closed("the old one ended"), from: old)
        XCTAssertFalse(link.isClosed)
        XCTAssertNil(CodexLinkStatus.load(paths)?.lastError)
    }
}
