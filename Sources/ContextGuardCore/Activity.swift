import Foundation

/// The main conversation's latest turn start or end, as the Context Guard mod saw it
/// (`context-guard mod turn`). A file of its own, written without the session's lock: a hook
/// holding that lock while it reads a long transcript must never cost a turn's start.
public struct TurnRecord: Codable, Equatable, Sendable {
    /// A turn started and hasn't ended.
    public var active: Bool
    public var at: Date

    public init(active: Bool, at: Date) {
        self.active = active
        self.at = at
    }

    public static func load(_ id: String, _ paths: Paths) -> TurnRecord? {
        FileIO.readJSON(TurnRecord.self, from: paths.turnFile(id))
    }

    public func save(for sessionId: String, _ paths: Paths) throws {
        try paths.ensureDirectories()
        try FileIO.writeJSON(self, to: paths.turnFile(sessionId))
    }
}

/// Work a session left running in the background between turns.
public struct BackgroundWork: Codable, Equatable, Sendable {
    /// Background agents still running, as the mod counted them. 0 when only Claude Code's
    /// registry says something is (a kind of task the mod can't list).
    public var agents: Int
    /// A shell command started in the background is still running.
    public var shells: Bool

    public init(agents: Int = 0, shells: Bool = false) {
        self.agents = agents
        self.shells = shells
    }
}

/// Where a session's Claude process stands now.
public enum SessionActivity: Equatable, Sendable {
    /// Between turns, with nothing running.
    case idle
    /// Between turns, with an agent or a shell command still running in the background. A wake
    /// still starts a new turn here, and compacting still works.
    case background(BackgroundWork)
    /// A turn is running, a dialog waits on you, or it can't be told.
    case busy

    /// A wake starts a new turn rather than landing inside one, and the session can be compacted.
    public var isBetweenTurns: Bool { self != .busy }

    public var background: BackgroundWork? {
        if case .background(let work) = self { return work }
        return nil
    }

    /// A turn record this recent doesn't yet tell a turn apart from background work: Claude Code
    /// writes its registry a moment after a turn ends.
    static let settle: TimeInterval = 2

    /// Reads Claude Code's registry status with the mod's turn record. The status alone is
    /// ambiguous: Claude Code writes `busy` both while a turn runs and while background agents run
    /// between turns, `shell` between turns while a background shell command runs, `waiting` for a
    /// permission prompt or dialog, and `idle` when none of these. A Claude Code that writes no
    /// status counts as idle.
    ///
    /// `busy` counts as between turns only on a turn record from this Claude process that says the
    /// last turn ended. Without one (a mod from before turn records, or none) it stays busy, so a
    /// wake never lands inside a turn.
    public static func of(_ entry: RegistryEntry?, turn: TurnRecord?, processStart: ProcessStart?, agents: Int = 0, now: Date) -> SessionActivity {
        guard let status = entry?.status else { return .idle }
        switch status {
        case "idle":
            return .idle
        case "shell":
            return .background(BackgroundWork(agents: agents, shells: true))
        case "busy":
            guard let turn, !turn.active, now.timeIntervalSince(turn.at) >= settle else { return .busy }
            // A record from before this process started belongs to an earlier run of the session.
            // The state file keeps whole seconds, so the start is compared to the second.
            if let processStart, turn.at < Date(timeIntervalSince1970: TimeInterval(processStart.seconds)) { return .busy }
            return .background(BackgroundWork(agents: agents, shells: false))
        default:
            return .busy
        }
    }
}
