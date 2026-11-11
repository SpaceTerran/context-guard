import Foundation

/// What an icon means. Each app draws it its own way: SF Symbols on the Mac, Segoe Fluent Icons on
/// Windows. Icons that only decorate a control (✕, a timer, the gauge) stay with the app.
public enum Symbol: String, Sendable, CaseIterable {
    /// Watched, and below the size it asks at.
    case watching
    /// A question waits for your answer.
    case asking
    /// Waits for something: a size, a terminal, Codex.
    case waiting
    /// The save message is on its way.
    case sending
    /// The session was asked to save.
    case sent
    /// Not asked again until it compacts.
    case skipped
    /// You stopped watching this session.
    case notWatching
    /// The session needs you before it compacts.
    case needsYou
    case compacting
    /// Done, installed, connected.
    case success
    /// Saved, and nothing changed since.
    case saved
    case warning
    case failed
    /// Context Guard is off.
    case off
    /// Saving, then compacting.
    case saving
}

/// What an icon's color says. Status colors only ever mean status; accent is Context Guard itself
/// at work.
public enum Tone: Sendable {
    case accent, success, warning, danger, muted
}

/// An icon and a line of text in one color: whether something is installed, how the Codex link
/// stands, whether a setting is saved.
public struct StatusLine: Equatable, Sendable {
    public var text: String
    public var symbol: Symbol
    public var tone: Tone

    public init(text: String, symbol: Symbol, tone: Tone) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }
}
