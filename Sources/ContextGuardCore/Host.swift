import Foundation

/// The coding tool a session runs in. Each one reaches Context Guard its own way: Claude Code
/// through its hooks and the Context Guard mod, Codex through its app server (`context-guard codex`).
/// The rules (`Engine`, `Compactor`) are the same for both; what differs between them is here.
public enum SessionHost: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    /// Its name in the menu, notices and messages.
    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// What judges whether the session is done saving, as notes name it.
    public var judgeName: String {
        switch self {
        case .claude: return "Haiku"
        case .codex: return "the judge model"
        }
    }

    /// When the save message reaches a session that's in the middle of a turn. Claude Code takes it
    /// at its next step; Codex only between turns.
    public var whenBusy: String {
        switch self {
        case .claude: return "at its next step"
        case .codex: return "when this turn ends"
        }
    }
}

extension SessionState {
    /// The tool whose wording applies. A tool this build doesn't know reads as Claude Code; nothing
    /// acts on its session anyway.
    var wordingHost: SessionHost { hostKind ?? .claude }
}
