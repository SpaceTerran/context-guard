import Foundation

/// What the mod knows that Context Guard can't see from outside the session.
public struct ModFacts: Codable, Equatable, Sendable {
    public var sessionId: String
    /// Subagents still running (`$.agent.list()`).
    public var agents: Int?
    /// Text in the prompt box (`$.prompt.read()`).
    public var draft: Bool?

    public init(sessionId: String, agents: Int? = nil, draft: Bool? = nil) {
        self.sessionId = sessionId
        self.agents = agents
        self.draft = draft
    }
}

/// A main-conversation turn starting or ending, as the mod hears it (`turn.start`, `turn.complete`).
public struct ModTurn: Codable, Equatable, Sendable {
    public var sessionId: String
    public var active: Bool

    public init(sessionId: String, active: Bool) {
        self.sessionId = sessionId
        self.active = active
    }
}

/// Runs the mod's `tick` and `report` against the state files, under the same lock as the hooks.
/// Every failure ends in `.none` / no change.
public struct ModRunner: Sendable {
    public let paths: Paths
    public let probe: any ProcessProbing
    public let registry: any RegistryReading
    public let clock: @Sendable () -> Date

    public init(paths: Paths, probe: any ProcessProbing = SystemProcessProbe(),
                registry: (any RegistryReading)? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.probe = probe
        self.registry = registry ?? FileRegistry(dir: paths.registryDir)
        self.clock = clock
    }

    public func tick(_ facts: ModFacts) -> ModAction {
        let id = facts.sessionId
        guard Paths.isValidSessionID(id), let snap = SessionState.load(id, paths), snap.guarded, !snap.ended else { return .none }
        let now = clock()
        // The common case, every ten seconds in every session: nothing to follow.
        guard Compactor.startableNonce(snap, now: now) != nil || (snap.followUp?.isActive ?? false) else { return .none }

        // Gathered before taking the lock: reading the conversation can take a moment.
        var look = SessionLook(draft: facts.draft ?? false)
        if let pid = snap.claudePid, probe.isRunning(pid, startedAt: snap.claudeStart) {
            if let entry = registry.entry(pid: pid) {
                // After /clear or /resume this process runs a different conversation.
                if entry.sessionId == id {
                    look.activity = SessionActivity.of(entry, turn: TurnRecord.load(id, paths), processStart: snap.claudeStart,
                                                       agents: facts.agents ?? 0, now: now)
                }
            } else if !registry.isAvailable {
                look.activity = .idle
            }
        }
        if let path = snap.transcriptPath, let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            look.transcriptSize = (attrs[.size] as? NSNumber)?.uint64Value
            look.lastWrite = attrs[.modificationDate] as? Date
            look.quiet = look.lastWrite.map { now.timeIntervalSince($0) >= 1 } ?? false
            if look.idle, look.quiet, let nonce = Compactor.nonceToJudge(snap, now: now) {
                look.conversation = ConversationReader.read(path: path, from: snap.confirmedOffset, after: nonce)
            }
            if let f = snap.followUp, f.stage == .continuing, let from = f.compactFrom {
                look.promptSinceCompacting = (ConversationReader.read(path: path, from: from, after: nil)?.userPrompts ?? 0) > 0
            }
        }

        guard let lock = FileLock.acquire(paths.lockFile(id), timeout: 1) else { return .none }
        defer { lock.release() }
        guard var s = SessionState.load(id, paths) else { return .none }
        let before = s
        // Compact Now on a follow-up already under way is applied here too, so it doesn't wait for
        // the session's next hook event when no background Stop hook is waiting.
        Engine.apply(Answer.load(id, paths), to: &s)
        let action = Compactor.tick(&s, config: Config.load(paths), watched: !Mute.isMuted(s, paths), look: look, now: now)
        if s != before {
            s.updatedAt = now
            // Unrecorded means it could happen twice, so a failed save does nothing.
            guard (try? s.save(paths)) != nil else { return .none }
        }
        return action
    }

    /// Records a main-conversation turn starting or ending. The mod awaits this at a turn's start,
    /// so the record is in before the turn runs. It takes no lock (`TurnRecord`).
    public func turn(_ t: ModTurn) {
        guard Paths.isValidSessionID(t.sessionId), let s = SessionState.load(t.sessionId, paths), s.guarded else { return }
        try? TurnRecord(active: t.active, at: clock()).save(for: t.sessionId, paths)
    }

    /// Returns whether the mod should tick again right away.
    public func report(_ r: ModReport) -> Bool {
        guard Paths.isValidSessionID(r.sessionId), let lock = FileLock.acquire(paths.lockFile(r.sessionId), timeout: 2) else { return false }
        defer { lock.release() }
        guard var s = SessionState.load(r.sessionId, paths) else { return false }
        let now = clock()
        let before = s
        let again = Compactor.apply(r, to: &s, now: now)
        if s != before {
            s.updatedAt = now
            guard (try? s.save(paths)) != nil else { return false }
        }
        return again
    }
}

extension ModAction {
    /// The JSON the mod reads.
    public var json: [String: Any] {
        switch self {
        case .none:
            return ["action": "none"]
        case .judge(let nonce, let mark, let prompt):
            return ["action": "judge", "nonce": nonce, "mark": mark, "prompt": prompt, "model": Compactor.judgeModel,
                    "maxTokens": Compactor.judgeMaxTokens, "timeoutMs": Compactor.judgeTimeoutMs]
        case .compact(let nonce):
            return ["action": "compact", "nonce": nonce]
        case .continue(let nonce, let text):
            return ["action": "continue", "nonce": nonce, "text": text]
        }
    }
}
