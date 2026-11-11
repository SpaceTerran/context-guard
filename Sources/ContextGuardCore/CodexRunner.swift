import Foundation

/// A Codex thread as `context-guard codex` sees it in the app server, for one tick.
public struct CodexThreadLook: Equatable, Sendable {
    public var threadId: String
    /// Its rollout file.
    public var path: String?
    public var cwd: String?
    /// Codex's name for it.
    public var name: String?
    /// `idle`, `active`, `systemError` or `notLoaded`.
    public var status: String
    /// What an active thread waits on (`waitingOnApproval`, `waitingOnUserInput`).
    public var flags: [String]
    /// A thread Codex keeps no rollout for (its own helpers, Context Guard's judge).
    public var ephemeral: Bool
    /// A terminal has the session open. nil when that can't be told.
    public var attached: Bool?
    /// Codex's own compaction point, when set (`model_auto_compact_token_limit`).
    public var autoCompactAt: Int?
    /// Codex compacts after a turn above this share of the window, when set.
    public var postTurnCompactPercent: Int?

    public init(threadId: String, path: String? = nil, cwd: String? = nil, name: String? = nil, status: String,
                flags: [String] = [], ephemeral: Bool = false, attached: Bool? = nil, autoCompactAt: Int? = nil,
                postTurnCompactPercent: Int? = nil) {
        self.threadId = threadId
        self.path = path
        self.cwd = cwd
        self.name = name
        self.status = status
        self.flags = flags
        self.ephemeral = ephemeral
        self.attached = attached
        self.autoCompactAt = autoCompactAt
        self.postTurnCompactPercent = postTurnCompactPercent
    }

    /// Between turns: a prompt starts a new turn, and the session can be compacted.
    public var isIdle: Bool { status == "idle" }
}

/// What the link should do for one thread.
public enum CodexCommand: Equatable, Sendable {
    case none
    /// Send the save message as your prompt. Decided while the thread was idle.
    case deliver(nonce: String, text: String)
    /// Ask the judge `prompt`, then report the reply with `mark`.
    case judge(nonce: String, mark: UInt64, prompt: String)
    /// Compact the thread (`thread/compact/start`).
    case compact(nonce: String)
    /// Send `text` as your prompt.
    case `continue`(nonce: String, text: String)
}

/// The rules for Codex sessions against the state files: the counterpart of `HookRunner` and
/// `ModRunner` together, run by `context-guard codex`. It only reads and writes files; the link does
/// what it returns. Every failure ends in `.none` / no change.
public struct CodexRunner: Sendable {
    public let paths: Paths
    public let clock: @Sendable () -> Date

    /// A thread gone from the app server this long has closed. The app server restarts itself
    /// (updates), and a session open in a terminal is loaded again within seconds.
    public static let closedAfter: TimeInterval = 90

    public init(paths: Paths, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.clock = clock
    }

    public func tick(_ t: CodexThreadLook) -> CodexCommand {
        let id = t.threadId
        guard Paths.isValidSessionID(id), !t.ephemeral, (try? paths.ensureDirectories()) != nil else { return .none }
        let now = clock()
        let snap = SessionState.load(id, paths)
        if let snap, snap.hostKind != .codex { return .none }

        // Gathered before taking the lock: reading the conversation can take a moment.
        let path = t.path ?? snap?.transcriptPath
        var size: UInt64?
        var lastWrite: Date?
        if let path, let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            size = (attrs[.size] as? NSNumber)?.uint64Value
            lastWrite = attrs[.modificationDate] as? Date
        }
        let quietFor = lastWrite.map { now.timeIntervalSince($0) } ?? .infinity
        var conversation: Conversation?
        var promptSinceCompacting = false
        if let snap, let path {
            if t.isIdle, quietFor >= 1, let nonce = Compactor.nonceToJudge(snap, now: now) {
                conversation = CodexConversation.read(path: path, from: snap.confirmedOffset, after: nonce)
            }
            if let f = snap.followUp, f.stage == .continuing, let from = f.compactFrom {
                promptSinceCompacting = (CodexConversation.read(path: path, from: from, after: nil)?.userPrompts ?? 0) > 0
            }
        }

        guard let lock = FileLock.acquire(paths.lockFile(id), timeout: 1) else { return .none }
        defer { lock.release() }
        var s = SessionState.load(id, paths) ?? SessionState(sessionId: id, host: .codex, now: now)
        guard s.hostKind == .codex else { return .none }
        let before = s
        let config = Config.load(paths)

        var c = s.codex ?? CodexFacts()
        let turnEnded = c.status == "active" && t.isIdle
        if c.status != t.status || (c.flags ?? []) != t.flags { c.statusAt = now }
        c.status = t.status
        c.flags = t.flags.isEmpty ? nil : t.flags
        c.attached = t.attached
        if t.status != "notLoaded" {
            // The app server's settings for it; one it doesn't list keeps the last ones seen.
            c.autoCompactAt = t.autoCompactAt
            c.postTurnCompactPercent = t.postTurnCompactPercent
        }
        noteLoaded(&s, &c, loaded: t.status != "notLoaded", now: now)
        if let cwd = t.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let name = t.name, !name.isEmpty { s.title = name }
        if let p = t.path, p != s.transcriptPath {
            s.transcriptPath = p
            s.cursor = nil
            c.terminal = nil
        }
        if c.terminal == nil, let p = s.transcriptPath, let meta = CodexRollout.meta(path: p) {
            c.terminal = meta.isTerminalSession
            c.originator = meta.originator
            if s.cwd == nil { s.cwd = meta.cwd }
        }
        s.codex = c

        if let p = s.transcriptPath {
            observe(&s, rollout: p, config: config, now: now)
        }
        s.guarded = s.codex?.terminal == true && s.codex?.window != nil
        let resolved = config.resolved(for: s)
        let watched = !Mute.isMuted(s, paths)

        // A turn ending after a send counts as a Stop does for Claude Code.
        if turnEnded { Engine.noteStop(&s) }
        if t.isIdle, let sent = s.sentAt {
            let idleFor = min(quietFor, now.timeIntervalSince(s.codex?.statusAt ?? now))
            let turnSince = (s.codex?.turn?.startedAt).map { $0 >= sent.addingTimeInterval(-1) } ?? false
            Engine.deliveryLost(&s, idleFor: idleFor, turnSinceSend: turnSince, now: now)
        }
        Engine.apply(Answer.load(id, paths), to: &s)
        Engine.advance(&s, config: resolved, watched: watched, now: now)
        noteInterruptedCompaction(&s, now: now)

        // Nothing goes to a session that's closing or has no terminal showing it.
        let reachable = t.isIdle && t.attached != false && !s.ended
        var command = CodexCommand.none
        if reachable, s.guarded, s.phase == .queued {
            // Claimed and saved before the link sends it, so it can't go out twice.
            let nonce = Engine.makeNonce()
            if let text = Engine.claimDelivery(&s, via: .turn, config: resolved, nonce: nonce, now: now) {
                command = .deliver(nonce: nonce, text: text)
            }
        }
        if command == .none {
            let look = SessionLook(activity: reachable ? .idle : .busy, quiet: quietFor >= 1, draft: false,
                                   conversation: conversation, promptSinceCompacting: promptSinceCompacting,
                                   transcriptSize: size, lastWrite: lastWrite)
            switch Compactor.tick(&s, config: resolved, watched: watched, look: look, now: now) {
            case .none: break
            case .judge(let nonce, let mark, let prompt): command = .judge(nonce: nonce, mark: mark, prompt: prompt)
            case .compact(let nonce): command = .compact(nonce: nonce)
            case .continue(let nonce, let text): command = .continue(nonce: nonce, text: text)
            }
        }

        if s != before {
            s.updatedAt = now
            // Unrecorded means it could happen twice, so a failed save does nothing.
            guard (try? s.save(paths)) != nil else { return .none }
        }
        return command
    }

    /// The link's report on a judge, compaction or continue message. Returns whether to tick again
    /// right away.
    @discardableResult
    public func report(_ r: ModReport) -> Bool {
        update(r.sessionId) { s, now in Compactor.apply(r, to: &s, now: now) } ?? false
    }

    /// Codex refused the save message outright: it never reached the session.
    public func refused(threadId: String, nonce: String) {
        _ = update(threadId) { s, _ in
            if s.sentNonce == nonce { Engine.unclaim(&s) }
            return true
        }
    }

    /// Codex sessions not known to have ended, for the link to look at even when the app server
    /// doesn't list them (closed while the link was away, or the app server restarted).
    public func openSessions() -> [SessionState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { SessionState.load($0.deletingPathExtension().lastPathComponent, paths) }
            .filter { $0.hostKind == .codex && !$0.ended }
    }

    // MARK: - Steps

    func update<T>(_ id: String, _ change: (inout SessionState, Date) -> T) -> T? {
        guard Paths.isValidSessionID(id), let lock = FileLock.acquire(paths.lockFile(id), timeout: 2) else { return nil }
        defer { lock.release() }
        guard var s = SessionState.load(id, paths), s.hostKind == .codex else { return nil }
        let now = clock()
        let before = s
        let out = change(&s, now)
        if s != before {
            s.updatedAt = now
            guard (try? s.save(paths)) != nil else { return nil }
        }
        return out
    }

    /// Gone from the app server for `closedAfter`: closed. Loaded again (resumed): open.
    func noteLoaded(_ s: inout SessionState, _ c: inout CodexFacts, loaded: Bool, now: Date) {
        c.loaded = loaded
        if loaded {
            c.unloadedAt = nil
            if s.ended {
                s.ended = false
                s.endedAt = nil
                s.endReason = nil
            }
            return
        }
        let since = c.unloadedAt ?? now
        c.unloadedAt = since
        if !s.ended, now.timeIntervalSince(since) >= Self.closedAfter {
            s.ended = true
            s.endedAt = now
            s.endReason = "closed"
        }
    }

    /// Fold in what the rollout added since the last read.
    func observe(_ s: inout SessionState, rollout path: String, config: Config, now: Date) {
        var c = s.codex ?? CodexFacts()
        let r = CodexRollout.read(path: path, cursor: s.cursor, markers: s.sentNonce.map { [$0] } ?? [],
                                  turn: c.turn ?? CodexTurn())
        if let cursor = r.transcript.cursor { s.cursor = cursor }
        if let w = r.window { c.window = w }
        if let m = r.model { c.model = m }
        c.turn = r.turn
        s.codex = c

        if r.transcript.compaction != nil {
            // Each of Codex's compactions shows up once, so this one is new.
            s.awaitingCompactionRecord = false
        } else if s.awaitingCompactionRecord, let after = r.transcript.tokens {
            // The size after the last compaction, written after it.
            s.lastCompaction?.postTokens = after
            if var f = s.followUp, f.compactedAt != nil, f.tokensAfter == nil {
                f.tokensAfter = after
                s.followUp = f
            }
        }
        Engine.observe(&s, r.transcript, config: config.resolved(for: s), now: now)
        if r.sizeAfterCompactionUnknown {
            s.tokens = 0
            s.tokensAt = nil
            s.awaitingCompactionRecord = true
        }
    }

    /// Esc during Context Guard's compaction ends its turn without one: the follow-up stops, so the
    /// ready verdict it holds doesn't compact again.
    func noteInterruptedCompaction(_ s: inout SessionState, now: Date) {
        guard let f = s.followUp, f.stage == .compacting, let turn = s.codex?.turn, turn.aborted, !turn.open,
              let started = turn.startedAt, let since = f.compactStartedAt,
              started >= since.addingTimeInterval(-1) else { return }
        Compactor.apply(ModReport(sessionId: s.sessionId, nonce: f.nonce, kind: .compactInterrupted), to: &s, now: now)
    }
}
