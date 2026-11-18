import Foundation

/// A session as the app and `status` show it: saved state plus what's true right now.
public struct SessionInfo: Identifiable, Equatable, Sendable {
    public var id: String { state.sessionId }
    public var state: SessionState
    /// Its Claude process is still running this conversation; for Codex, the app server or the
    /// Codex app has it loaded and `context-guard codex` is connected to that; for Cursor, the app or CLI that runs the
    /// chat is running and the chat had a turn within the hold after one.
    public var isLive: Bool
    public var registry: RegistryEntry?
    /// A background Stop hook is waiting, so "Yes" reaches the session right away even if it's idle.
    public var waiterAlive: Bool
    /// An answer written for the current cycle that the hook hasn't picked up yet.
    public var pendingAnswer: Answer?
    /// You stopped watching this session's tab ("Watch This Session" off).
    public var muted: Bool = false
    /// The main conversation's latest turn start or end, from the mod.
    public var turn: TurnRecord?

    public var title: String {
        if let t = state.title, !t.isEmpty { return t }
        if let n = state.name ?? registry?.name, !n.isEmpty { return n }
        return folderName ?? String(state.sessionId.prefix(8))
    }

    public var folderName: String? {
        guard let cwd = state.cwd ?? registry?.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    /// Short location line, e.g. "code-a6 · ~/code".
    public var subtitle: String {
        var parts: [String] = []
        if let n = state.name ?? registry?.name, !n.isEmpty, n != title { parts.append(n) }
        if let cwd = state.cwd ?? registry?.cwd, !cwd.isEmpty {
            parts.append(PathRules.abbreviatingHome(cwd))
        }
        return parts.joined(separator: " · ")
    }

    public var host: SessionHost { state.hostKind ?? .claude }

    /// A size as this session's tool counts it: tokens for Claude Code, and for Codex and Cursor the
    /// share of the session's own window first ("62% (160k)"), as they show context in percent.
    /// Rounds down, like `Format.tokens`.
    public func size(_ tokens: Int) -> String {
        guard let window = state.window else { return Format.tokens(tokens) }
        return "\(tokens * 100 / window)% (\(Format.tokens(tokens)))"
    }

    /// The same, short enough for a button: "80%" for Codex and Cursor, "500k" for Claude Code.
    public func shortSize(_ tokens: Int) -> String {
        guard let window = state.window else { return Format.tokens(tokens) }
        return "\(tokens * 100 / window)%"
    }

    /// "Yes" reaches the session right away, even while it sits idle: a background Stop hook is
    /// waiting (Claude Code, and Cursor's `stop` hook), or the link can send it a prompt now (Codex).
    public var reachableNow: Bool {
        guard host == .codex else { return waiterAlive }
        return isLive && state.codex?.status == "idle" && state.codex?.attached != false
    }

    /// Where its Claude process stands now. The app can't count background agents (only the mod
    /// can), so `background` work here says 0 agents. A Codex session is between turns when the
    /// app server says it's idle, and a Cursor chat when its last turn ended (its hooks' turn record).
    public var activity: SessionActivity {
        switch host {
        case .codex: return state.codex?.status == "idle" ? .idle : .busy
        case .cursor: return turn?.active == true ? .busy : .idle
        case .claude: return SessionActivity.of(registry, turn: turn, processStart: state.claudeStart, now: Date())
        }
    }

    /// Not in the middle of a turn: a wake starts a new one.
    public var isIdle: Bool { activity.isBetweenTurns }

    /// The phase including an answer the hook hasn't applied yet.
    public var effectivePhase: Phase {
        guard let a = pendingAnswer else { return state.phase }
        switch a.action {
        case .yes:
            // A follow-up already under way isn't asked to save again (`Engine.apply`).
            if let f = state.followUp, f.isActive, state.phase == .sent, state.sentNonce == f.nonce { return state.phase }
            return .queued
        case .later: return state.phase == .asking ? .later : state.phase
        case .skip: return state.phase == .asking || state.phase == .later ? .skipped : state.phase
        }
    }
}

public enum SessionCatalog {
    public static func load(_ paths: Paths, registry: any RegistryReading, probe: any ProcessProbing = SystemProcessProbe()) -> [SessionInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        let byPid = Dictionary(registry.all().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let registryAvailable = registry.isAvailable
        let link = CodexLinkStatus.load(paths)
        let now = Date()
        var out: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let s = SessionState.load(id, paths) else { continue }
            var entry: RegistryEntry?
            var live = false
            let waiter = s.waiterToken != nil && (s.waiterPid.map { probe.isRunning($0, startedAt: s.waiterStart) } ?? false)
            switch s.hostKind {
            case .codex:
                // The link's connection to where it's open: the app server, or the Codex app.
                live = (link?.isUp(for: s.codex?.surface, now: now) ?? false) && !s.ended && s.codex?.loaded == true
            case .cursor:
                // The app keeps every chat, so a chat counts while its `stop` hook waits after a turn
                // (or could still be: the hold's length) and Cursor runs.
                if !s.ended, let pid = s.cursorChat?.pid, probe.isRunning(pid, startedAt: s.cursorChat?.start) {
                    live = waiter || Date().timeIntervalSince(s.updatedAt) < CursorRunner.holdFor
                }
            case .claude:
                if let pid = s.claudePid, !s.ended, probe.isRunning(pid, startedAt: s.claudeStart) {
                    entry = byPid[pid]
                    if let entry { live = entry.sessionId == s.sessionId } else { live = !registryAvailable }
                }
            case nil:
                break
            }
            var pending: Answer?
            if let a = Answer.load(id, paths), a.id != s.appliedAnswerId, a.cycle == s.cycle { pending = a }
            out.append(SessionInfo(state: s, isLive: live, registry: entry, waiterAlive: waiter, pendingAnswer: pending,
                                   muted: Mute.isMuted(s, paths), turn: TurnRecord.load(id, paths)))
        }
        return out.sorted { ($0.state.tokens, $0.id) > ($1.state.tokens, $1.id) }
    }

    /// Remove files for sessions that ended or stopped running a while ago, and the "not watching"
    /// marks of tabs that closed.
    public static func prune(_ paths: Paths, sessions: [SessionInfo], olderThan age: TimeInterval, now: Date = Date(),
                             probe: any ProcessProbing = SystemProcessProbe()) {
        Mute.prune(paths, probe: probe)
        let fm = FileManager.default
        for info in sessions where !info.isLive && now.timeIntervalSince(info.state.updatedAt) > age {
            try? fm.removeItem(at: paths.stateFile(info.id))
            try? fm.removeItem(at: paths.lockFile(info.id))
            try? fm.removeItem(at: paths.answerFile(info.id))
            try? fm.removeItem(at: paths.turnFile(info.id))
        }
    }
}

public enum Format {
    /// 1 → "1 second", 60 → "60 seconds".
    public static func seconds(_ n: Int) -> String { n == 1 ? "1 second" : "\(n) seconds" }

    /// 302_517 → "302k". Rounds down, so a session never reads "300k" before it reaches 300k.
    public static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let tenths = n / 100_000
            return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
        }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
