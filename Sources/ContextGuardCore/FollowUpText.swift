import Foundation

/// How the app tells you where a session stands after its save message: a line in the session's menu,
/// and the notice a stage raises when the follow-up reaches it.
public enum FollowUpText {
    /// A finished follow-up stays in the menu this long.
    public static let shownAfterEnd: TimeInterval = 30 * 60

    /// What a notice's icon color says. Status colors only ever mean status; accent is Context
    /// Guard itself at work.
    public enum Tone: Sendable {
        case accent, success, warning, danger, muted
    }

    public struct Notice: Equatable, Sendable {
        public var symbol: String
        public var tone: Tone
        public var title: String
        /// A second line: Haiku's reason or what went wrong.
        public var reason: String?
        /// How long it stays up.
        public var seconds: TimeInterval
    }

    /// The menu line, or nil once a finished follow-up is old news.
    public static func line(_ f: FollowUp, continueMessage: String, now: Date) -> String? {
        if !f.isActive, now.timeIntervalSince(f.stageAt) > shownAfterEnd { return nil }
        let message = quoted(continueMessage)
        switch f.stage {
        case .checking: return "Compacts once it's done saving"
        case .working: return "Still saving" + reason(f)
        case .needsYou: return "Needs you before compacting" + reason(f)
        case .draft: return "Compacts once the prompt box is empty"
        case .compacting: return "Compacting…"
        case .continuing: return "Compacted\(sizes(f)) · sends \(message) when it's idle"
        case .done: return "Compacted\(sizes(f)) and sent \(message)"
        case .tookOver: return "Compacted\(sizes(f)) · you took over, so \(message) wasn't sent"
        case .stopped: return "Didn't compact" + reason(f)
        case .failed where f.compactedAt != nil: return "Compacted\(sizes(f)) · couldn't send \(message)" + reason(f)
        case .failed: return "Couldn't compact by itself" + reason(f)
        }
    }

    /// The notice for the stage the follow-up is in now, if that stage raises one.
    public static func notice(_ f: FollowUp, continueMessage: String) -> Notice? {
        let message = quoted(continueMessage)
        switch f.stage {
        case .needsYou:
            // It waits on you, so it stays up longer.
            return Notice(symbol: "questionmark.bubble.fill", tone: .warning, title: "Needs you before compacting", reason: sentence(f.note), seconds: 20)
        case .compacting:
            return Notice(symbol: "arrow.down.right.and.arrow.up.left.circle.fill", tone: .accent, title: "Compacting", reason: nil, seconds: 8)
        case .done:
            return Notice(symbol: "checkmark.circle.fill", tone: .success, title: "Compacted\(sizes(f))", reason: "Then sent \(message)", seconds: 8)
        case .tookOver:
            return Notice(symbol: "checkmark.circle.fill", tone: .success, title: "Compacted\(sizes(f))", reason: "You took over, so \(message) wasn't sent", seconds: 8)
        case .failed where f.compactedAt != nil:
            return Notice(symbol: "exclamationmark.triangle.fill", tone: .warning, title: "Compacted\(sizes(f))", reason: "Couldn't send \(message)" + reason(f), seconds: 20)
        case .failed:
            return Notice(symbol: "xmark.octagon.fill", tone: .danger, title: "Couldn't compact by itself", reason: sentence(f.note), seconds: 20)
        case .checking, .working, .draft, .continuing, .stopped:
            return nil
        }
    }

    /// " 312k → 24k", or nothing when the sizes aren't known.
    static func sizes(_ f: FollowUp) -> String {
        guard let before = f.tokensBefore, let after = f.tokensAfter else { return "" }
        return " \(Format.tokens(before)) → \(Format.tokens(after))"
    }

    static func reason(_ f: FollowUp) -> String {
        trimmed(f.note).map { ": \($0)" } ?? ""
    }

    /// The note without a closing period, or nil when there isn't one.
    static func trimmed(_ note: String?) -> String? {
        guard var n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        if n.hasSuffix("."), !n.hasSuffix("..") { n.removeLast() }
        return n
    }

    /// The note as a line of its own: trimmed, with a capital first letter.
    static func sentence(_ note: String?) -> String? {
        trimmed(note).map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// A message in quotes, cut to its first line and `max` characters: menus don't truncate, so
    /// one long message would widen the whole menu.
    public static func quoted(_ s: String, max: Int = 24) -> String {
        let whole = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = whole.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if shown.count > max {
            let cut = shown.prefix(max - 1)
            // Back up to a whole word, unless that leaves too little.
            let midWord = !shown.dropFirst(cut.count).hasPrefix(" ")
            if midWord, let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= max / 2 {
                shown = String(cut[..<space])
            } else {
                shown = String(cut)
            }
        }
        guard shown != whole else { return "\u{201C}\(shown)\u{201D}" }
        // "NOTES.md…", not "NOTES.md.…".
        while let last = shown.last, last.isWhitespace || ".,;:".contains(last) { shown.removeLast() }
        return "\u{201C}\(shown)…\u{201D}"
    }
}
