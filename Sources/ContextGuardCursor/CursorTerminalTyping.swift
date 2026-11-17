import ContextGuardCore
import Foundation

/// What the Cursor CLI shows in its pane, read from the screen with its colors: its prompt box (the
/// rows between a row of `▄` and a row of `▀`) and the slash-command menu under it. tmux
/// (`capture-pane -e`) and herdr (`pane read --format ansi`) draw the same screen with different
/// escape sequences, and herdr ends its rows with CRLF.
enum CursorCLIScreen {
    /// The text in the prompt box ("" when it's empty and shows its dimmed placeholder). nil when the
    /// screen shows no prompt box (a question, a permission prompt, or not the CLI at all).
    static func boxText(_ ansi: String) -> String? {
        guard let (rows, top, bottom) = box(ansi) else { return nil }
        let lines = rows[(top + 1)..<bottom]
        guard let first = lines.first else { return nil }
        // The placeholder's arrow is dimmed; once you type, it isn't.
        if lines.count == 1, dimmed("→", in: first) == true { return "" }
        let text = lines.map { plain($0).trimmingCharacters(in: .whitespaces) }
        var joined = text.joined(separator: "\n")
        if joined.hasPrefix("→") { joined = String(joined.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return joined
    }

    /// The slash-menu entry that Return would pick (marked with an arrow), as plain text.
    static func pickedCommand(_ ansi: String) -> String? {
        guard let (rows, _, bottom) = box(ansi) else { return nil }
        for row in rows[(bottom + 1)...] {
            let line = plain(row).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("→") { return String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// The rows, and where the last prompt box on screen starts and ends.
    private static func box(_ ansi: String) -> ([String], Int, Int)? {
        let rows = ansi.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func all(_ row: String, _ ch: Character) -> Bool {
            let t = plain(row).trimmingCharacters(in: .whitespaces)
            return t.count >= 10 && t.allSatisfy { $0 == ch }
        }
        guard let top = rows.lastIndex(where: { all($0, "▄") }),
              let bottom = rows[(top + 1)...].firstIndex(where: { all($0, "▀") }), bottom > top + 1 else { return nil }
        return (rows, top, bottom)
    }

    /// Whether `mark` is drawn dimmed (SGR 2) where it first shows in `row`; nil when it doesn't.
    static func dimmed(_ mark: Unicode.Scalar, in row: String) -> Bool? {
        var dim = false
        var it = row.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == mark { return dim }
            guard c == "\u{1B}" else { continue }
            guard it.next() == "[" else { continue }
            var params = ""
            var final: Unicode.Scalar?
            while let d = it.next() {
                if (0x40...0x7E).contains(d.value) { final = d; break }
                params.unicodeScalars.append(d)
            }
            guard final == "m" else { continue }
            // SGR: 0 resets, 2 dims, 22 undims; 38/48/58 carry a color (5;n or 2;r;g;b), skipped.
            let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var i = 0
            while i < codes.count {
                switch codes[i] {
                case 0: dim = false
                case 2: dim = true
                case 22: dim = false
                case 38, 48, 58: i += i + 1 < codes.count && codes[i + 1] == 5 ? 2 : 4
                default: break
                }
                i += 1
            }
        }
        return nil
    }

    /// Without terminal escape sequences.
    static func plain(_ s: String) -> String {
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\u{1B}" else { out.unicodeScalars.append(c); continue }
            guard let next = it.next() else { break }
            if next == "[" {
                // CSI: parameters, then a final byte in @…~.
                while let d = it.next(), !(0x40...0x7E).contains(d.value) {}
            } else if next == "]" {
                // OSC: up to BEL or ESC \.
                while let d = it.next(), d != "\u{07}", d != "\u{1B}" {}
            }
        }
        return out
    }
}

/// Types into a Cursor CLI chat through its terminal program: tmux (`send-keys`, `capture-pane`) or
/// herdr (`pane send-text`, `send-keys`, `read`). Never keystrokes, so it works whatever app is in
/// front, and it never types over text in the box.
struct CursorTerminalTyping: Sendable {
    var environment: [String: String]
    /// How long Cursor gets to start summarizing after Return.
    var startWait: TimeInterval = 12
    var pause: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var runner: @Sendable (URL, [String], [String: String]) -> Command.Output? = { program, args, env in
        Command.run(program, args, environment: env, timeout: 5)
    }

    func reach(_ chat: CursorChatRef) -> TypingReach {
        guard let t = chat.terminal else { return .never }
        return program(t) == nil ? .never : .ready
    }

    func compact(_ chat: CursorChatRef, started: @escaping @Sendable () -> Bool) -> CursorTypingResult {
        guard let t = chat.terminal, program(t) != nil else { return .failed("Context Guard can't reach the chat's terminal") }
        if let problem = checkEmpty(t) { return problem }
        guard type(t, text: "/summarize") else { return .failed("the terminal didn't take the text") }
        pause(0.6)
        guard let screen = read(t), CursorCLIScreen.boxText(screen) == "/summarize",
              CursorCLIScreen.pickedCommand(screen)?.hasPrefix("/summarize") == true else {
            clear(t)
            return .failed("the Cursor CLI didn't offer its /summarize command")
        }
        guard key(t, .enter) else { return .failed("the terminal didn't take Return") }
        let deadline = Date().addingTimeInterval(startWait)
        while Date() < deadline {
            if started() { return .compacted(continued: false) }
            pause(0.25)
        }
        return started() ? .compacted(continued: false) : .failed("the Cursor CLI didn't start summarizing")
    }

    func send(_ chat: CursorChatRef, text: String) -> CursorTypingResult {
        guard let t = chat.terminal, program(t) != nil else { return .failed("Context Guard can't reach the chat's terminal") }
        if let problem = checkEmpty(t) { return problem }
        let line = Self.oneLine(text)
        guard type(t, text: line) else { return .failed("the terminal didn't take the text") }
        pause(0.3)
        guard let screen = read(t), let typed = CursorCLIScreen.boxText(screen),
              typed.replacingOccurrences(of: "\n", with: "").hasPrefix(String(line.prefix(20))) else {
            clear(t)
            return .failed("the text didn't show in the Cursor CLI's prompt")
        }
        return key(t, .enter) ? .sent : .failed("the terminal didn't take Return")
    }

    /// nil when the box is there and empty.
    private func checkEmpty(_ t: CursorTerminal) -> CursorTypingResult? {
        guard let screen = read(t) else { return .failed("Context Guard couldn't read the chat's terminal") }
        guard let text = CursorCLIScreen.boxText(screen) else { return .notNow("the Cursor CLI isn't showing its prompt") }
        return text.isEmpty ? nil : .draft
    }

    /// The prompt box takes one line: Return would send it.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    enum Key { case enter, clearLine }

    private func program(_ t: CursorTerminal) -> URL? {
        switch t.kind {
        case .tmux: return Command.find("tmux", environment: environment)
        case .herdr: return Command.find("herdr", environment: environment, also: environment["HERDR_BIN_PATH"].map {
            [($0 as NSString).deletingLastPathComponent] } ?? [])
        }
    }

    private func env(_ t: CursorTerminal) -> [String: String] {
        var env = environment
        if t.kind == .herdr, let socket = t.socket { env["HERDR_SOCKET_PATH"] = socket }
        return env
    }

    private func tmux(_ t: CursorTerminal, _ args: [String]) -> [String] {
        (t.socket.map { ["-S", $0] } ?? []) + args
    }

    private func run(_ t: CursorTerminal, _ args: [String]) -> Command.Output? {
        guard let program = program(t) else { return nil }
        let full = t.kind == .tmux ? tmux(t, args) : args
        guard let out = runner(program, full, env(t)), out.status == 0 else { return nil }
        return out
    }

    func read(_ t: CursorTerminal) -> String? {
        switch t.kind {
        case .tmux: return run(t, ["capture-pane", "-p", "-e", "-t", t.pane])?.text
        case .herdr: return run(t, ["pane", "read", t.pane, "--source", "visible", "--format", "ansi"])?.text
        }
    }

    private func type(_ t: CursorTerminal, text: String) -> Bool {
        switch t.kind {
        case .tmux: return run(t, ["send-keys", "-t", t.pane, "-l", "--", text]) != nil
        case .herdr: return run(t, ["pane", "send-text", t.pane, text]) != nil
        }
    }

    private func key(_ t: CursorTerminal, _ key: Key) -> Bool {
        switch (t.kind, key) {
        case (.tmux, .enter): return run(t, ["send-keys", "-t", t.pane, "Enter"]) != nil
        case (.tmux, .clearLine): return run(t, ["send-keys", "-t", t.pane, "C-u"]) != nil
        case (.herdr, .enter): return run(t, ["pane", "send-keys", t.pane, "enter"]) != nil
        case (.herdr, .clearLine): return run(t, ["pane", "send-keys", t.pane, "ctrl+u"]) != nil
        }
    }

    /// Takes back what Context Guard typed: the box was empty before it did.
    private func clear(_ t: CursorTerminal) {
        _ = key(t, .clearLine)
    }
}
