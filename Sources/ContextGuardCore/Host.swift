import Foundation

/// The coding tool a session runs in. Each one reaches Context Guard its own way: Claude Code
/// through its hooks and the Context Guard mod, Codex through its app server (`context-guard codex`),
/// and the Cursor app on the Mac through its hooks (`context-guard cursor`). The rules (`Engine`,
/// `Compactor`) are the same for all of them; what differs between them is here.
public enum SessionHost: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    /// A Cursor chat on the Mac, in the Cursor app or the Cursor CLI (`CursorFacts.surface`).
    case cursor

    /// Its name in the menu, notices and messages.
    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// What judges whether the session is done saving, as notes name it.
    public var judgeName: String {
        switch self {
        case .claude: return "Haiku"
        case .codex: return "the judge model"
        case .cursor: return "Cursor's Auto model"
        }
    }

    /// The command you type to compact a session yourself.
    public var compactCommand: String {
        switch self {
        case .claude, .codex: return "/compact"
        case .cursor: return "/summarize"
        }
    }

    /// When the save message reaches an idle session nothing can reach right now: Claude Code and
    /// Cursor hear it on their next turn; the Codex link sends it once a terminal or the Codex app
    /// has the session open.
    public var whenOutOfReach: String {
        switch self {
        case .claude, .cursor: return "when it next runs"
        case .codex: return "when a terminal or the Codex app has it open"
        }
    }
}

extension SessionState {
    /// The tool whose wording applies. A tool this build doesn't know reads as Claude Code; nothing
    /// acts on its session anyway.
    var wordingHost: SessionHost { hostKind ?? .claude }
}
