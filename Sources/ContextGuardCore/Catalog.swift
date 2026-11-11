import Foundation

/// A session as the app and `status` show it: saved state plus what's true right now.
public struct SessionInfo: Identifiable, Equatable, Sendable {
    public var id: String { state.sessionId }
    public var state: SessionState
    /// Its Claude process is still running this conversation; for Codex, the app server has it
    /// loaded and `context-guard codex` is connected to it.
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
            parts.append((cwd as NSString).abbreviatingWithTildeInPath)
        }
        return parts.joined(separator: " · ")
    }

    public var host: SessionHost { state.hostKind ?? .claude }

    /// "Yes" reaches the session right away, even while it sits idle: a background Stop hook is
    /// waiting (Claude Code), or the link can send it a prompt now (Codex).
    public var reachableNow: Bool {
        guard host == .codex else { return waiterAlive }
        return isLive && state.codex?.status == "idle" && state.codex?.attached != false
    }

    /// Where its Claude process stands now. The app can't count background agents (only the mod
    /// can), so `background` work here says 0 agents. A Codex session is between turns when the
    /// app server says it's idle.
    public var activity: SessionActivity {
        if host == .codex { return state.codex?.status == "idle" ? .idle : .busy }
        return SessionActivity.of(registry, turn: turn, processStart: state.claudeStart, now: Date())
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
        let linkUp = CodexLinkStatus.load(paths)?.isUp(now: Date()) ?? false
        var out: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let s = SessionState.load(id, paths) else { continue }
            var entry: RegistryEntry?
            var live = false
            if s.hostKind == .codex {
                live = linkUp && !s.ended && s.codex?.loaded == true
            } else if let pid = s.claudePid, !s.ended, probe.isRunning(pid, startedAt: s.claudeStart) {
                entry = byPid[pid]
                if let entry { live = entry.sessionId == s.sessionId } else { live = !registryAvailable }
            }
            let waiter = s.waiterToken != nil && (s.waiterPid.map { probe.isRunning($0, startedAt: s.waiterStart) } ?? false)
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
