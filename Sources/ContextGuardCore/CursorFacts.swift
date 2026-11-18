import Foundation

/// Where a Cursor chat runs.
public enum CursorSurface: String, Codable, Sendable {
    /// The Cursor app's Agents window or an editor window.
    case app
    /// `cursor-agent` in a terminal.
    case cli
}

/// The terminal pane a Cursor CLI chat runs in, when it's one Context Guard can type into through the
/// pane's own program (as it reaches Codex through Codex's app server): never by keystrokes.
public struct CursorTerminal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tmux, herdr
    }

    public var kind: Kind
    /// tmux's `TMUX_PANE` ("%3"), or herdr's `HERDR_PANE_ID` ("w1:p2").
    public var pane: String
    /// The server's socket: tmux's is the first part of `TMUX`, herdr's is `HERDR_SOCKET_PATH`.
    public var socket: String?

    public init(kind: Kind, pane: String, socket: String? = nil) {
        self.kind = kind
        self.pane = pane
        self.socket = socket
    }
}

/// What Context Guard knows about a Cursor chat, in the app or the CLI, from Cursor's hooks and
/// Cursor's own stores of chats. Claude Code and Codex sessions don't have it.
public struct CursorFacts: Codable, Equatable, Sendable {
    /// The app or the CLI. nil in a file that doesn't say: the app.
    public var surface: CursorSurface?
    /// The chat's context window, as Cursor counts it (`promptTokenBreakdown.maxTokens`).
    public var window: Int?
    /// The model the chat last ran.
    public var model: String?
    /// The process that runs the chat (the Cursor app, or `cursor-agent`), and when it started: the
    /// chat is open while it runs.
    public var pid: Int32?
    public var start: ProcessStart?
    /// The CLI's terminal pane, when Context Guard can type into it.
    public var terminal: CursorTerminal?
    /// Cursor's turn (`generation_id`) that the save message went into mid-turn: it counts as
    /// arrived once that turn goes on.
    public var stepTurn: String?
    /// The last turn ended early (you stopped it, or it failed): nothing goes in between turns until
    /// your next one, so stopping a turn never starts another.
    public var turnCutShort: Bool?
    /// Where Cursor last summarized the chat by itself, as a share of its window.
    public var autoCompactPercent: Int?
    /// When Context Guard last found text in the chat's prompt box when it came to compact it.
    /// Nothing is typed over it: it tries again a while later.
    public var draftAt: Date?
    /// Why typing into the chat last failed, and when.
    public var typingProblem: String?
    public var typingProblemAt: Date?
    /// Typing said "not now" (you came back, or the chat left the screen): it isn't tried again
    /// before this.
    public var typingWaitUntil: Date?
    /// In the app: whether Cursor held the Accessibility permission Context Guard types with, at its
    /// last hook call (Settings shows it).
    public var canType: Bool?
    /// The chat's size as Cursor last gave it, and about how many characters its steps have added
    /// since: the app has a chat's size only as of its last turn's end (`CursorRunner.estimate`).
    public var sizeSeen: Int?
    public var charsSince: Int?

    public init(surface: CursorSurface? = nil, window: Int? = nil, model: String? = nil, pid: Int32? = nil,
                start: ProcessStart? = nil, terminal: CursorTerminal? = nil) {
        self.surface = surface
        self.window = window
        self.model = model
        self.pid = pid
        self.start = start
        self.terminal = terminal
    }

    /// The app or the CLI, as known.
    public var runsIn: CursorSurface { surface ?? .app }

    // A field that doesn't read is left unknown instead of failing the whole state file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try? c.decode(CursorSurface.self, forKey: .surface)
        window = try? c.decode(Int.self, forKey: .window)
        model = try? c.decode(String.self, forKey: .model)
        pid = try? c.decode(Int32.self, forKey: .pid)
        start = try? c.decode(ProcessStart.self, forKey: .start)
        terminal = try? c.decode(CursorTerminal.self, forKey: .terminal)
        stepTurn = try? c.decode(String.self, forKey: .stepTurn)
        turnCutShort = try? c.decode(Bool.self, forKey: .turnCutShort)
        autoCompactPercent = try? c.decode(Int.self, forKey: .autoCompactPercent)
        draftAt = try? c.decode(Date.self, forKey: .draftAt)
        typingProblem = try? c.decode(String.self, forKey: .typingProblem)
        typingProblemAt = try? c.decode(Date.self, forKey: .typingProblemAt)
        typingWaitUntil = try? c.decode(Date.self, forKey: .typingWaitUntil)
        canType = try? c.decode(Bool.self, forKey: .canType)
        sizeSeen = try? c.decode(Int.self, forKey: .sizeSeen)
        charsSince = try? c.decode(Int.self, forKey: .charsSince)
    }

    /// Where Cursor summarizes the chat by itself, as far as is known: the share of the window where
    /// it last did. Cursor sets this on its servers and doesn't say it beforehand.
    public var compactsItselfAt: Int? {
        guard let window, window > 0, let pct = autoCompactPercent, (1...100).contains(pct) else { return nil }
        return window * pct / 100
    }
}
