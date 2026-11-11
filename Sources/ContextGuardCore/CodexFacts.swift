import Foundation

/// What Context Guard knows about a Codex session, from its rollout file and the Codex app server.
/// Claude Code sessions don't have it.
public struct CodexFacts: Codable, Equatable, Sendable {
    /// The context window as the session reports it (`model_context_window`: the model's window
    /// less the part Codex keeps in reserve).
    public var window: Int?
    /// Where Codex compacts by itself, when known (`model_auto_compact_token_limit`).
    public var autoCompactAt: Int?
    /// The model the session last ran.
    public var model: String?
    /// Which Codex client started it: `codex-tui` for a terminal session.
    public var originator: String?

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

    /// Our item in the thread's queue, while the save or continue message waits there.
    public var queueItemId: String?

    public init(window: Int? = nil, autoCompactAt: Int? = nil, model: String? = nil, originator: String? = nil,
                status: String? = nil, flags: [String]? = nil, statusAt: Date? = nil,
                loaded: Bool? = nil, unloadedAt: Date? = nil, queueItemId: String? = nil) {
        self.window = window
        self.autoCompactAt = autoCompactAt
        self.model = model
        self.originator = originator
        self.status = status
        self.flags = flags
        self.statusAt = statusAt
        self.loaded = loaded
        self.unloadedAt = unloadedAt
        self.queueItemId = queueItemId
    }

    // A field that doesn't read is left unknown instead of failing the whole state file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try? c.decode(Int.self, forKey: .window)
        autoCompactAt = try? c.decode(Int.self, forKey: .autoCompactAt)
        model = try? c.decode(String.self, forKey: .model)
        originator = try? c.decode(String.self, forKey: .originator)
        status = try? c.decode(String.self, forKey: .status)
        flags = try? c.decode([String].self, forKey: .flags)
        statusAt = try? c.decode(Date.self, forKey: .statusAt)
        loaded = try? c.decode(Bool.self, forKey: .loaded)
        unloadedAt = try? c.decode(Date.self, forKey: .unloadedAt)
        queueItemId = try? c.decode(String.self, forKey: .queueItemId)
    }

    /// Where Codex compacts by itself: its own limit when known, else its default. By default it
    /// compacts at 90% of the model's window, and the reported window is 95% of that.
    public var compactsItselfAt: Int? {
        if let autoCompactAt, autoCompactAt > 0 { return autoCompactAt }
        return window.map { $0 * 90 / 95 }
    }
}
