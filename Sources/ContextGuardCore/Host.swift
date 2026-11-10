import Foundation

/// The coding tool a session runs in. Each one reaches Context Guard its own way: Claude Code
/// through its hooks and the Context Guard mod, Codex through its app server (`context-guard codex`).
/// The rules (`Engine`, `Compactor`) are the same for both.
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
}
