import ContextGuardCore
import ContextGuardTestSupport
@testable import ContextGuardCursor
import XCTest

/// The Cursor CLI's screen as `tmux capture-pane -e` shows it (captured from cursor-agent 2026.11.13).
enum CLIScreen {
    static let top = " \u{1B}[38;2;21;21;21m" + String(repeating: "▄", count: 100) + "\u{1B}[39m"
    static let bottom = " \u{1B}[38;2;21;21;21m" + String(repeating: "▀", count: 100) + "\u{1B}[39m"
    static let footer = ["  \u{1B}[2mAuto\u{1B}[0m", "  \u{1B}[2m~/code/demo · main\u{1B}[0m"]
    static let header = ["", "", "  Cursor Agent", "  v2026.11.13-eacade1", "", ""]

    static let emptyBox = " \u{1B}[48;2;21;21;21m \u{1B}[2m→ \u{1B}[0;7m\u{1B}[48;2;21;21;21mP\u{1B}[0;2m\u{1B}[48;2;21;21;21mlan, search, build anything\u{1B}[0m\u{1B}[48;2;21;21;21m      \u{1B}[49m"

    static func typedBox(_ text: String) -> String {
        " \u{1B}[48;2;21;21;21m → \(text)\u{1B}[7m \u{1B}[0m\u{1B}[48;2;21;21;21m        \u{1B}[49m"
    }

    static let summarizeBox = " \u{1B}[48;2;21;21;21m → \u{1B}[1m\u{1B}[36m/summarize\u{1B}[0;7m\u{1B}[48;2;21;21;21m \u{1B}[0m\u{1B}[48;2;21;21;21m      \u{1B}[49m"
    static let summarizeMenu = [
        "   → \u{1B}[1m/summarize\u{1B}[0m                \u{1B}[1mSummarize the conversation to reduce context\u{1B}[0m",
        "   \u{1B}[2m  /sdk\u{1B}[0m                      \u{1B}[2mGuide users building apps, scripts, CI pipelines, or automations on top of the Cursor…\u{1B}[0m",
    ]

    static func screen(box: [String], below: [String] = footer) -> String {
        (header + [top] + box + [bottom] + below + Array(repeating: "", count: 12)).joined(separator: "\n")
    }
}

/// The same screen as `herdr pane read --format ansi` shows it (herdr 0.9.5, cursor-agent 2026.11.13):
/// other escape sequences, the cursor drawn in reverse video, and CRLF at the end of each row.
enum HerdrScreen {
    static let top = " \u{1B}[0m\u{1B}[38;2;21;21;21m" + String(repeating: "▄", count: 100) + "\u{1B}[0m"
    static let bottom = " \u{1B}[0m\u{1B}[38;2;21;21;21m" + String(repeating: "▀", count: 100) + "\u{1B}[0m"
    static let footer = ["  \u{1B}[0m\u{1B}[2mAuto\u{1B}[0m \u{1B}[0m\u{1B}[2m·\u{1B}[0m \u{1B}[0m\u{1B}[2m17.3%\u{1B}[0m",
                         "  \u{1B}[0m\u{1B}[2m~/code/demo · main\u{1B}[0m"]

    static let emptyBox = " \u{1B}[0m\u{1B}[48;2;21;21;21m \u{1B}[0m\u{1B}[2m\u{1B}[48;2;21;21;21m→ \u{1B}[0m\u{1B}[7m\u{1B}[48;2;21;21;21mA\u{1B}[0m\u{1B}[2m\u{1B}[48;2;21;21;21mdd a follow-up\u{1B}[0m\u{1B}[48;2;21;21;21m          \u{1B}[0m"

    static func typedBox(_ text: String) -> String {
        " \u{1B}[0m\u{1B}[48;2;21;21;21m → \(text)\u{1B}[0m\u{1B}[7m\u{1B}[48;2;21;21;21m \u{1B}[0m\u{1B}[48;2;21;21;21m          \u{1B}[0m"
    }

    static let summarizeBox = " \u{1B}[0m\u{1B}[48;2;21;21;21m → \u{1B}[0m\u{1B}[1m\u{1B}[38;5;6m\u{1B}[48;2;21;21;21m/summarize\u{1B}[0m\u{1B}[7m\u{1B}[48;2;21;21;21m \u{1B}[0m\u{1B}[48;2;21;21;21m          \u{1B}[0m"
    static let summarizeMenu = [
        "   → \u{1B}[0m\u{1B}[1m/summarize\u{1B}[0m                \u{1B}[0m\u{1B}[1mSummarize the conversation to reduce context\u{1B}[0m",
        "   \u{1B}[0m\u{1B}[2m  /sdk\u{1B}[0m                      \u{1B}[0m\u{1B}[2mGuide users building apps, scripts, CI pipelines, or automations on top of the Cursor SDK…\u{1B}[0m",
    ]

    static func screen(box: [String], below: [String] = footer) -> String {
        (CLIScreen.header + [top] + box + [bottom] + below + Array(repeating: "", count: 12)).joined(separator: "\r\n")
    }
}

/// A pane running the Cursor CLI, driven through fake `tmux` / `herdr` calls.
final class FakePane: @unchecked Sendable {
    private let lock = NSLock()
    var box = ""
    /// What the slash menu offers for a box that starts with "/".
    var offersSummarize = true
    /// Shows a question instead of the prompt box.
    var blocked = false
    var summarizing = false
    var calls: [[String]] = []
    var environments: [[String: String]] = []

    func handle(_ args: [String], _ env: [String: String]) -> Command.Output? {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
        environments.append(env)
        var a = args
        if a.first == "-S" { a.removeFirst(2) }
        func ok(_ text: String = "") -> Command.Output { Command.Output(status: 0, stdout: Data(text.utf8)) }
        switch (a.first, a.dropFirst().first) {
        case ("capture-pane", _):
            return ok(screen())
        case ("pane", "read"):
            return ok(screen(herdr: true))
        case ("send-keys", _):
            if let i = a.firstIndex(of: "-l") { box += a[(a[i + 1] == "--" ? i + 2 : i + 1)...].joined(separator: " "); return ok() }
            return key(a.last!)
        case ("pane", "send-text"):
            box += a[3]
            return ok()
        case ("pane", "send-keys"):
            return key(a.last!)
        default:
            return Command.Output(status: 1, stdout: Data())
        }
    }

    private func key(_ k: String) -> Command.Output {
        switch k {
        case "Enter", "enter":
            if box == "/summarize", offersSummarize { summarizing = true }
            box = ""
        case "C-u", "ctrl+u":
            box = ""
        default:
            return Command.Output(status: 1, stdout: Data())
        }
        return Command.Output(status: 0, stdout: Data())
    }

    private func screen(herdr: Bool = false) -> String {
        if blocked { return (CLIScreen.header + ["  Run this command?", "  → Yes", "    No"]).joined(separator: herdr ? "\r\n" : "\n") }
        if herdr {
            if box.isEmpty { return HerdrScreen.screen(box: [HerdrScreen.emptyBox]) }
            if box == "/summarize", offersSummarize { return HerdrScreen.screen(box: [HerdrScreen.summarizeBox], below: HerdrScreen.summarizeMenu) }
            return HerdrScreen.screen(box: [HerdrScreen.typedBox(box)])
        }
        if box.isEmpty { return CLIScreen.screen(box: [CLIScreen.emptyBox]) }
        if box == "/summarize", offersSummarize { return CLIScreen.screen(box: [CLIScreen.summarizeBox], below: CLIScreen.summarizeMenu) }
        return CLIScreen.screen(box: [CLIScreen.typedBox(box)])
    }

    var started: Bool { lock.lock(); defer { lock.unlock() }; return summarizing }
}

final class CursorTerminalTypingTests: XCTestCase {
    func testReadsTheScreen() {
        XCTAssertEqual(CursorCLIScreen.boxText(CLIScreen.screen(box: [CLIScreen.emptyBox])), "")
        XCTAssertEqual(CursorCLIScreen.boxText(CLIScreen.screen(box: [CLIScreen.typedBox("hello there")])), "hello there")
        let menu = CLIScreen.screen(box: [CLIScreen.summarizeBox], below: CLIScreen.summarizeMenu)
        XCTAssertEqual(CursorCLIScreen.boxText(menu), "/summarize")
        XCTAssertEqual(CursorCLIScreen.pickedCommand(menu)?.hasPrefix("/summarize"), true)
        XCTAssertNil(CursorCLIScreen.pickedCommand(CLIScreen.screen(box: [CLIScreen.emptyBox])))
        // A draft of two lines.
        XCTAssertEqual(CursorCLIScreen.boxText(CLIScreen.screen(box: [CLIScreen.typedBox("first"), "   second"])), "first\nsecond")
        // No box: a question on screen, or not the CLI.
        XCTAssertNil(CursorCLIScreen.boxText("$ ls\nfoo\n"))
        XCTAssertNil(CursorCLIScreen.boxText(""))
        XCTAssertEqual(CursorCLIScreen.plain("a\u{1B}[0;7mb\u{1B}]8;;http://x\u{07}c\u{1B}"), "abc")
    }

    func testReadsHerdrsScreen() {
        XCTAssertEqual(CursorCLIScreen.boxText(HerdrScreen.screen(box: [HerdrScreen.emptyBox])), "")
        XCTAssertEqual(CursorCLIScreen.boxText(HerdrScreen.screen(box: [HerdrScreen.typedBox("hello there")])), "hello there")
        let menu = HerdrScreen.screen(box: [HerdrScreen.summarizeBox], below: HerdrScreen.summarizeMenu)
        XCTAssertEqual(CursorCLIScreen.boxText(menu), "/summarize")
        XCTAssertEqual(CursorCLIScreen.pickedCommand(menu), "/summarize                Summarize the conversation to reduce context")
        XCTAssertNil(CursorCLIScreen.pickedCommand(HerdrScreen.screen(box: [HerdrScreen.emptyBox])))
    }

    func testTheArrowIsDimmedOnlyInThePlaceholder() {
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: CLIScreen.emptyBox), true)
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: HerdrScreen.emptyBox), true)
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: CLIScreen.typedBox("hi")), false)
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: HerdrScreen.typedBox("hi")), false)
        // The 2 in a 24-bit color isn't dim; 22 and 0 end it.
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: "\u{1B}[38;2;2;2;2m→"), false)
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: "\u{1B}[2;38;5;2m→"), true)
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: "\u{1B}[2m\u{1B}[22m→"), false)
        XCTAssertEqual(CursorCLIScreen.dimmed("→", in: "\u{1B}[2m\u{1B}[m→"), false)
        XCTAssertNil(CursorCLIScreen.dimmed("→", in: "no arrow"))
    }

    let bin = TempDir()

    /// Stand-ins for `tmux` and `herdr` on `PATH`; `FakePane` answers what they're asked.
    func typing(_ pane: FakePane, env: [String: String] = [:]) -> CursorTerminalTyping {
        for name in ["tmux", "herdr"] {
            try! Data("#!/bin/sh\nexit 1\n".utf8).write(to: bin.file(name))
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.file(name).path)
        }
        var t = CursorTerminalTyping(environment: ["PATH": bin.url.path, "HOME": "/nonexistent"].merging(env) { $1 }, startWait: 1)
        t.pause = { _ in }
        t.runner = { _, args, env in pane.handle(args, env) }
        return t
    }

    let tmuxChat = CursorChatRef(id: "c", name: "Chat", surface: .cli, pid: 7,
                                 terminal: CursorTerminal(kind: .tmux, pane: "%3", socket: "/tmp/tmux-501/default"))

    func testSummarizesThroughTmux() throws {
        let pane = FakePane()
        let t = typing(pane)
        XCTAssertEqual(t.reach(tmuxChat), .ready)
        XCTAssertEqual(t.compact(tmuxChat, started: { pane.started }), .compacted(continued: false))
        XCTAssertTrue(pane.started)
        XCTAssertEqual(pane.calls.first, ["-S", "/tmp/tmux-501/default", "capture-pane", "-p", "-e", "-t", "%3"])
        XCTAssertTrue(pane.calls.contains(["-S", "/tmp/tmux-501/default", "send-keys", "-t", "%3", "-l", "--", "/summarize"]))
        XCTAssertEqual(pane.calls.last, ["-S", "/tmp/tmux-501/default", "send-keys", "-t", "%3", "Enter"])
    }

    func testNeverTypesOverADraft() throws {
        let pane = FakePane()
        pane.box = "half a thought"
        let t = typing(pane)
        XCTAssertEqual(t.compact(tmuxChat, started: { pane.started }), .draft)
        XCTAssertEqual(t.send(tmuxChat, text: "go on"), .draft)
        XCTAssertEqual(pane.box, "half a thought")
        XCTAssertFalse(pane.calls.contains { $0.contains("send-keys") })
    }

    func testWaitsWhileTheCLIAsksSomething() throws {
        let pane = FakePane()
        pane.blocked = true
        XCTAssertEqual(typing(pane).compact(tmuxChat, started: { pane.started }), .notNow("the Cursor CLI isn't showing its prompt"))
    }

    func testTakesBackWhatItTypedWhenSummarizeIsNotOffered() throws {
        let pane = FakePane()
        pane.offersSummarize = false
        XCTAssertEqual(typing(pane).compact(tmuxChat, started: { pane.started }), .failed("the Cursor CLI didn't offer its /summarize command"))
        XCTAssertEqual(pane.box, "")
        XCTAssertFalse(pane.calls.contains { $0.last == "Enter" })
    }

    func testSaysWhenTheSummaryDidNotStart() throws {
        let pane = FakePane()
        XCTAssertEqual(typing(pane).compact(tmuxChat, started: { false }), .failed("the Cursor CLI didn't start summarizing"))
    }

    func testSendsThroughHerdr() throws {
        // Found where herdr says it is, though not on PATH.
        let dir = TempDir()
        let herdr = dir.file("herdr")
        try Data("#!/bin/sh\n".utf8).write(to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        let pane = FakePane()
        var t = typing(pane, env: ["HERDR_BIN_PATH": herdr.path])
        t.environment["PATH"] = "/nonexistent"
        let chat = CursorChatRef(id: "c", name: "Chat", surface: .cli, pid: 7,
                                 terminal: CursorTerminal(kind: .herdr, pane: "w1:p2", socket: "/s/herdr.sock"))
        XCTAssertEqual(t.reach(chat), .ready)
        XCTAssertEqual(t.send(chat, text: "Carry on where\nyou left off."), .sent)
        XCTAssertEqual(pane.calls, [
            ["pane", "read", "w1:p2", "--source", "visible", "--format", "ansi"],
            ["pane", "send-text", "w1:p2", "Carry on where you left off."],
            ["pane", "read", "w1:p2", "--source", "visible", "--format", "ansi"],
            ["pane", "send-keys", "w1:p2", "enter"],
        ])
        XCTAssertEqual(pane.environments.last?["HERDR_SOCKET_PATH"], "/s/herdr.sock")
        XCTAssertEqual(t.compact(chat, started: { pane.started }), .compacted(continued: false))
        // Never over a draft in herdr's pane either.
        pane.box = "my draft"
        XCTAssertEqual(t.compact(chat, started: { true }), .draft)
        XCTAssertEqual(pane.box, "my draft")
    }

    func testNoTerminalNoTyping() {
        let pane = FakePane()
        let chat = CursorChatRef(id: "c", name: "Chat", surface: .cli, pid: 7)
        XCTAssertEqual(typing(pane).reach(chat), .never)
        XCTAssertEqual(typing(pane).compact(chat, started: { true }), .failed("Context Guard can't reach the chat's terminal"))
        // herdr isn't installed (no herdr on this PATH).
        let herdrChat = CursorChatRef(id: "c", name: "Chat", surface: .cli, pid: 7, terminal: CursorTerminal(kind: .herdr, pane: "w1:p1"))
        var t = typing(pane)
        t.environment = ["PATH": "/nonexistent", "HOME": "/nonexistent"]
        XCTAssertEqual(t.reach(herdrChat), .never)
        XCTAssertTrue(pane.calls.isEmpty)
    }

    func testOneLine() {
        XCTAssertEqual(CursorTerminalTyping.oneLine("a\n\n  b \r\nc"), "a b c")
    }
}
