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

    /// When the save message reaches an idle session nothing can reach right now: Claude Code
    /// hears it on its next turn; the Codex link sends it once a terminal shows the session.
    public var whenOutOfReach: String {
        switch self {
        case .claude: return "when it next runs"
        case .codex: return "when a terminal shows it"
        }
    }
}

extension SessionState {
    /// The tool whose wording applies. A tool this build doesn't know reads as Claude Code; nothing
    /// acts on its session anyway.
    var wordingHost: SessionHost { hostKind ?? .claude }
}
