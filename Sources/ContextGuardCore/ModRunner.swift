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
        var look = SessionLook(agents: facts.agents ?? 0, draft: facts.draft ?? false)
        if let pid = snap.claudePid, probe.isRunning(pid, startedAt: snap.claudeStart) {
            let entry = registry.entry(pid: pid)
            if let entry {
                look.idle = entry.sessionId == id && RegistryEntry.isIdle(entry)
            } else {
                look.idle = !registry.isAvailable
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
        let action = Compactor.tick(&s, config: Config.load(paths), watched: !Mute.isMuted(s, paths), look: look, now: now)
        if s != before {
            s.updatedAt = now
            // Unrecorded means it could happen twice, so a failed save does nothing.
            guard (try? s.save(paths)) != nil else { return .none }
        }
        return action
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
