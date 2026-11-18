import ContextGuardCore
import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCodexLink

/// The Codex app link against a fake app (its router and one window) and a real rollout file:
/// what it follows, what it sends the window, and what it leaves alone.
final class CodexAppLinkTests: XCTestCase {
    let dir = TempDir()
    let clock = TestClock()
    let id = CodexLine.thread
    let cwd = "/Users/demo/code"
    let daemon = FakeDaemon()
    let drivers = CodexDrivers()
    var paths: Paths!
    var codexHome: String!
    var log: Transcript!
    var app: FakeCodexApp!
    var launcher: FakeLauncher!
    var link: CodexAppLink!
    var connection: CodexAppConnection!

    override func setUpWithError() throws {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        codexHome = dir.file("codex").path
        try FileManager.default.createDirectory(atPath: locks, withIntermediateDirectories: true)
        log = Transcript(dir, name: "rollout-\(id).jsonl")
        log.append(CodexLine.meta(originator: CodexMeta.appOriginator))
        load(id)
        app = try FakeCodexApp()
        app.open(id, cwd: cwd, rollout: log.path)
        launcher = FakeLauncher(daemon)
        try makeLink()
    }

    override func tearDown() {
        connection?.close()
    }

    func makeLink(onlyCwd: String? = nil) throws {
        var o = CodexAppLink.Options(onlyCwd: onlyCwd)
        o.inline = true
        o.callTimeout = 2
        o.judgeTimeout = 2
        let clock = self.clock
        let link = CodexAppLink(paths: paths, connector: NoCodexApp(), launcher: launcher, codexHome: codexHome,
                                drivers: drivers, options: o, clock: { clock.now }, judgeFolder: dir.file("judge"))
        let gen = link.newConnection()
        connection = CodexAppConnection(transport: app.router.client) { [weak link] in link?.handle($0, from: gen) }
        XCTAssertEqual(try connection.start(timeout: 2), FakeCodexApp.me)
        self.link = link
    }

    var locks: String { (codexHome as NSString).appendingPathComponent("thread-writer-locks") }

    /// Codex has the chat loaded: its writer lock is there.
    func load(_ thread: String) {
        FileManager.default.createFile(atPath: (locks as NSString).appendingPathComponent("\(thread).lock"), contents: nil)
    }

    func unload(_ thread: String) {
        try? FileManager.default.removeItem(atPath: (locks as NSString).appendingPathComponent("\(thread).lock"))
    }

    var state: SessionState? { SessionState.load(id, paths) }

    func pass() { link.pass(connection, now: clock.now) }

    /// Everything the link sent so far has reached the app.
    func flush() {
        _ = try? connection.request(.ownerDiscovery, params: ["flush": true], timeout: 2)
    }

    func waitFor(_ what: String, timeout: TimeInterval = 2, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// A pass asks to follow the chat; the window streams it.
    func follow(_ thread: String? = nil) {
        let thread = thread ?? id
        pass()
        waitFor("the window streams \(thread)") {
            link.chat(thread)?.owner == FakeCodexApp.window && link.chat(thread)?.state.isCurrent == true
        }
    }

    /// The window says the chat is working or not, and the link has seen it.
    func setStatus(_ status: String) {
        app.setStatus(id, status)
        waitFor("the link sees \(status)") { link.chat(id)?.state.status == status }
    }

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

    func text(_ nonce: String) -> String { "\(Config.defaultMessage) [\(nonce)]" }

    /// At 160k you said Yes; the save message went to the window and Codex ran it. Returns its nonce.
    func sendTheSaveMessage() throws -> String {
        try configure()
        log.append(CodexLine.turn("Add a settings screen", reply: "Added it.", tokens: 160_000))
        try settle()
        follow()
        pass()
        XCTAssertEqual(state?.phase, .asking)
        XCTAssertTrue(app.requests(.startTurn).isEmpty, "nothing before you answer")
        try answerYes()
        pass()
        let nonce = try XCTUnwrap(state?.sentNonce)
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(state?.sentVia, .turn)
        let sent = try XCTUnwrap(app.requests(.startTurn).last)
        XCTAssertEqual(sent["targetClientId"]?.string, FakeCodexApp.window)
        XCTAssertEqual(sent["version"]?.int, 2)
        XCTAssertEqual(sent["params"], CodexAppRequests.startTurn(id, text: text(nonce)))
        // The window runs it as your next prompt, under an id of its own.
        setStatus("active")
        log.append(CodexLine.taskStarted(), CodexLine.prompt(text(nonce)))
        pass()
        XCTAssertNotNil(state?.confirmedAt)
        return nonce
    }

    /// The chat saved and went idle.
    func finishSaving() throws {
        log.append(CodexLine.toolCall(), CodexLine.toolOutput("main -> main"), CodexLine.reply("Pushed and saved. Ready for compaction."),
                   CodexLine.tokens(165_000), CodexLine.taskComplete())
        setStatus("idle")
        try settle()
    }

    // MARK: - Following

    func testAChatOpenInTheAppIsFollowedAndGuarded() throws {
        daemon.config = ["model_auto_compact_token_limit": 180_000, "model_post_turn_compact_threshold_percent": 70, "mcp_servers": .null]
        try configure()
        log.append(CodexLine.turn("Add a settings screen", reply: "Added it.", tokens: 30_000))
        follow()
        pass()
        let s = try XCTUnwrap(state)
        XCTAssertEqual(s.codex?.surface, .app)
        XCTAssertEqual(s.codex?.originator, CodexMeta.appOriginator)
        XCTAssertEqual(s.codex?.status, "idle")
        XCTAssertEqual(s.codex?.attached, true)
        XCTAssertTrue(s.guarded)
        XCTAssertEqual(s.title, "Settings screen")
        XCTAssertEqual(s.cwd, cwd)
        XCTAssertEqual(s.transcriptPath, log.path)
        XCTAssertEqual(s.tokens, 30_000, "sizes come from the rollout")
        XCTAssertTrue(drivers.appHas(id))
        XCTAssertEqual(link.status(stopped: false).chats, 1)
        flush()
        XCTAssertEqual(app.follows(id), 1, "asked once: the window streams it from then on")
        // Codex's settings for the chat's folder, from the app's own Codex.
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(daemon.calls("config/read").first?["cwd"]?.string, cwd)
        XCTAssertEqual(s.codex?.autoCompactAt, 180_000)
        XCTAssertEqual(s.codex?.postTurnCompactPercent, 70)
    }

    func testAChatNobodyHasOpenIsAskedForAgainNowAndThen() throws {
        let other = "01a1c7f0-0000-7000-8000-0000000000a1"
        load(other)
        pass()
        flush()
        XCTAssertEqual(app.follows(other), 1)
        XCTAssertNil(link.chat(other)?.owner)
        pass()
        flush()
        XCTAssertEqual(app.follows(other), 1, "not at every pass")
        clock.advance(31)
        pass()
        flush()
        XCTAssertEqual(app.follows(other), 2)
        XCTAssertEqual(app.follows(id), 1, "one that's streamed isn't asked for again")

        // A new window may have it open: asked at once.
        app.windowOpens("owner-2")
        waitFor("asked for again") { link.chat(other)?.askedAt == nil }
        pass()
        flush()
        XCTAssertEqual(app.follows(other), 3)

        // Codex unloads it: forgotten.
        unload(other)
        pass()
        XCTAssertNil(link.chat(other))
        XCTAssertNil(SessionState.load(other, paths), "never looked at")
    }

    func testAMissedChangeAsksForTheChatAfresh() {
        follow()
        app.set(id, "threadRuntimeStatus", FakeCodexApp.status("active"), missed: true)
        waitFor("dropped") { link.chat(id)?.state.isCurrent == false }
        XCTAssertEqual(link.chat(id)?.owner, FakeCodexApp.window)
        pass()
        waitFor("streamed afresh") { link.chat(id)?.state.isCurrent == true }
        XCTAssertEqual(link.chat(id)?.state.status, "active")
        flush()
        XCTAssertEqual(app.follows(id), 2)
    }

    func testChangesFromAWindowThatNoLongerHasItAreIgnored() {
        follow()
        app.set(id, "threadRuntimeStatus", FakeCodexApp.status("active"), from: "owner-0")
        app.set(id, "title", "Settings screen, part 2")
        waitFor("the owner's change") { link.chat(id)?.state.title == "Settings screen, part 2" }
        XCTAssertEqual(link.chat(id)?.state.status, "idle")
        XCTAssertEqual(link.chat(id)?.state.isCurrent, true)
    }

    func testOnlyTheFolderAskedFor() throws {
        connection.close()
        let elsewhere = "01a1c7f0-0000-7000-8000-0000000000b1"
        let r = Transcript(dir, name: "rollout-\(elsewhere).jsonl")
        r.append(CodexLine.meta(id: elsewhere, cwd: "/Users/demo/code-2", originator: CodexMeta.appOriginator))
        load(elsewhere)
        app = try FakeCodexApp()
        app.open(id, cwd: cwd, rollout: log.path)
        app.open(elsewhere, cwd: "/Users/demo/code-2", rollout: r.path)
        try makeLink(onlyCwd: "/Users/demo/code")
        follow()
        follow(elsewhere)
        pass()
        XCTAssertNotNil(state)
        XCTAssertNil(SessionState.load(elsewhere, paths), "a folder whose name only starts the same")
    }

    // MARK: - The save message

    func testTheSaveMessageGoesToTheWindowThatHasTheChatOpen() throws {
        _ = try sendTheSaveMessage()
        pass()
        XCTAssertEqual(app.requests(.startTurn).count, 1, "once")
    }

    func testASaveMessageTheWindowRefusesGoesBackToWaiting() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        follow()
        pass()
        try answerYes()
        app.fail(.startTurn, with: "Cannot read properties of null (reading 'id')")
        pass()
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertEqual(state?.resendCount, 0, "a refusal isn't a lost send")
        XCTAssertEqual(link.chat(id)?.owner, FakeCodexApp.window, "the window is still there")

        app.fail(.startTurn, with: nil)
        pass()
        XCTAssertEqual(state?.phase, .sent)
        let sent = app.requests(.startTurn)
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent.first?["params"], sent.last?["params"], "a new message")
    }

    func testASaveMessageForAChatNoWindowHasOpenWaits() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        follow()
        pass()
        try answerYes()
        app.fail(.startTurn, with: "no-client-found")
        pass()
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertNil(link.chat(id)?.owner, "followed afresh")
        pass()
        XCTAssertEqual(app.requests(.startTurn).count, 1, "not until a window streams it again")
        XCTAssertFalse(drivers.appHas(id))
    }

    func testASendThatMayHaveGoneInIsLeftAsSent() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        follow()
        pass()
        try answerYes()
        app.fail(.startTurn, with: "request-timeout")
        pass()
        XCTAssertEqual(state?.phase, .sent, "the rollout shows whether it did")
    }

    /// A long turn of yours passes 60% (160k) in the app, and you said Yes while it runs.
    func yesWhileATurnRuns() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 100_000))
        log.append(CodexLine.taskStarted(at: "2026-11-11T00:20:00.000Z"), CodexLine.prompt("Refactor the billing API"),
                   CodexLine.toolCall(), CodexLine.tokens(160_000))
        app.open(id, cwd: cwd, rollout: log.path, status: "active")
        follow()
        pass()
        XCTAssertEqual(state?.phase, .asking)
        try answerYes()
    }

    func testMidTurnTheSaveMessageGoesIntoTheRunningTurn() throws {
        try yesWhileATurnRuns()
        pass()
        let nonce = try XCTUnwrap(state?.sentNonce)
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertEqual(state?.sentVia, .step)
        XCTAssertTrue(app.requests(.startTurn).isEmpty, "not left for after the turn")
        let steer = try XCTUnwrap(app.requests(.steerTurn).first)
        XCTAssertEqual(steer["targetClientId"]?.string, FakeCodexApp.window)
        XCTAssertEqual(steer["version"]?.int, 1)
        XCTAssertEqual(steer["params"], CodexAppRequests.steerTurn(
            id, messageId: CodexClientID.make(nonce: nonce, kind: "save"), text: text(nonce), cwd: cwd))
        pass()
        XCTAssertEqual(app.requests(.steerTurn).count, 1, "once")
    }

    func testOneTheWindowWontTakeMidTurnGoesInWhenTheTurnEnds() throws {
        try yesWhileATurnRuns()
        app.fail(.steerTurn, with: "Cannot read properties of null (reading 'id')")
        pass()
        XCTAssertEqual(state?.phase, .queued)
        pass()
        XCTAssertEqual(app.requests(.steerTurn).count, 1, "not into that turn again")
        XCTAssertTrue(app.requests(.startTurn).isEmpty)

        log.append(CodexLine.reply("Refactored."), CodexLine.tokens(170_000), CodexLine.taskComplete())
        setStatus("idle")
        pass()
        XCTAssertEqual(app.requests(.startTurn).count, 1, "as the next prompt")
        XCTAssertEqual(state?.phase, .sent)
    }

    // MARK: - Judge, compaction, continue

    func testFromAskingToContinueThroughTheApp() throws {
        let nonce = try sendTheSaveMessage()
        try finishSaving()
        pass()

        // The judge on a throwaway thread of the app's own Codex, then the compaction through the
        // window, in one pass.
        let judge = try XCTUnwrap(daemon.calls("thread/start").first)
        XCTAssertEqual(judge["model"]?.string, "gpt-6-luna")
        XCTAssertEqual(judge["ephemeral"]?.bool, true)
        XCTAssertEqual(judge["cwd"]?.string, link.judgeFolder.path)
        let question = try XCTUnwrap(daemon.calls("turn/start").first?["input"]?[0]?["text"]?.string)
        XCTAssertTrue(question.contains("Pushed and saved. Ready for compaction."))
        let compact = try XCTUnwrap(app.requests(.compactThread).first)
        XCTAssertEqual(compact["targetClientId"]?.string, FakeCodexApp.window)
        XCTAssertEqual(compact["version"]?.int, 1)
        XCTAssertEqual(compact["params"], CodexAppRequests.compact(id))
        XCTAssertEqual(state?.followUp?.stage, .compacting)
        XCTAssertEqual(state?.followUp?.note, "pushed and saved")

        setStatus("active")
        pass()
        XCTAssertEqual(app.requests(.compactThread).count, 1, "once")

        log.append(CodexLine.compactionTurn(after: 18_000))
        setStatus("idle")
        try settle()
        pass()
        XCTAssertEqual(state?.tokens, 18_000)
        let next = try XCTUnwrap(app.requests(.startTurn).last)
        XCTAssertEqual(next["targetClientId"]?.string, FakeCodexApp.window)
        XCTAssertEqual(next["params"], CodexAppRequests.startTurn(id, text: "continue now"))
        XCTAssertEqual(state?.followUp?.stage, .done)
        XCTAssertEqual(state?.followUp?.nonce, nonce)
        pass()
        XCTAssertEqual(app.requests(.startTurn).count, 2, "the save message and continue, once each")
    }

    func testATurnStartedWhileItWasJudgedHoldsTheCompaction() throws {
        _ = try sendTheSaveMessage()
        try finishSaving()
        // You type in the app while the judge thinks.
        let app = self.app!, link = self.link!, id = self.id
        daemon.onCall = { method, params in
            guard method == "turn/start", params["threadId"]?.string != id else { return }
            app.setStatus(id, "active")
            let end = Date().addingTimeInterval(2)
            while link.chat(id)?.state.status != "active", Date() < end { Thread.sleep(forTimeInterval: 0.005) }
        }
        pass()
        XCTAssertEqual(daemon.calls("thread/start").count, 1)
        XCTAssertTrue(app.requests(.compactThread).isEmpty, "it would have cut your turn off")
        XCTAssertEqual(state?.followUp?.stage, .checking)
        XCTAssertEqual(state?.codex?.status, "active", "looked at again after the judge, not as it was before")
    }

    func testACompactionTheWindowRefusesIsReported() throws {
        _ = try sendTheSaveMessage()
        try finishSaving()
        app.fail(.compactThread, with: "Cannot read properties of null (reading 'id')")
        pass()
        XCTAssertEqual(app.requests(.compactThread).count, 1)
        XCTAssertEqual(state?.followUp?.stage, .checking, "judged again before another try")
        XCTAssertEqual(state?.followUp?.note, "compacting failed: Cannot read properties of null (reading 'id')")
        XCTAssertEqual(state?.followUp?.compactAttempts, 1)
    }

    // MARK: - Left alone

    func testAChatATerminalShowsIsTheTerminalsToDrive() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        follow()
        pass()
        try answerYes()
        drivers.setTerminal([id])
        pass()
        XCTAssertTrue(app.requests(.startTurn).isEmpty)
        XCTAssertEqual(state?.phase, .asking, "not looked at: the terminal's connection takes your answer")
        XCTAssertEqual(state?.codex?.loaded, true, "not closing either")
        clock.advance(CodexRunner.closedAfter + 1)
        pass()
        XCTAssertFalse(state?.ended ?? true)
    }

    func testAnAppThatSpeaksAnotherVersionIsOnlyWatched() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        follow()
        pass()
        try answerYes()
        app.set(id, "title", "Renamed", version: 14)
        waitFor("noticed") { link.status(stopped: false).unsupported != nil }
        XCTAssertEqual(link.status(stopped: false).unsupported,
                       "the Codex app sends thread-stream-state-changed version 14; this Context Guard reads version 13")
        pass()
        XCTAssertTrue(app.requests(.startTurn).isEmpty)
        XCTAssertEqual(state?.codex?.attached, false)
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertTrue(state?.guarded ?? false, "still watched")
    }

    func testARequestInAnotherVersionStopsActing() throws {
        try configure()
        log.append(CodexLine.turn("two", reply: "ok", tokens: 160_000))
        follow()
        pass()
        try answerYes()
        app.fail(.startTurn, with: "request-version-mismatch")
        pass()
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertEqual(link.status(stopped: false).unsupported,
                       "the Codex app speaks another version of thread-follower-start-turn than 2")
        app.fail(.startTurn, with: nil)
        pass()
        XCTAssertEqual(app.requests(.startTurn).count, 1, "nothing more is sent")
        XCTAssertEqual(state?.codex?.attached, false)
    }

    // MARK: - Ending

    func testAnArchivedChatEndsAtOnceAndOpensAgainUnarchived() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        follow()
        pass()
        XCTAssertEqual(state?.ended, false)
        app.archive(id, cwd: cwd)
        waitFor("let go") { link.chat(id)?.owner == nil }
        pass()
        XCTAssertEqual(state?.ended, true)
        XCTAssertEqual(state?.endReason, "archived")
        XCTAssertFalse(drivers.appHas(id))
        flush()
        XCTAssertEqual(app.follows(id), 1, "not asked for again at once")

        app.open(id, cwd: cwd, rollout: log.path)
        app.unarchive(id)
        waitFor("asked for again") { link.chat(id)?.askedAt == nil }
        follow()
        pass()
        XCTAssertEqual(state?.ended, false)
        XCTAssertNil(state?.endReason)
    }

    func testADeletedChatEndsAtOnce() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        follow()
        pass()
        try FileManager.default.removeItem(atPath: log.path)
        app.stopStreaming(id)
        waitFor("let go") { link.chat(id)?.owner == nil }
        pass()
        XCTAssertEqual(state?.ended, true)
        XCTAssertEqual(state?.endReason, "deleted")
    }

    func testAChatWhoseRolloutMovedToTheArchiveEndsArchived() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        follow()
        pass()
        let archive = (codexHome as NSString).appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: log.path, toPath: (archive as NSString).appendingPathComponent(log.url.lastPathComponent))
        app.stopStreaming(id)
        waitFor("let go") { link.chat(id)?.owner == nil }
        pass()
        XCTAssertEqual(state?.ended, true)
        XCTAssertEqual(state?.endReason, "archived")
    }

    func testAChatWhoseWindowClosedClosesAfterAWhile() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        follow()
        pass()
        app.windowCloses()
        waitFor("let go") { link.chat(id)?.owner == nil }
        pass()
        XCTAssertEqual(state?.codex?.loaded, false)
        XCTAssertEqual(state?.ended, false, "it may open again in a moment")
        XCTAssertEqual(state?.codex?.surface, .app)
        clock.advance(CodexRunner.closedAfter + 1)
        pass()
        XCTAssertEqual(state?.ended, true)
        XCTAssertEqual(state?.endReason, "closed")
    }

    func testWithTheAppGoneItsChatsCloseAfterAWhile() throws {
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        follow()
        pass()
        app.quit()
        waitFor("the connection ends") { link.isClosed }
        link.lostEveryOwner()
        XCTAssertFalse(drivers.appHas(id))
        link.sweep(now: clock.now, except: [], nil)
        XCTAssertEqual(state?.codex?.loaded, false)
        XCTAssertEqual(state?.ended, false)
        clock.advance(CodexRunner.closedAfter + 1)
        link.sweep(now: clock.now, except: [], nil)
        XCTAssertEqual(state?.ended, true)
    }

    // MARK: - The app's own Codex

    func testTheAppsOwnCodexStopsWhenNoChatIsOpenAndStartsAgainWhenOneIs() throws {
        follow()
        pass()
        XCTAssertEqual(launcher.launches, 1)
        app.windowCloses()
        waitFor("let go") { link.chat(id)?.owner == nil }
        pass()
        XCTAssertFalse(daemon.closed)
        clock.advance(301)
        pass()
        XCTAssertTrue(daemon.closed, "nothing to judge for five minutes")

        app.open(id, cwd: cwd, rollout: log.path)
        clock.advance(31)
        follow()
        pass()
        XCTAssertEqual(launcher.launches, 2)
        XCTAssertFalse(daemon.closed)
    }

    func testWithoutTheAppsOwnCodexChatsAreStillLookedAtAndItIsTriedAgainLater() throws {
        launcher.failure = .unavailable("the Codex app's own codex wasn't found")
        try configure()
        log.append(CodexLine.turn("one", reply: "ok", tokens: 30_000))
        follow()
        pass()
        XCTAssertEqual(state?.codex?.surface, .app, "on Codex's defaults")
        XCTAssertNil(state?.codex?.autoCompactAt)
        XCTAssertEqual(launcher.launches, 1)
        pass()
        XCTAssertEqual(launcher.launches, 1, "not at every look")
        launcher.failure = nil
        clock.advance(61)
        pass()
        XCTAssertEqual(launcher.launches, 2)
    }
}

/// The app link's own loop: joining the app, letting go when it quits, stopping.
final class CodexAppLinkLoopTests: XCTestCase {
    func testItJoinsFollowsAndLetsGoWhenTheAppQuits() throws {
        let dir = TempDir()
        let id = CodexLine.thread
        let paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        let codexHome = dir.file("codex")
        let locks = codexHome.appendingPathComponent("thread-writer-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locks.appendingPathComponent("\(id).lock").path, contents: nil)
        let log = Transcript(dir, name: "rollout-\(id).jsonl")
        log.append(CodexLine.meta(originator: CodexMeta.appOriginator))
        log.append(CodexLine.turn("Add a settings screen", reply: "Added it.", tokens: 30_000))

        let app = try FakeCodexApp()
        app.open(id, cwd: "/Users/demo/code", rollout: log.path)
        let host = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        let daemon = FakeDaemon()
        let launcher = FakeLauncher(daemon)
        let drivers = CodexDrivers()
        var o = CodexAppLink.Options()
        o.pass = 0.02
        o.retry = 0.02
        let link = CodexAppLink(paths: paths, connector: OneCodexApp(CodexAppRouter(transport: app.router.client, hostExecutable: host)),
                                launcher: launcher, codexHome: codexHome.path, drivers: drivers, options: o,
                                judgeFolder: dir.file("judge"))
        let changes = Counter()
        link.onStatusChange = { changes.add() }
        let ended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            link.run()
            ended.signal()
        }

        waitFor("joined and following") {
            link.status(stopped: false).connected && link.chat(id)?.owner == FakeCodexApp.window
                && SessionState.load(id, paths)?.codex?.surface == .app
        }
        XCTAssertEqual(link.status(stopped: false).chats, 1)
        XCTAssertTrue(drivers.appHas(id))
        XCTAssertEqual(launcher.hosts.first, host, "the app server of the app that runs the router")
        XCTAssertGreaterThan(changes.count, 0)

        app.quit()
        waitFor("let go") { !link.status(stopped: false).connected && !drivers.appHas(id) }
        XCTAssertNil(link.chat(id))
        XCTAssertEqual(link.status(stopped: false).lastError, "the Codex app closed the connection")

        link.stop()
        XCTAssertEqual(ended.wait(timeout: .now() + 3), .success, "stops when told")
        XCTAssertTrue(daemon.closed, "its own Codex stops with it")
        XCTAssertFalse(link.status(stopped: false).connected)
    }

    func waitFor(_ what: String, timeout: TimeInterval = 3, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

#if !os(Windows)
/// The app's own Codex: its standard input and output, and where it's found.
final class CodexAppServerTests: XCTestCase {
    let dir = TempDir()

    func testLinesGoOutAndComeBack() throws {
        let c = try StdioChannel.start(executable: "/bin/cat", arguments: [], environment: [:], directory: dir.url)
        try c.send(text: #"{"id":1}"#)
        try c.send(text: #"{"id":2}"#)
        XCTAssertEqual(try c.receive(), #"{"id":1}"#)
        XCTAssertEqual(try c.receive(), #"{"id":2}"#)
        c.end()
        XCTAssertNil(try c.receive(), "cat ends with its input")
        XCTAssertThrowsError(try c.send(text: "{}")) {
            XCTAssertEqual($0 as? CodexLinkError, .closed("the app server has stopped"))
        }
        c.release()
    }

    func testBlankLinesAreSkippedAndAnUnfinishedOneDropped() throws {
        let c = try StdioChannel.start(executable: "/bin/sh", arguments: ["-c", #"printf '{"a":1}\n\n{"b":2}\n{"c":'"#],
                                       environment: [:], directory: dir.url)
        XCTAssertEqual(try c.receive(), #"{"a":1}"#)
        XCTAssertEqual(try c.receive(), #"{"b":2}"#)
        XCTAssertNil(try c.receive())
        c.release()
    }

    func testAProgramThatIsNotThereSaysSo() {
        XCTAssertThrowsError(try StdioChannel.start(executable: dir.file("nothing").path, arguments: [], environment: [:],
                                                    directory: dir.url)) {
            guard case .unavailable? = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
    }

    func testTheAppServerIsTheAppsOwnCodexOnTheAppsCodexFolder() throws {
        let bundle = dir.file("Demo.app")
        let codex = bundle.appendingPathComponent(CodexAppBundle.inBundle)
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Answers initialize with where it runs.
        let script = """
        #!/bin/sh
        [ "$1" = app-server ] || exit 2
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) printf '{"id":1,"result":{"userAgent":"%s|%s"}}\\n' "$CODEX_HOME" "$(pwd -P)" ;;
          esac
        done
        """
        try script.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let folder = dir.file("judge")
        let launcher = CodexAppServerLauncher(codexHome: "/Users/demo/.codex", folder: folder)
        let daemon = try launcher.launch(hostExecutable: bundle.appendingPathComponent("Contents/MacOS/ChatGPT").path) { _ in }
        defer { daemon.close() }
        let agent = try XCTUnwrap(daemon.initialize(version: "1.2.0", timeout: 5))
        let parts = agent.split(separator: "|").map(String.init)
        XCTAssertEqual(parts.first, "/Users/demo/.codex", "on the app's Codex folder, so its sign-in")
        XCTAssertEqual(parts.last.map { ($0 as NSString).lastPathComponent }, "judge", "in the judge's empty folder")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testTheCodexInTheAppThatRunsTheRouterComesFirst() {
        let beta = "/Users/demo/Apps/ChatGPT Beta.app"
        let inBeta = beta + "/" + CodexAppBundle.inBundle
        let usual = "/Applications/ChatGPT.app/" + CodexAppBundle.inBundle
        let yours = ("~/Applications/ChatGPT.app" as NSString).expandingTildeInPath + "/" + CodexAppBundle.inBundle
        XCTAssertEqual(CodexAppBundle.codexBinary(hostExecutable: beta + "/Contents/MacOS/ChatGPT", isExecutable: { _ in true }), inBeta)
        XCTAssertEqual(CodexAppBundle.codexBinary(hostExecutable: beta + "/Contents/MacOS/ChatGPT", isExecutable: { $0 == usual }), usual,
                       "the app where it usually is when that one has none")
        // Another Codex client of yours runs the router: not an app's program.
        XCTAssertEqual(CodexAppBundle.codexBinary(hostExecutable: "/usr/local/bin/codex", isExecutable: { _ in true }), usual)
        XCTAssertEqual(CodexAppBundle.codexBinary(hostExecutable: nil, isExecutable: { $0 == yours }), yours)
        XCTAssertNil(CodexAppBundle.codexBinary(hostExecutable: beta + "/Contents/MacOS/ChatGPT", isExecutable: { _ in false }))
    }
}
#else
final class CodexAppServerTests: XCTestCase {
    func testTheCodexBesideTheAppsProgram() {
        let app = #"C:\Program Files\WindowsApps\OpenAI.Codex_26.1111.0.0_x64__2p2nqsd0c76g0\app"#
        XCTAssertEqual(CodexAppBundle.codexBinary(hostExecutable: app + #"\ChatGPT.exe"#, isExecutable: { _ in true }),
                       app + #"\resources\codex.exe"#)
        XCTAssertNil(CodexAppBundle.codexBinary(hostExecutable: app + #"\ChatGPT.exe"#, isExecutable: { _ in false }))
        XCTAssertNil(CodexAppBundle.codexBinary(hostExecutable: nil, isExecutable: { _ in true }))
    }
}
#endif

// MARK: - Fakes

/// The Codex app, faked: its router, over a socket pair, and one window (`owner-1`) with the chats
/// `open` gives it. The window streams a chat to whoever asks to follow it, and answers requests
/// (`fail` makes it refuse one).
final class FakeCodexApp: @unchecked Sendable {
    static let window = "owner-1"
    /// The id the router gives Context Guard.
    static let me = "cg-1"

    private(set) var router: FakeRouter!
    private let lock = NSLock()
    private let sendLock = NSLock()
    private var states: [String: [String: JSONValue]] = [:]
    private var revisions: [String: Int] = [:]
    private var failures: [String: FakeRouterError] = [:]

    init() throws {
        router = try FakeRouter { [weak self] message, _ in self?.answer(message) }
    }

    static func status(_ s: String) -> JSONValue {
        s == "active" ? ["type": "active", "activeFlags": []] : ["type": .string(s)]
    }

    /// The chat is open in the window.
    func open(_ id: String, cwd: String, rollout: String?, status: String = "idle") {
        lock.lock()
        states[id] = [
            "id": .string(id), "title": "Settings screen", "cwd": .string(cwd), "latestModel": "gpt-6-luna",
            "source": "vscode", "threadSource": "user", "ephemeral": false, "historyMode": "paginated",
            "rolloutPath": rollout.map { .string($0) } ?? .null, "threadRuntimeStatus": Self.status(status),
            "latestTokenUsageInfo": ["last": ["totalTokens": 18_804], "modelContextWindow": 258_400],
            "turnHistory": ["history": ["entitiesByKey": [:], "islands": []]],
        ]
        lock.unlock()
    }

    /// Requests the window refuses with `error` (nil: it takes them again).
    func fail(_ method: CodexAppMethod, with error: FakeRouterError?) {
        lock.lock()
        failures[method.name] = error
        lock.unlock()
    }

    /// One field of the chat changes and the window streams the change. `missed`: the link misses
    /// the change before it. `from` another window: one that streamed it before (nothing changes).
    func set(_ id: String, _ field: String, _ value: JSONValue, missed: Bool = false, version: Int = 13,
             from source: String = window) {
        lock.lock()
        let current = revisions[id] ?? 0
        let base = current + (missed ? 1 : 0)
        if source == Self.window {
            states[id]?[field] = value
            revisions[id] = base + 1
        }
        lock.unlock()
        send(broadcast("thread-stream-state-changed", version: version, from: source, [
            "conversationId": .string(id), "hostId": "local",
            "change": ["type": "patches", "baseRevision": .number(Double(base)), "revision": .number(Double(base + 1)),
                       "patches": [["op": "replace", "path": [.string(field)], "value": value]]],
        ]))
    }

    func setStatus(_ id: String, _ status: String) {
        set(id, "threadRuntimeStatus", Self.status(status))
    }

    /// The window stops streaming the chat (it closed it, or deleted it).
    func stopStreaming(_ id: String) {
        close(id)
        send(broadcast("thread-stream-following-changed", version: 1,
                       ["conversationId": .string(id), "hostId": "local", "following": false]))
    }

    func archive(_ id: String, cwd: String) {
        close(id)
        send(broadcast("thread-archived", version: 2, ["hostId": "local", "conversationId": .string(id), "cwd": .string(cwd)]))
    }

    func unarchive(_ id: String) {
        send(broadcast("thread-unarchived", version: 1, ["hostId": "local", "conversationId": .string(id)]))
    }

    /// The window closes, with every chat it had open.
    func windowCloses() {
        lock.lock()
        states = [:]
        lock.unlock()
        send(broadcast("client-status-changed", version: 0, from: nil,
                       ["clientId": .string(Self.window), "clientType": "electron", "status": "disconnected"]))
    }

    func windowOpens(_ client: String) {
        send(broadcast("client-status-changed", version: 0, from: nil,
                       ["clientId": .string(client), "clientType": "electron", "status": "connected"]))
    }

    /// The app quits: the router closes the connection.
    func quit() { router.close() }

    /// The requests for `method` the router got, whole.
    func requests(_ method: CodexAppMethod) -> [JSONValue] {
        router.received.filter { $0["type"]?.string == "request" && $0["method"]?.string == method.name }
    }

    /// How often Context Guard asked to follow the chat.
    func follows(_ id: String) -> Int {
        router.received.filter {
            $0["type"]?.string == "broadcast" && $0["method"]?.string == CodexAppMethod.followingChanged.name
                && $0["sourceClientId"]?.string == Self.me && $0["params"]?["conversationId"]?.string == id
                && $0["params"]?["following"]?.bool == true
        }.count
    }

    // MARK: -

    private func close(_ id: String) {
        lock.lock()
        states[id] = nil
        lock.unlock()
    }

    private func answer(_ m: JSONValue) {
        switch m["type"]?.string {
        case "request":
            let method = m["method"]?.string ?? ""
            if method == CodexAppMethod.initialize.name {
                return reply(m, .success(["clientId": .string(Self.me)]))
            }
            lock.lock()
            let failure = failures[method]
            lock.unlock()
            reply(m, failure.map { .failure($0) } ?? .success(["ok": true]))
        case "broadcast":
            guard m["method"]?.string == CodexAppMethod.followingChanged.name, m["params"]?["following"]?.bool == true,
                  let id = m["params"]?["conversationId"]?.string, let client = m["sourceClientId"]?.string else { return }
            snapshot(id, to: client)
        default:
            break
        }
    }

    /// The window sends the chat whole to `client`, if it has it open.
    private func snapshot(_ id: String, to client: String) {
        lock.lock()
        guard let state = states[id] else {
            lock.unlock()
            return
        }
        let revision = (revisions[id] ?? 0) + 1
        revisions[id] = revision
        lock.unlock()
        var b = broadcast("thread-stream-state-changed", version: 13, [
            "conversationId": .string(id), "hostId": "local",
            "change": ["type": "snapshot", "revision": .number(Double(revision)), "conversationState": .object(state)],
        ])
        b["targetClientIds"] = [.string(client)]
        send(.object(b))
    }

    private func broadcast(_ method: String, version: Int, from source: String? = window,
                           _ params: [String: JSONValue]) -> [String: JSONValue] {
        var b: [String: JSONValue] = ["type": "broadcast", "method": .string(method), "version": .number(Double(version)),
                                      "params": .object(params)]
        if let source { b["sourceClientId"] = .string(source) }
        return b
    }

    private func send(_ b: [String: JSONValue]) { send(.object(b)) }

    private func reply(_ request: JSONValue, _ result: Result<JSONValue, FakeRouterError>) {
        var r: [String: JSONValue] = ["type": "response", "requestId": request["requestId"] ?? .null,
                                      "method": request["method"] ?? .null, "handledByClientId": .string(Self.window)]
        switch result {
        case .success(let value):
            r["resultType"] = "success"
            r["result"] = value
        case .failure(let e):
            r["resultType"] = "error"
            r["error"] = .string(e.text)
        }
        send(.object(r))
    }

    /// One message at a time, whichever thread sends it.
    private func send(_ message: JSONValue) {
        sendLock.lock()
        router.send(message)
        sendLock.unlock()
    }
}

/// Starts the app's own Codex: the fake app server, every time (`failure` makes it fail).
final class FakeLauncher: CodexAppServerLaunching, @unchecked Sendable {
    let daemon: FakeDaemon
    private let lock = NSLock()
    private var calls: [String?] = []
    private var failing: CodexLinkError?

    init(_ daemon: FakeDaemon) {
        self.daemon = daemon
    }

    var failure: CodexLinkError? {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }

    var launches: Int { hosts.count }

    /// The router's program each launch was given.
    var hosts: [String?] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func launch(hostExecutable: String?, onEvent: @escaping @Sendable (CodexEvent) -> Void) throws -> CodexDaemon {
        lock.lock()
        calls.append(hostExecutable)
        let failing = self.failing
        lock.unlock()
        if let failing { throw failing }
        daemon.reopen()
        daemon.onEvent = onEvent
        return daemon
    }
}

/// No Codex app running.
struct NoCodexApp: CodexAppConnecting {
    func connect() throws -> CodexAppRouter { throw CodexLinkError.unavailable("the Codex app isn't running") }
}

/// The app's router, once; then the app has quit.
final class OneCodexApp: CodexAppConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var router: CodexAppRouter?

    init(_ router: CodexAppRouter) {
        self.router = router
    }

    func connect() throws -> CodexAppRouter {
        lock.lock()
        defer { lock.unlock() }
        guard let r = router else { throw CodexLinkError.unavailable("the Codex app isn't running") }
        router = nil
        return r
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func add() {
        lock.lock()
        n += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}
