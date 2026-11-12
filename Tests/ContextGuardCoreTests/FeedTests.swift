import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// `context-guard ui`'s engine: the lines it writes for what happens in Context Guard's folder and
/// for what the Windows app sends it.
final class FeedTests: XCTestCase {
    var fx: FeedFixture!
    var t0: Date { fx.t0 }

    override func setUp() { fx = FeedFixture() }
    override func tearDown() { fx = nil }

    func types(_ lines: [String]) -> [String] { FeedFixture.types(lines) }

    /// A started feed.
    func started() -> Feed {
        let feed = fx.feed()
        _ = feed.start(now: t0)
        return feed
    }

    // MARK: The board

    func testStartWritesTheFirstBoard() throws {
        let feed = fx.feed()
        let lines = feed.start(now: t0)
        XCTAssertEqual(types(lines), ["board"])
        XCTAssertEqual(try FeedFixture.json(lines[0])["v"], .number("1"))
        let board = feed.board(now: t0)
        XCTAssertEqual(lines[0], Feed.line(.board(board)), "the line is the board")
        XCTAssertEqual(board.tray, Board.Tray(state: "on", label: "Context Guard"))
        XCTAssertEqual(board.menu.on, Board.Toggle(label: "Context Guard On", on: true))
        XCTAssertEqual(board.menu.lines, ["Asks at 300k · Wait until 500k"])
        XCTAssertEqual(board.menu.empty, "No sessions running")
        XCTAssertEqual(board.menu.sessions, [])
        XCTAssertEqual(board.popups, [])
        XCTAssertNil(board.settings)
        XCTAssertNil(feed.nextWake(now: t0), "nothing changes by itself")
    }

    func testAnUnchangedBoardIsntWrittenAgain() {
        let feed = started()
        XCTAssertEqual(feed.refresh(now: fx.at(2)), [])
        XCTAssertEqual(feed.tick(now: fx.at(3)), [])
        XCTAssertEqual(feed.handle(#"{"do":"settingsClose","id":"1"}"#, now: fx.at(4)), [Feed.line(.result(id: "1", problem: nil))])
    }

    func testCodexSessionsShowOnceTheLinkRuns() throws {
        try fx.link()
        let id = try fx.codexSession(1)
        try fx.session(2, phase: .watching)
        let board = started().board(now: t0)
        XCTAssertEqual(board.menu.lines, ["Claude Code: asks at 300k · Wait until 500k", "Codex: asks at 60% · Wait until 80%"])
        XCTAssertEqual(board.menu.sessions.map(\.tokens), ["302k", "160k"], "largest first")
        XCTAssertEqual(board.popups.map(\.key), ["question:\(id)"])
        XCTAssertEqual(board.popups.first?.question?.heading, "Context at 61% (160k)")
        XCTAssertEqual(board.popups.first?.question?.subtitle, #"Codex · C:\code\c1"#)
    }

    // MARK: Questions

    func testAQuestionOpensWithAChime() throws {
        let id = try fx.session(1)
        let feed = fx.feed()
        XCTAssertEqual(types(feed.start(now: t0)), ["board", "chime"])
        let board = feed.board(now: t0)
        XCTAssertEqual(board.tray.state, "asking")
        XCTAssertEqual(board.popups.map(\.key), ["question:\(id)"])
        let q = try XCTUnwrap(board.popups.first?.question)
        XCTAssertNil(board.popups.first?.notice)
        XCTAssertEqual(q.session, id)
        XCTAssertEqual(q.heading, "Context at 302k")
        XCTAssertEqual(q.title, "Session 1")
        XCTAssertEqual(q.subtitle, #"C:\code\s1"#)
        XCTAssertNil(q.progress)
        let ask = try XCTUnwrap(q.ask)
        XCTAssertEqual(ask.countdown, "Compacts in 60 seconds unless you answer")
        XCTAssertNil(ask.hide, "no ✕ while it counts down")
        XCTAssertEqual(ask.deferral, Board.Deferral(label: "Wait until 500k", help: "Compact by itself when this session reaches 500k", answer: .later))
        XCTAssertEqual(ask.compact, Board.Action(label: "Compact", help: Words.Popup.compactHelp(Config.defaultMessage)))
        let session = try XCTUnwrap(board.menu.sessions.first)
        XCTAssertEqual(session.deferral, Board.Deferral(label: "Wait until 500k", help: nil, answer: .later))
        XCTAssertEqual(session.showQuestion, "Show the Question")
        XCTAssertEqual(feed.refresh(now: t0), [], "it opens once")
    }

    func testTheCountdownMovesEachSecond() throws {
        try fx.session(1)
        let feed = started()
        XCTAssertEqual(try XCTUnwrap(feed.nextWake(now: t0)).timeIntervalSince(t0), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(feed.nextWake(now: fx.at(0.4))).timeIntervalSince(t0), 1, accuracy: 0.001)
        XCTAssertEqual(types(feed.tick(now: fx.at(1))), ["board"])
        XCTAssertEqual(feed.board(now: fx.at(1)).popups.first?.question?.ask?.countdown, "Compacts in 59 seconds unless you answer")
        XCTAssertEqual(feed.tick(now: fx.at(1.5)), [], "the same second")
    }

    func testWithoutACountdownItCanBeHidden() throws {
        try fx.config { $0.autoYesSeconds = 0 }
        try fx.session(1, tokens: 512_000)
        let feed = started()
        let ask = try XCTUnwrap(feed.board(now: t0).popups.first?.question?.ask)
        XCTAssertNil(ask.countdown)
        XCTAssertEqual(ask.hide, Board.Action(label: "Close", help: Words.Popup.hideHelp))
        XCTAssertEqual(ask.deferral, Board.Deferral(label: "Not Now", help: Words.Popup.notNowHelp, answer: .skip), "past its compact-at size")
        XCTAssertNil(feed.nextWake(now: t0))
    }

    func testAnAnswerShowsItsProgressThenCloses() throws {
        let id = try fx.session(1)
        let feed = started()
        let lines = feed.handle(#"{"do":"answer","id":"7","session":"\#(id)","action":"yes","source":"popup"}"#, now: fx.at(2))
        XCTAssertEqual(types(lines), ["result", "board"])
        XCTAssertEqual(lines[0], Feed.line(.result(id: "7", problem: nil)))
        let answer = try XCTUnwrap(Answer.load(id, fx.paths))
        XCTAssertEqual(answer.action, .yes)
        XCTAssertEqual(answer.source, .popup)
        let progress = try XCTUnwrap(feed.board(now: fx.at(2)).popups.first?.question?.progress)
        XCTAssertEqual(progress, Board.Progress(mark: "icon", symbol: .waiting, tone: .muted, text: "Asks it to save when it next runs"))
        XCTAssertNil(feed.board(now: fx.at(2)).popups.first?.question?.ask)

        let wake = try XCTUnwrap(feed.nextWake(now: fx.at(2)))
        XCTAssertEqual(wake.timeIntervalSince(fx.at(2)), 6.05, accuracy: 0.001, "shown long enough")
        XCTAssertEqual(types(feed.tick(now: wake)), ["board"])
        XCTAssertEqual(feed.board(now: wake).popups, [])
        XCTAssertEqual(feed.refresh(now: wake.addingTimeInterval(1)), [], "answered: it doesn't open again")
    }

    func testWhileBusyItGoesInAtItsNextStep() throws {
        let id = try fx.session(1, status: "busy")
        let feed = started()
        _ = feed.handle(#"{"do":"answer","session":"\#(id)","action":"yes","source":"popup"}"#, now: t0)
        XCTAssertEqual(feed.board(now: t0).popups.first?.question?.progress,
                       Board.Progress(mark: "working", symbol: nil, tone: nil, text: "Asking it to save at its next step…"))
    }

    func testCompactNowFromTheMenu() throws {
        let id = try fx.session(1, phase: .watching)
        let feed = started()
        XCTAssertEqual(feed.board(now: t0).menu.sessions.first?.compactNow, Board.MenuItem(label: "Compact Now", enabled: true))
        let lines = feed.handle(#"{"do":"answer","session":"\#(id)","action":"yes","source":"menu"}"#, now: t0)
        XCTAssertEqual(types(lines), ["result", "board"])
        XCTAssertNil(try FeedFixture.json(lines[0])["id"], "no id sent, none back")
        XCTAssertEqual(Answer.load(id, fx.paths)?.source, .menu)
        let session = try XCTUnwrap(feed.board(now: t0).menu.sessions.first)
        XCTAssertEqual(session.status, "Asks it to save when it next runs")
        XCTAssertEqual(session.compactNow.enabled, false, "it's already on its way")
        XCTAssertEqual(feed.board(now: t0).popups, [], "the menu's answer opens no popup")
    }

    func testAnAnswerForASessionThatsGoneDoesNothing() {
        let feed = started()
        XCTAssertEqual(feed.handle(#"{"do":"answer","id":"1","session":"nope","action":"yes","source":"popup"}"#, now: t0),
                       [Feed.line(.result(id: "1", problem: nil))])
        XCTAssertNil(Answer.load("nope", fx.paths))
    }

    func testHideUntilTheMenuShowsItAgain() throws {
        let id = try fx.session(1)
        let feed = started()
        XCTAssertEqual(types(feed.handle(#"{"do":"hide","session":"\#(id)"}"#, now: t0)), ["result", "board"])
        XCTAssertEqual(feed.board(now: t0).popups, [])
        XCTAssertNil(feed.nextWake(now: t0))
        XCTAssertEqual(feed.refresh(now: fx.at(1)), [], "hidden until it asks again")
        XCTAssertEqual(types(feed.handle(#"{"do":"show","session":"\#(id)"}"#, now: fx.at(2))), ["result", "board", "chime"])
        XCTAssertEqual(feed.board(now: fx.at(2)).popups.map(\.key), ["question:\(id)"])
    }

    func testRoomForFiveAtOnce() throws {
        let ids = try (1...6).map { try fx.session($0, tokens: 300_000 + $0) }
        let feed = fx.feed()
        XCTAssertEqual(types(feed.start(now: t0)), ["board", "chime"])
        XCTAssertEqual(feed.board(now: t0).popups.map(\.key), ids.reversed().prefix(5).map { "question:\($0)" }, "largest first")
        XCTAssertEqual(types(feed.handle(#"{"do":"hide","session":"\#(ids[5])"}"#, now: fx.at(1))), ["result", "board", "chime"])
        XCTAssertEqual(feed.board(now: fx.at(1)).popups.map(\.key), ids.prefix(5).reversed().map { "question:\($0)" }, "the sixth takes its place")
    }

    // MARK: Notices

    func testTurnOffSaysHowToTurnItBackOn() throws {
        try fx.session(1)
        let feed = started()
        XCTAssertEqual(types(feed.handle(#"{"do":"turnOff","id":"3"}"#, now: fx.at(1))), ["result", "board"])
        XCTAssertFalse(Config.load(fx.paths).enabled)
        let board = feed.board(now: fx.at(1))
        XCTAssertEqual(board.tray, Board.Tray(state: "off", label: "Context Guard (off)"))
        XCTAssertEqual(board.menu.on, Board.Toggle(label: "Context Guard On", on: false))
        XCTAssertEqual(board.popups.map(\.key), ["notice:off:1"], "the question closes")
        XCTAssertEqual(board.popups.first?.notice, Board.Notice(symbol: .off, tone: .muted, title: "Context Guard is off", detail: Words.Notice.turnBackOn,
                                                                caption: "", captionWraps: false, close: "Close"))
        XCTAssertEqual(feed.nextWake(now: fx.at(1)), fx.at(9))
        XCTAssertEqual(feed.tick(now: fx.at(8.9)), [])
        XCTAssertEqual(types(feed.tick(now: fx.at(9))), ["board"], "it closes by itself")
        XCTAssertEqual(feed.board(now: fx.at(9)).popups, [])
    }

    func testCloseANotice() {
        let feed = started()
        _ = feed.handle(#"{"do":"turnOff"}"#, now: t0)
        XCTAssertEqual(types(feed.handle(#"{"do":"close","key":"notice:off:1"}"#, now: fx.at(1))), ["result", "board"])
        XCTAssertEqual(feed.board(now: fx.at(1)).popups, [])
        XCTAssertNil(feed.nextWake(now: fx.at(1)))
    }

    func testASendIsANoticeWithoutAChime() throws {
        let id = try fx.session(1, phase: .watching)
        let feed = started()
        try fx.edit(id) { s in
            s.phase = .sent
            s.sentNonce = "cg-1"
            s.sendReason = .manual
        }
        XCTAssertEqual(types(feed.refresh(now: fx.at(1))), ["board"])
        let board = feed.board(now: fx.at(1))
        XCTAssertEqual(board.popups.map(\.key), ["notice:cg-1"])
        XCTAssertEqual(board.popups.first?.notice?.title, "Saving, then compacting")
    }

    func testASavesLineInTheMenuWakesEachSecond() throws {
        try fx.session(1, phase: .sent) { s in
            s.sentNonce = "cg-1"
            s.confirmedAt = self.t0
            s.followUp = FollowUp(nonce: "cg-1", now: self.t0)
        }
        let feed = started()
        XCTAssertEqual(feed.board(now: t0).menu.sessions.first?.followUp, "Compacts once it's done saving")
        XCTAssertEqual(feed.nextWake(now: t0), fx.at(1))
    }

    // MARK: Switches

    func testTheSwitchesAndWatchThisSession() throws {
        let id = try fx.session(1)
        let feed = started()
        _ = feed.handle(#"{"do":"enable","on":false}"#, now: t0)
        XCTAssertFalse(Config.load(fx.paths).enabled)
        XCTAssertEqual(feed.board(now: t0).tray.state, "off")
        XCTAssertEqual(feed.board(now: t0).popups, [], "the switch shows no notice")
        XCTAssertEqual(types(feed.handle(#"{"do":"enable","on":true}"#, now: fx.at(1))), ["result", "board", "chime"], "it asks again")

        _ = feed.handle(#"{"do":"watch","session":"\#(id)","on":false}"#, now: fx.at(2))
        let board = feed.board(now: fx.at(2))
        let session = try XCTUnwrap(board.menu.sessions.first)
        XCTAssertEqual(session.watch, Board.Toggle(label: "Watch This Session", on: false))
        XCTAssertEqual(session.symbol, .notWatching)
        XCTAssertEqual(session.status, "Not watching this session")
        XCTAssertEqual(board.popups, [])
        XCTAssertEqual(board.tray.state, "on")
        _ = feed.handle(#"{"do":"watch","session":"\#(id)","on":true}"#, now: fx.at(3))
        XCTAssertEqual(feed.board(now: fx.at(3)).menu.sessions.first?.watch.on, true)
    }

    // MARK: Lines it can't read

    func testLinesThatArentIntents() {
        let feed = started()
        let lines = ["nonsense", "{}", #"{"do":"fly"}"#, #"{"do":"answer","session":"x"}"#,
                     #"{"do":"answer","session":"x","action":"maybe","source":"popup"}"#, #"{"do":"set","field":"colour","value":"1"}"#,
                     #"{"do":"enable","on":"yes"}"#]
        for line in lines {
            XCTAssertEqual(feed.handle(line, now: t0), [Feed.line(.error("not an intent: \(line)"))], line)
        }
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(feed.handle(long, now: t0), [Feed.line(.error("not an intent: \(long.prefix(200))"))], "a long line is cut")
        XCTAssertEqual(Config.load(fx.paths).enabled, true)
    }

    // MARK: Settings

    func testSettingsNeedsToBeOpen() {
        let feed = started()
        for intent in [#"{"do":"set","id":"2","field":"askK","value":"200"}"#, #"{"do":"step","id":"2","field":"askK","up":true}"#,
                       #"{"do":"restore","id":"2","field":"message"}"#] {
            XCTAssertEqual(feed.handle(intent, now: t0), [Feed.line(.result(id: "2", problem: "Settings isn't open."))], intent)
        }
        XCTAssertEqual(Config.load(fx.paths).askAt, 300_000)
    }

    func testSettingsSavesAsYouType() throws {
        let feed = started()
        XCTAssertEqual(types(feed.handle(#"{"do":"settingsOpen"}"#, now: t0)), ["result", "board"])
        var settings = try XCTUnwrap(feed.board(now: t0).settings)
        XCTAssertEqual(settings.title, "Context Guard Settings")
        XCTAssertEqual(settings.tabs.map(\.id), ["general", "asking", "messages"])
        XCTAssertEqual(settings.tabs.map(\.title), ["General", "When to Ask", "Messages"])
        XCTAssertEqual(settings.card("When to ask")?.status, Board.Status(StatusLine(text: "Saved", symbol: .saved, tone: .muted)))

        _ = feed.handle(#"{"do":"set","field":"askK","value":"200"}"#, now: fx.at(1))
        XCTAssertEqual(Config.load(fx.paths).askAt, 200_000)
        settings = try XCTUnwrap(feed.board(now: fx.at(1)).settings)
        XCTAssertEqual(settings.card("When to ask")?.status, Board.Status(StatusLine(text: "Saved 3:41 PM", symbol: .success, tone: .success)))
        XCTAssertEqual(settings.field(.askK), Board.Field(id: .askK, label: "Ask at", unit: "k tokens", value: 200, text: "200", invalid: false))
        XCTAssertEqual(feed.board(now: fx.at(1)).menu.lines, ["Asks at 200k · Wait until 500k"], "the menu reads it back")

        _ = feed.handle(#"{"do":"set","field":"laterK","value":""}"#, now: fx.at(2))
        settings = try XCTUnwrap(feed.board(now: fx.at(2)).settings)
        XCTAssertEqual(settings.field(.laterK), Board.Field(id: .laterK, label: "If you choose Wait, compact at", unit: "k tokens", value: 0, text: "",
                                                            invalid: true))
        XCTAssertEqual(settings.card("When to ask")?.status?.text, "Not saved")
        XCTAssertEqual(Config.load(fx.paths).laterAt, 500_000, "not saved")

        _ = feed.handle(#"{"do":"step","field":"autoYes","up":true}"#, now: fx.at(3))
        XCTAssertEqual(Config.load(fx.paths).autoYesSeconds, 75)

        _ = feed.handle(#"{"do":"set","field":"message","value":"Save your work."}"#, now: fx.at(4))
        XCTAssertEqual(Config.load(fx.paths).message, "Save your work.")
        settings = try XCTUnwrap(feed.board(now: fx.at(4)).settings)
        XCTAssertEqual(settings.text(.message)?.restore.enabled, true)
        _ = feed.handle(#"{"do":"restore","field":"message"}"#, now: fx.at(5))
        XCTAssertEqual(Config.load(fx.paths).message, Config.defaultMessage)
        XCTAssertEqual(try XCTUnwrap(feed.board(now: fx.at(5)).settings).text(.message)?.restore.enabled, false)

        _ = feed.handle(#"{"do":"settingsClose"}"#, now: fx.at(6))
        XCTAssertNil(feed.board(now: fx.at(6)).settings)
        _ = feed.handle(#"{"do":"settingsOpen"}"#, now: fx.at(7))
        settings = try XCTUnwrap(feed.board(now: fx.at(7)).settings)
        XCTAssertEqual(settings.field(.laterK)?.value, 500, "it opens fresh from the settings")
        XCTAssertEqual(settings.card("When to ask")?.status?.text, "Saved")
    }

    func testSettingsReadsWhatsInstalledWhenItOpens() throws {
        let feed = started()
        _ = feed.handle(#"{"do":"settingsOpen"}"#, now: t0)
        let missing = StatusLine(text: "Not installed: run \(Words.installer)", symbol: .warning, tone: .warning)
        var rows = try XCTUnwrap(feed.board(now: t0).settings).statusRows("Claude Code")
        XCTAssertEqual(rows.map(\.label), ["Hooks", "Mod", "Judge"])
        XCTAssertEqual(rows.map(\.status), [Board.Status(missing), Board.Status(missing), Board.Status(SettingsText.claudeJudge)])
        XCTAssertNil(try XCTUnwrap(feed.board(now: t0).settings).card("Codex"), "no Codex until its link is installed or has run")

        try fx.installClaudeSide()
        fx.linkInstalled = true
        _ = feed.refresh(now: fx.at(1))
        rows = try XCTUnwrap(feed.board(now: fx.at(1)).settings).statusRows("Claude Code")
        XCTAssertEqual(rows.first?.status.text, missing.text, "read when Settings opens")

        _ = feed.handle(#"{"do":"settingsOpen"}"#, now: fx.at(2))
        let settings = try XCTUnwrap(feed.board(now: fx.at(2)).settings)
        XCTAssertEqual(settings.statusRows("Claude Code").prefix(2).map(\.status.text), ["Installed", "Installed"])
        XCTAssertEqual(settings.statusRows("Codex").map(\.status.text), ["Not running: run \(Words.installer)", "Picked when Codex connects"])
    }

    func testCodexLinkInstall() throws {
        let agents = fx.dir.file("LaunchAgents")
        let env = ["CONTEXT_GUARD_LAUNCH_AGENTS": agents.path]
        XCTAssertEqual(CodexLinkInstall.plist(env), agents.appendingPathComponent("com.spaceterran.ContextGuard.codex.plist"))
        XCTAssertFalse(CodexLinkInstall.isInstalled(fx.paths, env: env, windows: false))
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: CodexLinkInstall.plist(env))
        XCTAssertTrue(CodexLinkInstall.isInstalled(fx.paths, env: env, windows: false))

        XCTAssertFalse(CodexLinkInstall.isInstalled(fx.paths, env: env, windows: true), "Windows looks for the link's program")
        let program = CodexLinkInstall.program(fx.paths)
        XCTAssertEqual(program.lastPathComponent, "context-guard-link.exe")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: program)
        XCTAssertTrue(CodexLinkInstall.isInstalled(fx.paths, env: env, windows: true))
    }
}
