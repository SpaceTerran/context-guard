import XCTest
@testable import ContextGuardCore

final class StatusTextTests: XCTestCase {
    let now = Date()

    func claude(_ tokens: Int, phase: Phase = .watching, title: String = "Settings screen") -> SessionInfo {
        var s = SessionState(sessionId: "a1b2c3d4-0000-4000-8000-000000000001", now: now)
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.title = title
        return SessionInfo(state: s, isLive: true, waiterAlive: false)
    }

    func codex(_ tokens: Int, window: Int? = 258_400, attached: Bool? = true, surface: CodexSurface? = nil,
               onlyWatching: Bool = false) -> SessionInfo {
        var s = SessionState(sessionId: "01a1c7f0-4d8a-7870-aab2-07bc76ea7408", host: .codex, now: now)
        s.guarded = window != nil
        s.tokens = tokens
        s.title = "Release notes"
        s.codex = CodexFacts(window: window, status: "idle", loaded: true)
        s.codex?.attached = attached
        s.codex?.surface = surface
        s.codex?.onlyWatching = onlyWatching ? true : nil
        return SessionInfo(state: s, isLive: true, waiterAlive: false)
    }

    func testWithoutCodexItReadsAsBefore() {
        var waiting = claude(312_000, phase: .sent)
        waiting.waiterAlive = true
        let lines = StatusText.lines(config: Config(), sessions: [waiting, claude(40_000)], link: nil, now: now)
        XCTAssertEqual(lines, [
            "Context Guard is on · asks at 300k · compacts at 500k when told to wait",
            "a1b2c3d4  312k   sent      Settings screen · waiting in background",
            "a1b2c3d4  40k    watching  Settings screen",
        ])
        XCTAssertEqual(StatusText.lines(config: Config(), sessions: [], link: nil, now: now),
                       ["Context Guard is on · asks at 300k · compacts at 500k when told to wait", "No running sessions seen yet."])
    }

    func testWithCodexEachToolHasItsLine() {
        let link = CodexLinkStatus(at: now, connected: true, serverVersion: "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)", judgeModel: "gpt-6-luna")
        let lines = StatusText.lines(config: Config(), sessions: [claude(40_000), codex(160_000)], link: link, now: now)
        XCTAssertEqual(lines, [
            "Context Guard is on",
            "  Claude Code: asks at 300k · compacts at 500k when told to wait",
            "  Codex: asks at 60% · compacts at 80% of each session's window when told to wait",
            "  Codex link: connected to Codex 0.167.1 · judge: gpt-6-luna",
            "a1b2c3d4  Claude 40k    watching  Settings screen",
            "01a1c7f0  Codex  160k   watching  Release notes · 61% of 258k",
        ])
    }

    func testCodexSessionFilesAloneDontBringBackTheCodexLines() {
        // After `install.sh --no-codex` the link's file is gone, but session files stay a week.
        let lines = StatusText.lines(config: Config(), sessions: [claude(40_000), codex(160_000)], link: nil, now: now)
        XCTAssertEqual(lines.first, "Context Guard is on · asks at 300k · compacts at 500k when told to wait")
        XCTAssertFalse(lines.contains { $0.contains("Codex link") })
    }

    func cursor(_ tokens: Int, window: Int = 200_000) -> SessionInfo {
        var s = SessionState(sessionId: "44e5a64b-0000-4000-8000-000000000003", host: .cursor, now: now)
        s.guarded = true
        s.tokens = tokens
        s.title = "Notes file"
        s.cursorChat = CursorFacts(window: window)
        return SessionInfo(state: s, isLive: true, waiterAlive: false)
    }

    func testOnceCursorsHooksAreInItHasItsLine() {
        // Right after install.sh, before any Cursor chat has run.
        XCTAssertEqual(StatusText.lines(config: Config(), sessions: [], link: nil, cursorHooks: true, now: now), [
            "Context Guard is on",
            "  Claude Code: asks at 300k · compacts at 500k when told to wait",
            "  Cursor: asks at 60% · compacts at 80% of each chat's window when told to wait",
            "No running sessions seen yet.",
        ])
    }

    func testACursorChatBringsCursorsLineWithoutItsHooks() {
        let lines = StatusText.lines(config: Config(), sessions: [claude(40_000), cursor(50_000)], link: nil, now: now)
        XCTAssertEqual(lines, [
            "Context Guard is on",
            "  Claude Code: asks at 300k · compacts at 500k when told to wait",
            "  Cursor: asks at 60% · compacts at 80% of each chat's window when told to wait",
            "a1b2c3d4  Claude 40k    watching  Settings screen",
            "44e5a64b  Cursor 50k    watching  Notes file · 25% of 200k",
        ])
    }

    func testACodexSessionsOwnFacts() {
        XCTAssertEqual(StatusText.row(codex(30_000, window: nil), tools: true, config: Config(), now: now), "01a1c7f0  Codex  30k    watching  Release notes (not guarded)")
        XCTAssertEqual(StatusText.row(codex(30_000, attached: false), tools: true, config: Config(), now: now),
                       "01a1c7f0  Codex  30k    watching  Release notes · 11% of 258k · no terminal shows it")
        XCTAssertEqual(StatusText.row(codex(30_000, onlyWatching: true), tools: true, config: Config(), now: now),
                       "01a1c7f0  Codex  30k    watching  Release notes · 11% of 258k · only watching",
                       "an older Codex: shown, but it isn't that no terminal shows it")
    }

    func testWhereCompactingStandsReadsAsTheMenuSaysIt() {
        var s = codex(22_000)
        var f = FollowUp(nonce: "cg-1a2b3c4d5e", manual: false, now: now.addingTimeInterval(-60))
        f.stage = .done
        f.stageAt = now.addingTimeInterval(-60)
        f.note = "No files needed saving."
        f.tokensBefore = 57_062
        f.tokensAfter = 22_987
        s.state.followUp = f
        XCTAssertEqual(StatusText.row(s, tools: true, config: Config(), now: now),
                       "01a1c7f0  Codex  22k    watching  Release notes · 8% of 258k · compacted 57k → 22k and sent \u{201C}continue now\u{201D}")
        XCTAssertEqual(StatusText.row(s, tools: true, config: Config(), now: now.addingTimeInterval(FollowUpText.shownAfterEnd + 60)),
                       "01a1c7f0  Codex  22k    watching  Release notes · 8% of 258k",
                       "once the menu stops showing it, so does status")
        s.state.followUp?.stage = .needsYou
        s.state.followUp?.note = "Asked whether to merge."
        XCTAssertEqual(StatusText.row(s, tools: true, config: Config(), now: now),
                       "01a1c7f0  Codex  22k    watching  Release notes · 8% of 258k · needs you before compacting: Asked whether to merge")
    }

    func testHowTheLinkStands() {
        XCTAssertEqual(StatusText.linkState(nil, now: now), "not running")
        XCTAssertEqual(StatusText.linkState(CodexLinkStatus(at: now.addingTimeInterval(-300), connected: true), now: now),
                       "not running (last heard from 5 min ago)")
        XCTAssertEqual(StatusText.linkState(CodexLinkStatus(at: now.addingTimeInterval(-3), connected: false, stopped: true), now: now),
                       "not running (stopped 3 s ago)")
        XCTAssertEqual(StatusText.linkState(CodexLinkStatus(at: now, connected: false, lastError: "couldn't connect (Connection refused)"), now: now),
                       "waiting for Codex · last error: couldn't connect (Connection refused)")
        XCTAssertEqual(StatusText.linkState(CodexLinkStatus(at: now, connected: true, observeOnly: "this Codex has no thread/queue/add"), now: now),
                       "connected · judge: each session's own model · only watching: this Codex has no thread/queue/add")
        XCTAssertEqual(StatusText.codexVersion("weird"), "weird")
        XCTAssertEqual(StatusText.ago(45), "45 s ago")
        XCTAssertEqual(StatusText.ago(10_800), "3 h ago")
    }

    func testAStateForSettings() {
        XCTAssertEqual(CodexLinkStatus.state(nil, now: now), .notRunning)
        XCTAssertEqual(CodexLinkStatus.state(CodexLinkStatus(at: now.addingTimeInterval(-60), connected: true), now: now), .notRunning)
        XCTAssertEqual(CodexLinkStatus.state(CodexLinkStatus(at: now, connected: true, stopped: true), now: now), .notRunning)
        XCTAssertEqual(CodexLinkStatus.state(CodexLinkStatus(at: now, connected: false, lastError: "refused"), now: now), .waiting)
        XCTAssertEqual(CodexLinkStatus.state(CodexLinkStatus(at: now, connected: true), now: now), .connected)
        XCTAssertEqual(CodexLinkStatus.state(CodexLinkStatus(at: now, connected: true, observeOnly: "no thread/queue/add"), now: now),
                       .onlyWatching("no thread/queue/add"))
    }

    func testSizesAsEachToolCountsThem() {
        XCTAssertEqual(claude(302_517).size(302_517), "302k")
        XCTAssertEqual(codex(160_000).size(160_000), "61% (160k)")
        XCTAssertEqual(codex(160_000).size(155_039), "59% (155k)", "rounds down, never early")
        XCTAssertEqual(codex(160_000, window: nil).size(160_000), "160k", "no window yet")
        XCTAssertEqual(codex(160_000).shortSize(206_720), "80%")
        XCTAssertEqual(claude(40_000).shortSize(500_000), "500k")
        XCTAssertEqual(SessionHost.claude.whenOutOfReach, "when it next runs")
        XCTAssertEqual(SessionHost.codex.whenOutOfReach, "when a terminal or the Codex app has it open")
    }

    func testWithTheCodexAppItHasALineAndItsChatsSaySo() {
        // No Codex terminal is open: the link is in the app only.
        let app = CodexAppLinkStatus(connected: true, chats: 2, judgeModel: "gpt-6-luna")
        let link = CodexLinkStatus(at: now, connected: false, app: app)
        XCTAssertEqual(StatusText.lines(config: Config(), sessions: [codex(160_000, surface: .app)], link: link, now: now), [
            "Context Guard is on",
            "  Claude Code: asks at 300k · compacts at 500k when told to wait",
            "  Codex: asks at 60% · compacts at 80% of each session's window when told to wait",
            "  Codex link: waiting for a Codex terminal",
            "  Codex app: connected · 2 chats open · judge: gpt-6-luna",
            "01a1c7f0  Codex  160k   watching  Release notes · 61% of 258k · Codex app",
        ])
        XCTAssertEqual(StatusText.row(codex(30_000, surface: .app, onlyWatching: true), tools: true, config: Config(), now: now),
                       "01a1c7f0  Codex  30k    watching  Release notes · 11% of 258k · Codex app · only watching")

        let stopped = CodexLinkStatus(at: now, connected: false, stopped: true, app: CodexAppLinkStatus(connected: false))
        XCTAssertFalse(StatusText.lines(config: Config(), sessions: [], link: stopped, now: now).contains { $0.contains("Codex app") },
                       "a link that isn't running has nothing to say about the app")
    }

    func testHowTheCodexAppStands() {
        XCTAssertEqual(StatusText.appState(CodexAppLinkStatus(connected: false)), "waiting for the Codex app")
        XCTAssertEqual(StatusText.appState(CodexAppLinkStatus(connected: false, lastError: "the Codex app closed the connection")),
                       "waiting for the Codex app · last error: the Codex app closed the connection")
        XCTAssertEqual(StatusText.appState(CodexAppLinkStatus(connected: true)), "connected · 0 chats open")
        XCTAssertEqual(StatusText.appState(CodexAppLinkStatus(connected: true, chats: 1, unsupported: "thread-archived version 3")),
                       "connected · 1 chat open · only watching: thread-archived version 3")
    }

    func testTheCodexAppCountsForSettings() {
        func state(connected: Bool = false, observeOnly: String? = nil, app: CodexAppLinkStatus?) -> CodexLinkStatus.State {
            CodexLinkStatus.state(CodexLinkStatus(at: now, connected: connected, observeOnly: observeOnly, app: app), now: now)
        }
        XCTAssertEqual(state(app: CodexAppLinkStatus(connected: true)), .connected)
        XCTAssertEqual(state(app: CodexAppLinkStatus(connected: false)), .waiting)
        XCTAssertEqual(state(app: CodexAppLinkStatus(connected: true, unsupported: "thread-archived version 3")),
                       .onlyWatching("thread-archived version 3"))
        XCTAssertEqual(state(connected: true, observeOnly: "no thread/queue/add", app: CodexAppLinkStatus(connected: true)),
                       .onlyWatching("no thread/queue/add"))
        XCTAssertEqual(state(connected: true, app: CodexAppLinkStatus(connected: false, unsupported: "an old version")), .connected,
                       "what an app it isn't in says doesn't count")
        XCTAssertEqual(CodexLinkStatus.state(CodexLinkStatus(at: now.addingTimeInterval(-60), connected: false,
                                                             app: CodexAppLinkStatus(connected: true)), now: now), .notRunning)
    }

    func testALinkWithNoSessionsYet() {
        let lines = StatusText.lines(config: Config(), sessions: [], link: CodexLinkStatus(at: now, connected: false), now: now)
        XCTAssertEqual(lines.last, "No running sessions seen yet.")
        XCTAssertEqual(lines[3], "  Codex link: waiting for Codex")
    }
}
