import Foundation

/// What Context Guard knows about a Codex session, from its rollout file and the Codex app server.
/// Claude Code sessions don't have it.
public struct CodexFacts: Codable, Equatable, Sendable {
    /// The context window as the session reports it (`model_context_window`: the model's window
    /// less the part Codex keeps in reserve).
    public var window: Int?
    /// Where Codex compacts by itself, when known (`model_auto_compact_token_limit`).
    public var autoCompactAt: Int?
    /// Codex also compacts after a turn that ends above this share of the window, when set
    /// (`model_post_turn_compact_threshold_percent`).
    public var postTurnCompactPercent: Int?
    /// The model the session last ran.
    public var model: String?
    /// Which Codex client started it: `codex-tui` for a terminal session.
    public var originator: String?
    /// A session you drive in a terminal, in a format Context Guard reads (`CodexMeta`). nil until
    /// its rollout's first line has been read.
    public var terminal: Bool?
    /// The `CodexMeta.terminalRule` that made `terminal`: one made by an older rule is made again.
    public var terminalRule: Int?
    /// Its turns as the rollout showed them, carried from one read to the next.
    public var turn: CodexTurn?

    /// The thread's status in the app server: `idle`, `active`, `systemError` or `notLoaded`.
    public var status: String?
    /// What an active thread waits on (`waitingOnApproval`, `waitingOnUserInput`).
    public var flags: [String]?
    public var statusAt: Date?
    /// Whether the app server has the thread loaded: a terminal has it open, or had it open
    /// less than a minute ago.
    public var loaded: Bool?
    /// When the link last saw it unloaded, to tell a closed session from a restarting app server.
    public var unloadedAt: Date?
    /// A terminal has it open, as far as the link can tell.
    public var attached: Bool?
    /// The running turn (by when it started) that wouldn't take the save message: it goes in
    /// once that turn ends instead.
    public var steerRefused: Date?

    public init(window: Int? = nil, autoCompactAt: Int? = nil, postTurnCompactPercent: Int? = nil,
                model: String? = nil, originator: String? = nil,
                status: String? = nil, flags: [String]? = nil, statusAt: Date? = nil,
                loaded: Bool? = nil, unloadedAt: Date? = nil) {
        self.window = window
        self.autoCompactAt = autoCompactAt
        self.postTurnCompactPercent = postTurnCompactPercent
        self.model = model
        self.originator = originator
        self.status = status
        self.flags = flags
        self.statusAt = statusAt
        self.loaded = loaded
        self.unloadedAt = unloadedAt
    }

    // A field that doesn't read is left unknown instead of failing the whole state file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try? c.decode(Int.self, forKey: .window)
        autoCompactAt = try? c.decode(Int.self, forKey: .autoCompactAt)
        postTurnCompactPercent = try? c.decode(Int.self, forKey: .postTurnCompactPercent)
        model = try? c.decode(String.self, forKey: .model)
        originator = try? c.decode(String.self, forKey: .originator)
        terminal = try? c.decode(Bool.self, forKey: .terminal)
        terminalRule = try? c.decode(Int.self, forKey: .terminalRule)
        turn = try? c.decode(CodexTurn.self, forKey: .turn)
        status = try? c.decode(String.self, forKey: .status)
        flags = try? c.decode([String].self, forKey: .flags)
        statusAt = try? c.decode(Date.self, forKey: .statusAt)
        loaded = try? c.decode(Bool.self, forKey: .loaded)
        unloadedAt = try? c.decode(Date.self, forKey: .unloadedAt)
        attached = try? c.decode(Bool.self, forKey: .attached)
        steerRefused = try? c.decode(Date.self, forKey: .steerRefused)
    }

    /// The lowest point where Codex compacts by itself, as far as is known. By default it compacts
    /// at 90% of the model's window, and the reported window is 95% of that; its own limit and its
    /// after-a-turn share, when set, can come earlier.
    public var compactsItselfAt: Int? {
        var points: [Int] = []
        if let window, window > 0 {
            points.append(window * 90 / 95)
            if let pct = postTurnCompactPercent, (1...100).contains(pct) { points.append(window * pct / 100) }
        }
        if let autoCompactAt, autoCompactAt > 0 { points.append(autoCompactAt) }
        return points.min()
    }
}
