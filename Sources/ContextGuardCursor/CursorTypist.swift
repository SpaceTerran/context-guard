import ContextGuardCore
import Foundation

/// Types into a Cursor chat wherever it runs: the app through Accessibility, the CLI through its
/// tmux or herdr pane.
public struct CursorTypist: CursorTyping {
    var app: CursorAppTyping
    var terminal: CursorTerminalTyping

    /// `environment`: the hook's, which has the CLI's terminal (and where its programs are).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        app = CursorAppTyping()
        terminal = CursorTerminalTyping(environment: environment)
    }

    public func reach(_ chat: CursorChatRef) -> TypingReach {
        chat.surface == .cli ? terminal.reach(chat) : app.reach(chat)
    }

    public func compact(_ chat: CursorChatRef, started: @escaping @Sendable () -> Bool,
                        continueText: @escaping @Sendable () -> String?) -> CursorTypingResult {
        chat.surface == .cli ? terminal.compact(chat, started: started) : app.compact(chat, started: started, continueText: continueText)
    }

    public func send(_ chat: CursorChatRef, text: String) -> CursorTypingResult {
        chat.surface == .cli ? terminal.send(chat, text: text) : app.send(chat, text: text)
    }
}
