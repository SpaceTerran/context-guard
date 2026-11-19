import AppKit
import ApplicationServices
import ContextGuardCore
import Foundation

/// Types into a chat in the Cursor app as you would, using Cursor's own Accessibility permission (it
/// runs inside Cursor's hook). Finds the chat's prompt box by Accessibility where the chat is open on
/// this screen (its panel in the Agents window, or its tab in an editor window; Cursor's chat links
/// open only cloud agents), checks it's empty, focuses it and posts key events to Cursor alone: all
/// in one go, then the app that was in front gets focus back. A chat whose editor tab is open but
/// behind another tab is brought to the front of its group for that, and the tab you had there comes
/// back after; a minimized window goes back to the Dock. Never types over a draft, never types while
/// you're using the computer or the screen is locked, and never into a chat that shares its name with
/// another one Cursor lists (the screen can't tell them apart).
struct CursorAppTyping: Sendable {
    /// You've used no keyboard or mouse for this long.
    var idleNeeded: TimeInterval = 10
    /// Seconds since your last key press, click or mouse move.
    var idle: @Sendable () -> TimeInterval = CursorAppTyping.idleSeconds
    /// The screen is locked: Cursor's windows aren't there to look at.
    var locked: @Sendable () -> Bool = CursorAppTyping.screenLocked
    /// How many other chats Cursor lists under this chat's name (nil: can't tell).
    var namesakes: @Sendable (_ id: String, _ name: String) -> Int? = { CursorAppStore().namesakes(of: $0, named: $1) }
    /// How long Cursor gets to start summarizing after Return.
    var startWait: TimeInterval = 12

    /// Looks for the chat only when typing could start: while you're using the computer, or the screen
    /// is locked, it waits without looking.
    func reach(_ chat: CursorChatRef) -> TypingReach {
        guard AXIsProcessTrusted(), let name = chat.name, !name.isEmpty else { return .never }
        guard !locked(), idle() >= idleNeeded else { return .notNow }
        return Session(pid: chat.pid).locate(chat: name, namesakes: others(chat, name)) != nil ? .ready : .notShown
    }

    /// The other chats Cursor lists under this one's name, counted when asked.
    private func others(_ chat: CursorChatRef, _ name: String) -> () -> Int? {
        { namesakes(chat.id, name) }
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
        guard !locked() else { return .notNow("the screen is locked") }
        guard idle() >= idleNeeded else { return .notNow("you're using the computer") }
        guard let name = chat.name, !name.isEmpty else { return .failed("the chat has no name yet") }
        guard let cursor = NSRunningApplication(processIdentifier: chat.pid) else { return .failed("Cursor isn't running") }
        let s = Session(pid: chat.pid, idle: idle)
        guard let place = s.locate(chat: name, namesakes: others(chat, name)) else { return .notNow("the chat isn't open in Cursor") }
        if case .shown(_, let box) = place {
            s.box = box
            guard s.boxValue() == "" else { return .draft }
        }

        let previous = Self.frontApp()
        defer { Self.handBack(previous, from: chat.pid) }
        // These run first, last one first: the tab you had in front comes back, then a window you had
        // in the Dock goes back there, while Cursor is still in front.
        let minimized = (Session.attr(place.window, kAXMinimizedAttribute) as? Bool) == true
        defer { if minimized, s.untouched() { AXUIElementSetAttributeValue(place.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) } }
        var tabBack: AXUIElement?
        defer { if let tabBack, s.untouched() { AXUIElementPerformAction(tabBack, kAXPressAction as CFString) } }
        Self.bringForward(cursor)
        if minimized { AXUIElementSetAttributeValue(place.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementPerformAction(place.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(place.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if case .tab(let window, let tab) = place {
            let before = Session.selectedBeside(tab)
            guard AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success else {
                return .failed("Cursor didn't bring the chat's tab to the front")
            }
            tabBack = before
            let deadline = Date().addingTimeInterval(3)
            while true {
                if case .shown(let w, let box)? = s.locate(chat: name, namesakes: others(chat, name)), CFEqual(w, window) {
                    s.box = box
                    break
                }
                guard Date() < deadline else { return .failed("Cursor didn't show the chat when its tab was picked") }
                usleep(150_000)
            }
            guard s.boxValue() == "" else { return .draft }
        }
        guard let box = s.box else { return .failed("the chat's prompt box wasn't found") }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(3)
        while !s.stillHere() {
            if s.interrupted { return .notNow("you started using the computer") }
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

    /// The login window covers the screen: while it does, an app's Accessibility windows aren't its
    /// windows (each reads as the app itself).
    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
    }

    /// Where the chat is open.
    enum Place {
        /// On screen: its prompt box, and the window it's in.
        case shown(window: AXUIElement, box: AXUIElement)
        /// Its tab in an editor window, behind another tab in the same group.
        case tab(window: AXUIElement, tab: AXUIElement)

        var window: AXUIElement {
            switch self {
            case .shown(let window, _), .tab(let window, _): return window
            }
        }
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

        /// Where the chat is open in this screen's Cursor windows: on screen, the Agents window's
        /// panel for it (a group named after it, holding the box) or its selected tab in an editor
        /// window (described "<name>, Chat Editors…"; the box is in the same editor group); or its
        /// editor tab behind another one. On screen comes first, then the front window; which one of
        /// these is the chat is `pick`'s. A window on another desktop isn't in Cursor's windows.
        func locate(chat name: String, namesakes: () -> Int?) -> Place? {
            var shown: [Place] = []
            var behind: [Place] = []
            for window in windows() {
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
                        if Self.selected(e) {
                            tabs.append(e)
                        } else if desc.hasPrefix(name + ", Chat Editors") {
                            behind.append(.tab(window: window, tab: e))
                        }
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
                func add(_ box: AXUIElement) {
                    guard !shown.contains(where: { if case .shown(_, let b) = $0 { return CFEqual(b, box) }; return false }) else { return }
                    shown.append(.shown(window: window, box: box))
                }
                // A group named after the chat must hold the box itself (a tab's label is a group too).
                for g in groups {
                    let inside = holding(g)
                    if inside.count == 1 { add(inside[0]) }
                }
                // A selected tab: the box in the nearest enclosing part that has one.
                for t in tabs {
                    for a in Self.ancestors(t).prefix(12) {
                        let inside = holding(a)
                        if inside.isEmpty { continue }
                        if inside.count == 1 { add(inside[0]) }
                        break
                    }
                }
            }
            return Self.pick(shown + behind, namesakes: namesakes)
        }

        /// The first of the places showing a chat's name, if it's surely that chat. Another chat Cursor
        /// lists under the name could be any of them, so with one there's none to type into; with none,
        /// each place is the chat (open twice). Not knowing (no list to count in), only one place is.
        static func pick<P>(_ places: [P], namesakes: () -> Int?) -> P? {
            guard let first = places.first else { return nil }
            switch namesakes() {
            case 0?: return first
            case nil: return places.count == 1 ? first : nil
            default: return nil
            }
        }

        /// The app's windows, without the stand-ins a locked screen gives.
        func windows() -> [AXUIElement] {
            (Self.attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { Self.string($0, kAXRoleAttribute) == "AXWindow" }
        }

        /// The tab in front of `tab`'s group, other than `tab` (its tab bar holds both).
        static func selectedBeside(_ tab: AXUIElement) -> AXUIElement? {
            for bar in ancestors(tab).prefix(3) {
                let tabs = children(bar).filter { string($0, kAXRoleAttribute) == "AXRadioButton" }
                guard tabs.count > 1 else { continue }
                return tabs.first { !CFEqual($0, tab) && selected($0) }
            }
            return nil
        }

        static func selected(_ e: AXUIElement) -> Bool { (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1 }

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
            return untouched() && inFront()
        }

        /// You haven't touched the keyboard or mouse since this began.
        func untouched() -> Bool {
            if idle() + 0.25 < Date().timeIntervalSince(began) { interrupted = true }
            return !interrupted
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
