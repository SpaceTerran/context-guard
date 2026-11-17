import AppKit
import ApplicationServices
import ContextGuardCore
import Foundation

/// Types into a chat in the Cursor app as you would, using Cursor's own Accessibility permission (it
/// runs inside Cursor's hook). Finds the chat's prompt box by Accessibility where the chat is on
/// screen (its panel in the Agents window, or its tab in an editor window; Cursor's chat links open
/// only cloud agents), checks it's empty, focuses it and posts key events to Cursor alone: all in
/// one go, then the app that was in front gets focus back. Never switches which chat a window shows,
/// never types over a draft, never types while you're using the computer.
struct CursorAppTyping: Sendable {
    /// You've used no keyboard or mouse for this long.
    var idleNeeded: TimeInterval = 10
    /// Seconds since your last key press, click or mouse move.
    var idle: @Sendable () -> TimeInterval = CursorAppTyping.idleSeconds
    /// How long Cursor gets to start summarizing after Return.
    var startWait: TimeInterval = 12

    /// Never while the chat isn't on screen: you can summarize it yourself, or open it.
    func reach(_ chat: CursorChatRef) -> TypingReach {
        guard AXIsProcessTrusted(), let name = chat.name, !name.isEmpty,
              Session(pid: chat.pid).findBox(chat: name) != nil else { return .never }
        return idle() >= idleNeeded ? .ready : .notNow
    }

    func compact(_ chat: CursorChatRef, started: @escaping @Sendable () -> Bool,
                 continueText: @escaping @Sendable () -> String?) -> CursorTypingResult {
        drive(chat) { s in
            guard s.type("/summarize", chunk: 1), s.boxValue() == "/summarize", s.windowShows("Summarize the conversation") else {
                s.clearBox(typed: "/summarize")
                return .failed("Cursor didn't offer its Summarize command")
            }
            s.key(Keys.returnKey)
            let deadline = Date().addingTimeInterval(startWait)
            while !started() {
                guard Date() < deadline else { return .failed("Cursor didn't start summarizing") }
                usleep(250_000)
            }
            guard let text = continueText().map(CursorTerminalTyping.oneLine), !text.isEmpty else { return .compacted(continued: false) }
            // Cursor holds it until the summary is done.
            usleep(300_000)
            guard s.boxValue() == "", s.type(text), s.boxValue() == text else {
                s.clearBox(typed: text)
                return .compacted(continued: false)
            }
            s.key(Keys.returnKey)
            return .compacted(continued: true)
        }
    }

    func send(_ chat: CursorChatRef, text: String) -> CursorTypingResult {
        let line = CursorTerminalTyping.oneLine(text)
        return drive(chat) { s in
            guard s.type(line), s.boxValue() == line else {
                s.clearBox(typed: line)
                return .failed("the text didn't land in Cursor's prompt box")
            }
            s.key(Keys.returnKey)
            return .sent
        }
    }

    // MARK: - One activation

    private func drive(_ chat: CursorChatRef, _ body: (Session) -> CursorTypingResult) -> CursorTypingResult {
        guard AXIsProcessTrusted() else { return .failed("Context Guard can't use Cursor's Accessibility permission") }
        guard idle() >= idleNeeded else { return .notNow("you're using the computer") }
        guard let name = chat.name, !name.isEmpty else { return .failed("the chat has no name yet") }
        guard let cursor = NSRunningApplication(processIdentifier: chat.pid) else { return .failed("Cursor isn't running") }
        let s = Session(pid: chat.pid, idle: idle)
        guard let (window, box) = s.findBox(chat: name) else { return .notNow("the chat isn't open in Cursor") }
        s.box = box
        guard s.boxValue() == "" else { return .draft }

        let previous = Self.frontApp()
        defer { Self.handBack(previous, from: chat.pid) }
        Self.bringForward(cursor)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(3)
        while !s.stillHere() {
            guard Date() < deadline else { return .failed("Cursor didn't put the chat's prompt box in focus") }
            usleep(150_000)
            AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // Looked at again now it's in front: you may have typed in it a moment ago.
        guard s.boxValue() == "" else { return .draft }
        let result = body(s)
        if s.interrupted, case .failed = result { return .notNow("you started using the computer") }
        return result
    }

    /// The app whose window is on top of the screen. Asked of the window server each time:
    /// `NSWorkspace.frontmostApplication` only changes while the main run loop runs, which a hook
    /// process's doesn't, so it keeps naming the app that was in front when first asked.
    static func frontApp() -> NSRunningApplication? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let top = windows.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let pid = top[kCGWindowOwnerPID as String] as? Int32,
           let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// Back to the app that was in front, unless that was Cursor.
    static func handBack(_ previous: NSRunningApplication?, from pid: pid_t) {
        guard let previous, previous.processIdentifier != pid, !previous.isTerminated else { return }
        bringForward(previous)
    }

    /// Through Launch Services, as `open` does: a background process's `activate()` is declined.
    static func bringForward(_ app: NSRunningApplication) {
        if let id = app.bundleIdentifier,
           Command.run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", id], timeout: 5)?.status == 0 { return }
        app.activate()
    }

    /// Seconds since your last key press, click or mouse move (the hardware's, not posted events).
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    enum Keys {
        static let returnKey: CGKeyCode = 36
        static let delete: CGKeyCode = 51
        static let a: CGKeyCode = 0
    }

    /// Cursor's Accessibility tree, and key events posted to Cursor only.
    final class Session {
        let pid: pid_t
        let app: AXUIElement
        var box: AXUIElement?
        /// You touched the keyboard or mouse after typing began: it stops there.
        private(set) var interrupted = false
        private let began = Date()
        private let source = CGEventSource(stateID: .privateState)
        private let idle: () -> TimeInterval

        init(pid: pid_t, idle: @escaping () -> TimeInterval = CursorAppTyping.idleSeconds) {
            self.pid = pid
            self.idle = idle
            app = AXUIElementCreateApplication(pid)
            // Electron builds its tree only for a client that asks.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        /// The chat's prompt box and its window, if the chat is on screen: the Agents window's panel
        /// for it (a group named after it, holding the box), or its selected tab in an editor window
        /// (described "<name>, Chat Editors…"; the box is in the same editor group). nil when it isn't
        /// shown, or two different boxes claim the name.
        func findBox(chat name: String) -> (AXUIElement, AXUIElement)? {
            var found: [(AXUIElement, AXUIElement)] = []
            for window in Self.attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                var boxes: [AXUIElement] = []
                var groups: [AXUIElement] = []
                var tabs: [AXUIElement] = []
                var seen = 0
                func walk(_ e: AXUIElement, _ depth: Int) {
                    seen += 1
                    guard seen < 20_000, depth < 90 else { return }
                    let role = Self.string(e, kAXRoleAttribute)
                    let title = Self.string(e, kAXTitleAttribute), desc = Self.string(e, kAXDescriptionAttribute)
                    switch role {
                    case "AXTextArea" where Self.label(e).hasPrefix("Prompt"):
                        boxes.append(e)
                        return
                    case "AXGroup" where title == name || desc == name:
                        groups.append(e)
                    case "AXRadioButton" where title == name || desc == name || desc.hasPrefix(name + ", Chat Editors"):
                        if (Self.attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1 { tabs.append(e) }
                    default:
                        break
                    }
                    // The transcript holds most of the window and never a prompt box.
                    if title == "Chat transcript" || desc == "Chat transcript" { return }
                    for k in Self.children(e) { walk(k, depth + 1) }
                }
                walk(window, 0)
                guard !boxes.isEmpty else { continue }
                let chains = boxes.map { (box: $0, up: Self.ancestors($0)) }
                func holding(_ a: AXUIElement) -> [AXUIElement] {
                    chains.filter { $0.up.contains { CFEqual($0, a) } }.map(\.box)
                }
                // A group named after the chat must hold the box itself (a tab's label is a group too).
                for g in groups {
                    let inside = holding(g)
                    if inside.count == 1 { found.append((window, inside[0])) }
                }
                // A selected tab: the box in the nearest enclosing part that has one.
                for t in tabs {
                    for a in Self.ancestors(t).prefix(12) {
                        let inside = holding(a)
                        if inside.isEmpty { continue }
                        if inside.count == 1 { found.append((window, inside[0])) }
                        break
                    }
                }
            }
            // Two different boxes claim the name (two chats called the same, or one chat in two
            // windows): which one is meant can't be told.
            guard let first = found.first, found.allSatisfy({ CFEqual($0.1, first.1) }) else { return nil }
            return first
        }

        /// The box's text, trimmed (an empty box reads as a line break).
        func boxValue() -> String? {
            guard let box else { return nil }
            return Self.string(box, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Whether the focused window shows `text` anywhere (the slash menu's entry).
        func windowShows(_ text: String) -> Bool {
            usleep(400_000)
            guard let window = Self.attr(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return false }
            var seen = 0
            func walk(_ e: AXUIElement, _ depth: Int) -> Bool {
                seen += 1
                guard seen < 8_000, depth < 80 else { return false }
                if Self.label(e).contains(text) || Self.string(e, kAXValueAttribute).prefix(400).contains(text) { return true }
                for k in Self.children(e) where walk(k, depth + 1) { return true }
                return false
            }
            return walk(window, 0)
        }

        /// Types `text`, `chunk` characters per key event. Only while Cursor is in front and the box
        /// still has focus.
        @discardableResult
        func type(_ text: String, chunk: Int = 20) -> Bool {
            guard stillHere() else { return false }
            var units = Array(text.utf16)[...]
            while !units.isEmpty {
                let piece = Array(units.prefix(chunk))
                units = units.dropFirst(piece.count)
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return false }
                    ev.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                    ev.postToPid(pid)
                    usleep(12_000)
                }
            }
            usleep(300_000)
            return stillHere()
        }

        func key(_ code: CGKeyCode, flags: CGEventFlags = [], evenIfYouAreBack: Bool = false) {
            guard evenIfYouAreBack ? inFront() : stillHere() else { return }
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                ev.flags = flags
                ev.postToPid(pid)
                usleep(12_000)
            }
        }

        /// Takes back what Context Guard typed (the box was empty before it did), but only while the
        /// box holds nothing else: what you typed stays.
        func clearBox(typed: String) {
            guard let v = boxValue(), !v.isEmpty, typed.hasPrefix(v) else { return }
            key(Keys.a, flags: .maskCommand, evenIfYouAreBack: true)
            usleep(100_000)
            guard boxValue().map({ typed.hasPrefix($0) }) == true else { return }
            key(Keys.delete, evenIfYouAreBack: true)
            usleep(200_000)
        }

        /// Cursor is in front and the box has focus. Both asked of Cursor itself.
        func inFront() -> Bool {
            guard (Self.attr(app, kAXFrontmostAttribute) as? Bool) == true, let box,
                  let focused = Self.attr(app, kAXFocusedUIElementAttribute) else { return false }
            return CFEqual(focused, box)
        }

        /// Cursor is in front, the box has focus and you haven't touched anything since this began:
        /// keys go nowhere else, and never mix with yours.
        func stillHere() -> Bool {
            if idle() + 0.25 < Date().timeIntervalSince(began) { interrupted = true }
            return !interrupted && inFront()
        }

        static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }

        static func string(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }

        static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

        /// Its parent, its parent's parent, and so on up to the window.
        static func ancestors(_ e: AXUIElement) -> [AXUIElement] {
            var out: [AXUIElement] = []
            var cur = attr(e, kAXParentAttribute).map { $0 as! AXUIElement }
            while let c = cur, out.count < 120 {
                out.append(c)
                if string(c, kAXRoleAttribute) == "AXWindow" { break }
                cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
            }
            return out
        }

        /// Title, description and placeholder, as one line.
        static func label(_ e: AXUIElement) -> String {
            [string(e, kAXTitleAttribute), string(e, kAXDescriptionAttribute), string(e, kAXPlaceholderValueAttribute)]
                .filter { !$0.isEmpty }.joined(separator: " | ")
        }
    }
}
