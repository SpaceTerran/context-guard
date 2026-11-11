import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// Popups and notices as an app sees them: what opens, what closes and when, and what each says.
final class PresenterTests: XCTestCase {
    /// The panels an app would show, with room for `room` at once.
    final class FakeHost: PanelHost {
        var room = 5
        private(set) var open: [String] = []
        private(set) var notices: [String: NoticeContent] = [:]
        private(set) var rechecks: [TimeInterval] = []

        var openKeys: [String] { open }

        func openQuestion(_ id: String) -> Bool {
            guard open.count < room else { return false }
            open.append(Presenter.questionKey(id))
            return true
        }

        func showNotice(_ notice: NoticeContent, key: String) {
            open.append(key)
            notices[key] = notice
        }

        func close(_ key: String) { open.removeAll { $0 == key } }

        func recheck(after seconds: TimeInterval) { rechecks.append(seconds) }

        var questions: [String] { open.filter { $0.hasPrefix("question:") } }
        var noticeKeys: [String] { open.filter { $0.hasPrefix("notice:") } }
    }

    let dir = TempDir()
    let start = ProcessStart(seconds: 1_790_000_000, microseconds: 7)
    let t0 = Date(timeIntervalSince1970: 1_790_000_100)
    var paths: Paths!
    var probe: FakeProbe!
    var registry: FakeRegistry!
    var host: FakeHost!
    var installed = false

    override func setUp() {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        try? paths.ensureDirectories()
        probe = FakeProbe()
        registry = FakeRegistry()
        host = FakeHost()
        var c = Config()
        c.enabledAt = t0.addingTimeInterval(-3_600)
        try? c.save(paths)
    }

    func presenter(at now: Date? = nil) -> Presenter {
        let p = Presenter(paths: paths, registry: registry, probe: probe, codexLinkInstalled: { [unowned self] in installed }, now: now ?? t0)
        p.start(now: now ?? t0)
        p.reload(now: now ?? t0)
        return p
    }

    /// A Claude Code session whose process runs, idle unless `status` says otherwise.
    @discardableResult
    func session(_ n: Int, tokens: Int = 302_000, phase: Phase = .asking, cycle: Int = 1, status: String = "idle",
                 change: (inout SessionState) -> Void = { _ in }) throws -> String {
        let id = "00000000-0000-4000-8000-00000000000\(n)"
        let pid = Int32(4_000 + n)
        var s = SessionState(sessionId: id, now: t0)
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.cycle = cycle
        s.title = "Session \(n)"
        s.cwd = "/tmp/s\(n)"
        s.claudePid = pid
        s.claudeStart = start
        if phase == .asking { s.askedAt = t0 }
        change(&s)
        try s.save(paths)
        probe.set(pid, ProcessIdentity(start: start, hasTTY: true))
        registry.set(RegistryEntry(pid: pid, sessionId: id, kind: "interactive", entrypoint: "cli", status: status))
        return id
    }

    func edit(_ id: String, _ change: (inout SessionState) -> Void) throws {
        var s = try XCTUnwrap(SessionState.load(id, paths))
        change(&s)
        try s.save(paths)
    }

    // MARK: Questions

    func testAQuestionOpensOnce() throws {
        let id = try session(1)
        let p = presenter()
        p.sync(host, now: t0)
        XCTAssertEqual(host.questions, [Presenter.questionKey(id)])
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertEqual(host.questions.count, 1)
    }

    func testNoQuestionWhileOffOrUnwatchedOrBelowItsTurn() throws {
        try session(1, phase: .watching)
        let unwatched = try session(2)
        let p = presenter()
        try p.setWatched(unwatched, false)
        p.reload(now: t0)
        p.sync(host, now: t0)
        XCTAssertEqual(host.questions, [])
        try session(3)
        p.setEnabled(false, now: t0)
        p.reload(now: t0)
        p.sync(host, now: t0)
        XCTAssertEqual(host.questions, [], "off")
    }

    func testAQuestionWithNoRoomOpensOnceThereIs() throws {
        host.room = 0
        let id = try session(1)
        let p = presenter()
        p.sync(host, now: t0)
        XCTAssertEqual(host.questions, [])
        host.room = 5
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertEqual(host.questions, [Presenter.questionKey(id)])
    }

    func testHiddenUntilItAsksAgain() throws {
        let id = try session(1)
        let p = presenter()
        p.sync(host, now: t0)
        p.hideQuestion(id, host)
        XCTAssertEqual(host.questions, [])
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertEqual(host.questions, [], "hidden for this cycle")
        try edit(id) { $0.cycle = 2 }
        p.reload(now: t0)
        p.sync(host, now: t0.addingTimeInterval(2))
        XCTAssertEqual(host.questions, [Presenter.questionKey(id)], "a new cycle asks again")
    }

    func testTheMenuCanShowAHiddenQuestion() throws {
        let id = try session(1)
        let p = presenter()
        p.sync(host, now: t0)
        p.hideQuestion(id, host)
        p.showQuestion(id)
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertEqual(host.questions, [Presenter.questionKey(id)])
    }

    func testAnAnswerShowsItsProgressThenCloses() throws {
        let id = try session(1, status: "busy")
        let p = presenter()
        p.sync(host, now: t0)
        XCTAssertTrue(try p.answer(id, .yes, from: .popup, now: t0))
        XCTAssertEqual(Answer.load(id, paths)?.action, .yes)
        XCTAssertEqual(Answer.load(id, paths)?.source, .popup)
        XCTAssertEqual(p.replies[id], Reply(cycle: 1, action: .yes, at: t0))
        p.reload(now: t0)
        let info = try XCTUnwrap(p.session(id))
        XCTAssertEqual(p.progress(info), .nextStep, "busy: at its next step")
        p.sync(host, now: t0)
        XCTAssertEqual(host.questions.count, 1, "the popup stays to show it")
        XCTAssertEqual(try XCTUnwrap(host.rechecks.last), 45.05, accuracy: 0.001)
        p.sync(host, now: t0.addingTimeInterval(30))
        XCTAssertEqual(host.questions.count, 1)
        XCTAssertEqual(try XCTUnwrap(host.rechecks.last), 15.05, accuracy: 0.001)
        p.sync(host, now: t0.addingTimeInterval(45))
        XCTAssertEqual(host.questions, [], "shown long enough")
        p.sync(host, now: t0.addingTimeInterval(46))
        XCTAssertEqual(host.questions, [], "it no longer asks")
    }

    func testEachNewProgressStartsItsOwnLinger() throws {
        let id = try session(1, status: "busy")
        let p = presenter()
        p.sync(host, now: t0)
        try p.answer(id, .yes, from: .popup, now: t0)
        p.reload(now: t0)
        p.sync(host, now: t0)
        // The hook sends it and confirms it 40 s later: "sent" shows for 2.5 s from then.
        try edit(id) { s in
            s.phase = .sent
            s.appliedAnswerId = Answer.load(id, self.paths)?.id
            s.sentNonce = "cg-1"
            s.confirmedAt = self.t0
        }
        p.reload(now: t0)
        p.sync(host, now: t0.addingTimeInterval(40))
        XCTAssertEqual(p.progress(try XCTUnwrap(p.session(id))), .sent)
        XCTAssertEqual(host.questions.count, 1)
        p.sync(host, now: t0.addingTimeInterval(42))
        XCTAssertEqual(host.questions.count, 1)
        p.sync(host, now: t0.addingTimeInterval(42.5))
        XCTAssertEqual(host.questions, [])
        XCTAssertEqual(host.noticeKeys, [], "the popup showed the send, so no notice")
    }

    func testAQuestionThatGoesAwayCloses() throws {
        let id = try session(1)
        let p = presenter()
        p.sync(host, now: t0)
        try edit(id) { $0.phase = .watching }
        p.reload(now: t0)
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertEqual(host.questions, [])
    }

    func testAnswersForUnknownSessions() throws {
        let p = presenter()
        XCTAssertFalse(try p.answer("nope", .yes, from: .menu))
        XCTAssertFalse(try p.setWatched("nope", false))
        XCTAssertNil(Answer.load("nope", paths))
    }

    // MARK: Notices

    func testWhatsThereAtStartIsntAnnounced() throws {
        try session(1, phase: .sent) { s in
            s.sentNonce = "cg-old"
            s.followUp = FollowUp(nonce: "cg-old", now: self.t0)
        }
        let p = presenter()
        p.sync(host, now: t0)
        XCTAssertEqual(host.noticeKeys, [])
    }

    func testASendIsAnnounced() throws {
        let a = try session(1, phase: .watching)
        let b = try session(2, tokens: 512_000, phase: .later)
        let p = presenter()
        try edit(a) { s in
            s.phase = .sent
            s.sentNonce = "cg-a"
            s.sendReason = .manual
        }
        try edit(b) { s in
            s.phase = .sent
            s.sentNonce = "cg-b"
            s.sendReason = .later
            s.sentTokens = 512_000
        }
        p.reload(now: t0)
        p.sync(host, now: t0)
        XCTAssertEqual(host.notices["notice:cg-a"],
                       NoticeContent(symbol: .saving, tone: .accent, title: "Saving, then compacting", detail: "Session 1", caption: "/tmp/s1"))
        XCTAssertEqual(host.notices["notice:cg-b"]?.title, "Reached 512k: saving, then compacting")
        let shown = host.noticeKeys
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertEqual(host.noticeKeys, shown, "once")
    }

    func testEachFollowUpStageReplacesTheLast() throws {
        let id = try session(1, phase: .sent) { s in
            s.sentNonce = "cg-1"
            s.confirmedAt = self.t0
        }
        let p = presenter()
        try edit(id) { s in
            var f = FollowUp(nonce: "cg-1", now: self.t0)
            f.stage = .needsYou
            f.note = "asked which branch."
            s.followUp = f
        }
        p.reload(now: t0)
        p.sync(host, now: t0)
        let needs = "notice:follow-up:cg-1:needsYou"
        XCTAssertEqual(host.notices[needs], NoticeContent(symbol: .needsYou, tone: .warning, title: "Needs you before compacting",
                                                          detail: "Session 1", caption: "Asked which branch", captionWraps: true, seconds: 20))
        XCTAssertTrue(host.isOpen(needs))
        try edit(id) { $0.followUp?.stage = .compacting }
        p.reload(now: t0)
        p.sync(host, now: t0.addingTimeInterval(1))
        XCTAssertFalse(host.isOpen(needs), "answered, so it's closed")
        XCTAssertEqual(host.notices["notice:follow-up:cg-1:compacting"]?.caption, "/tmp/s1", "no reason: the location")
        try edit(id) { $0.followUp?.stage = .checking }
        p.reload(now: t0)
        p.sync(host, now: t0.addingTimeInterval(2))
        XCTAssertEqual(host.noticeKeys, [], "a stage with no notice still closes the last")
    }

    func testAnAutoCompactionBeforeTheSaveIsAnnounced() throws {
        let id = try session(1, tokens: 188_400, phase: .watching)
        let p = presenter()
        try edit(id) { s in
            s.lastCompaction = Compaction(at: self.t0.addingTimeInterval(5), trigger: "auto", preTokens: 188_400, postTokens: 21_000,
                                          interruptedPhase: .queued)
        }
        p.reload(now: t0)
        p.sync(host, now: t0.addingTimeInterval(6))
        let key = try XCTUnwrap(host.noticeKeys.first)
        XCTAssertEqual(host.notices[key], NoticeContent(symbol: .compacting, tone: .warning, title: "Auto-compacted at 188k before it could save",
                                                        detail: "Session 1", caption: "/tmp/s1"))
    }

    func testOnlyNewAutoCompactionsThatInterruptedSomethingAreAnnounced() throws {
        let a = try session(1, phase: .watching)
        let b = try session(2, phase: .watching)
        let c = try session(3, phase: .watching)
        let p = presenter()
        let later = t0.addingTimeInterval(5)
        try edit(a) { $0.lastCompaction = Compaction(at: later, trigger: "manual", preTokens: 1, postTokens: 1, interruptedPhase: .queued) }
        try edit(b) { $0.lastCompaction = Compaction(at: later, trigger: "auto", preTokens: 1, postTokens: 1) }
        try edit(c) { $0.lastCompaction = Compaction(at: self.t0.addingTimeInterval(-5), trigger: "auto", preTokens: 1, postTokens: 1, interruptedPhase: .queued) }
        p.reload(now: t0)
        p.sync(host, now: later)
        XCTAssertEqual(host.noticeKeys, [])
    }

    func testTurningOffSaysHowToTurnItBackOn() throws {
        let p = presenter()
        p.announceOff(host)
        let key = try XCTUnwrap(host.noticeKeys.first)
        XCTAssertTrue(key.hasPrefix("notice:off:"))
        XCTAssertEqual(host.notices[key], NoticeContent(symbol: .off, tone: .muted, title: "Context Guard is off", detail: Words.Notice.turnBackOn))
        p.announceOff(host)
        XCTAssertEqual(host.noticeKeys.count, 2, "each time")
    }

    // MARK: Reading

    func testStartGivesOldSettingsAnEnabledAt() throws {
        try Data(#"{"schemaVersion": 1, "enabled": true}"#.utf8).write(to: paths.configFile)
        let p = Presenter(paths: paths, registry: registry, probe: probe, codexLinkInstalled: { false }, now: t0)
        XCTAssertNil(p.start(now: t0))
        XCTAssertEqual(Config.load(paths).enabledAt, t0)
    }

    func testCodexsLinesShowOnceItsInstalledOrHasRun() throws {
        let p = presenter()
        XCTAssertFalse(p.showsCodex)
        XCTAssertEqual(p.codexLink, .notRunning)
        installed = true
        p.reload(now: t0)
        XCTAssertTrue(p.showsCodex)
        installed = false
        try CodexLinkStatus(at: t0, connected: true, judgeModel: "gpt-6-luna").save(paths)
        p.reload(now: t0)
        XCTAssertTrue(p.showsCodex)
        XCTAssertEqual(p.codexLink, .connected)
        XCTAssertEqual(p.codexJudge, "gpt-6-luna")
    }

    func testOldSessionFilesGoHourly() throws {
        let id = try session(1, phase: .watching) { $0.updatedAt = self.t0.addingTimeInterval(-8 * 86_400) }
        probe.set(4_001, nil)
        let p = presenter(at: t0.addingTimeInterval(-10))
        XCTAssertNil(SessionState.load(id, paths), "pruned on the first read")
        let again = try session(2, phase: .watching) { $0.updatedAt = self.t0.addingTimeInterval(-8 * 86_400) }
        probe.set(4_002, nil)
        p.reload(now: t0.addingTimeInterval(1_000))
        XCTAssertNotNil(SessionState.load(again, paths), "not yet an hour")
        p.reload(now: t0.addingTimeInterval(3_600))
        XCTAssertNil(SessionState.load(again, paths))
    }
}
