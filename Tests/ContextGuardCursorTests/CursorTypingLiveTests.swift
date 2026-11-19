import ApplicationServices
import ContextGuardCore
@testable import ContextGuardCursor
import XCTest

/// Typing into real Cursor chats on this Mac. Skipped unless the chat to use is named in the
/// environment: a scratch chat only, never one of yours.
final class CursorTypingLiveTests: XCTestCase {
    let env = ProcessInfo.processInfo.environment

    /// CG_LIVE_TMUX_SOCKET, CG_LIVE_TMUX_PANE: a pane running `cursor-agent` with a finished turn.
    func testSummarizeInTmux() throws {
        guard let socket = env["CG_LIVE_TMUX_SOCKET"], let pane = env["CG_LIVE_TMUX_PANE"] else { throw XCTSkip("no live tmux pane") }
        let t = CursorTerminalTyping(environment: env)
        let chat = CursorChatRef(id: "live", name: nil, surface: .cli, pid: 1, terminal: CursorTerminal(kind: .tmux, pane: pane, socket: socket))
        XCTAssertEqual(t.reach(chat), .ready)
        let result = t.compact(chat, started: {
            let screen = t.read(chat.terminal!).map(CursorCLIScreen.plain) ?? ""
            return screen.contains("Summariz")
        })
        XCTAssertEqual(result, .compacted(continued: false))
    }

    /// CG_LIVE_CURSOR_CHAT, CG_LIVE_CURSOR_NAME, CG_LIVE_CURSOR_PID, CG_LIVE_PRECOMPACT_DIR (where the
    /// chat's project hooks log `preCompact`).
    func testSummarizeInTheApp() throws {
        guard let id = env["CG_LIVE_CURSOR_CHAT"], let name = env["CG_LIVE_CURSOR_NAME"],
              let pid = env["CG_LIVE_CURSOR_PID"].flatMap({ Int32($0) }), let logs = env["CG_LIVE_PRECOMPACT_DIR"] else {
            throw XCTSkip("no live Cursor chat")
        }
        let t = CursorAppTyping(idleNeeded: 60)
        let chat = CursorChatRef(id: id, name: name, surface: .app, pid: pid)
        XCTAssertEqual(t.reach(chat), .ready)
        let since = Date()
        let result = t.compact(chat, started: {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: logs)) ?? []
            return files.contains { f in
                f.hasSuffix("-preCompact.json") && (Double(f.split(separator: "-").first ?? "") ?? 0) >= since.timeIntervalSince1970 - 1
            }
        }, continueText: { "Context Guard live test: reply with just OK." })
        print("LIVE RESULT:", result)
        XCTAssertEqual(result, .compacted(continued: true))
    }

    /// CG_LIVE_CURSOR_CHAT, CG_LIVE_CURSOR_NAME, CG_LIVE_CURSOR_PID: you touch the keyboard or mouse
    /// as `/summarize` lands in the chat's prompt box. Nothing outside the hardware can make the
    /// system's idle reading drop, so it reads 0 from that moment, as a key press makes it. Typing
    /// stops, takes back what it typed, and the app that was in front gets focus back.
    func testYourInputWhileTypingStopsIt() throws {
        guard env["CG_LIVE_CURSOR_CHAT"] != nil, let name = env["CG_LIVE_CURSOR_NAME"],
              let pid = env["CG_LIVE_CURSOR_PID"].flatMap({ Int32($0) }) else {
            throw XCTSkip("no live Cursor chat")
        }
        let touched = Flag(), done = Flag()
        DispatchQueue.global().async {
            let cursor = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(cursor, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            while !done.value {
                var focused: AnyObject?, value: AnyObject?
                if AXUIElementCopyAttributeValue(cursor, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                   let element = focused, AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
                   (value as? String)?.hasPrefix("/") == true {
                    touched.set()
                }
                usleep(5_000)
            }
        }
        defer { done.set() }
        var t = CursorAppTyping(idleNeeded: 60)
        t.idle = { touched.value ? 0 : CursorAppTyping.idleSeconds() }
        let chat = CursorChatRef(id: "live", name: name, surface: .app, pid: pid)
        XCTAssertEqual(t.reach(chat), .ready, "you've been away a minute")
        let before = CursorAppTyping.frontApp()?.processIdentifier
        let result = t.compact(chat, started: { false }, continueText: { nil })
        print("LIVE RESULT:", result)
        XCTAssertTrue(touched.value, "/summarize began to land")
        XCTAssertEqual(result, .notNow("you started using the computer"))
        usleep(500_000)
        XCTAssertEqual(CursorAppTyping.frontApp()?.processIdentifier, before, "focus went back")
        let s = CursorAppTyping.Session(pid: pid)
        guard case .shown(_, let box)? = s.locate(chat: name, namesakes: { 0 }) else { return XCTFail("the chat is on screen") }
        s.box = box
        XCTAssertEqual(s.boxValue(), "", "what it typed was taken back")
    }
}

/// A flag set from one thread and read from another.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set() { lock.lock(); on = true; lock.unlock() }
}
