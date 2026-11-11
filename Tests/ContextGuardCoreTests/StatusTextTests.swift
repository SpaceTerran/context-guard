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

    func codex(_ tokens: Int, window: Int? = 258_400, attached: Bool? = true) -> SessionInfo {
        var s = SessionState(sessionId: "01a1c7f0-4d8a-7870-aab2-07bc76ea7408", host: .codex, now: now)
        s.guarded = window != nil
        s.tokens = tokens
        s.title = "Release notes"
        s.codex = CodexFacts(window: window, status: "idle", loaded: true)
        s.codex?.attached = attached
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

    func testACodexSessionsOwnFacts() {
        XCTAssertEqual(StatusText.row(codex(30_000, window: nil), tools: true), "01a1c7f0  Codex  30k    watching  Release notes (not guarded)")
        XCTAssertEqual(StatusText.row(codex(30_000, attached: false), tools: true),
                       "01a1c7f0  Codex  30k    watching  Release notes · 11% of 258k · no terminal shows it")
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

    func testALinkWithNoSessionsYet() {
        let lines = StatusText.lines(config: Config(), sessions: [], link: CodexLinkStatus(at: now, connected: false), now: now)
        XCTAssertEqual(lines.last, "No running sessions seen yet.")
        XCTAssertEqual(lines[3], "  Codex link: waiting for Codex")
    }
}
