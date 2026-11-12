import Foundation

public enum HookEvent: String, Sendable {
    case postToolBatch = "PostToolBatch"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
}

/// The fields Context Guard uses from Claude Code's hook input.
public struct HookInput: Equatable, Sendable {
    public var event: String
    public var sessionId: String
    public var transcriptPath: String?
    public var cwd: String?
    /// Present only when the hook fires inside a subagent.
    public var agentId: String?
    /// SessionStart: startup, resume, clear, compact, fork.
    public var source: String?
    /// SessionStart on resume/fork: the resumed context size.
    public var contextTokens: Int?
    /// SessionEnd: why it ended.
    public var reason: String?

    public init(event: String, sessionId: String, transcriptPath: String? = nil, cwd: String? = nil, agentId: String? = nil, source: String? = nil, contextTokens: Int? = nil, reason: String? = nil) {
        self.event = event
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.agentId = agentId
        self.source = source
        self.contextTokens = contextTokens
        self.reason = reason
    }

    public static func parse(_ data: Data) -> HookInput? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = obj["hook_event_name"] as? String,
              let sid = obj["session_id"] as? String else { return nil }
        let agent = obj["agent_id"] as? String
        return HookInput(
            event: event, sessionId: sid,
            transcriptPath: obj["transcript_path"] as? String,
            cwd: obj["cwd"] as? String,
            agentId: (agent?.isEmpty ?? true) ? nil : agent,
            source: obj["source"] as? String,
            contextTokens: TranscriptReader.int(obj["context_tokens"]),
            reason: obj["reason"] as? String)
    }
}

public enum HookOutcome: Equatable, Sendable {
    /// Print nothing, exit 0.
    case silent
    /// Print `hookSpecificOutput.additionalContext` JSON, exit 0.
    case addContext(event: String, text: String)
    /// Print the text to stderr, exit 2: the async Stop hook wakes the session with it.
    case wake(text: String)
    /// Stay in the background and wait for your answer (`runWaiter`).
    case wait(token: String)
}

/// Runs one hook event against the state files. Every failure ends in `.silent`.
public struct HookRunner: Sendable {
    public let paths: Paths
    /// The Claude Code process that ran the hook (see `claudePid(_:)`).
    public let claudePid: Int32?

    /// Which Claude Code process ran the hook: the one the hook command names (`CG_CLAUDE_PID=$PPID`
    /// in the Mac's shell line, always the process that ran it), else the one Claude Code names
    /// (`CLAUDE_PID`, since 2.1.214; the Windows hook runs the program with no shell).
    public static func claudePid(_ env: [String: String]) -> Int32? {
        env["CG_CLAUDE_PID"].flatMap { Int32($0) } ?? env["CLAUDE_PID"].flatMap { Int32($0) }
    }
    public let environment: [String: String]
    public let probe: any ProcessProbing
    public let registry: any RegistryReading
    public let clock: @Sendable () -> Date
    /// How long the hot path waits for the session lock before giving up (the next event catches up).
    public var lockTimeout: TimeInterval = 0.3

    public init(paths: Paths, claudePid: Int32?, environment: [String: String],
                probe: any ProcessProbing = SystemProcessProbe(),
                registry: (any RegistryReading)? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.claudePid = claudePid
        self.environment = environment
        self.probe = probe
        self.registry = registry ?? FileRegistry(dir: paths.registryDir)
        self.clock = clock
    }

    public func handle(_ input: HookInput) -> HookOutcome {
        guard input.agentId == nil, Paths.isValidSessionID(input.sessionId),
              let event = HookEvent(rawValue: input.event) else { return .silent }
        guard (try? paths.ensureDirectories()) != nil else { return .silent }
        let config = Config.load(paths)
        guard let lock = FileLock.acquire(paths.lockFile(input.sessionId), timeout: event == .stop ? 2 : lockTimeout) else { return .silent }
        defer { lock.release() }

        let now = clock()
        var s = SessionState.load(input.sessionId, paths) ?? SessionState(sessionId: input.sessionId, now: now)
        // Another tool's session is never the hooks' to touch.
        guard s.hostKind == .claude else { return .silent }
        s.updatedAt = now
        s.lastEvent = input.event
        if let cwd = input.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let path = input.transcriptPath, !path.isEmpty {
            if path != s.transcriptPath { s.cursor = nil }
            s.transcriptPath = path
        }
        identify(&s)

        switch event {
        case .sessionEnd:
            s.ended = true
            s.endedAt = now
            s.endReason = input.reason
            s.waiterToken = nil
            try? s.save(paths)
            return .silent
        case .sessionStart:
            s.ended = false
            s.endedAt = nil
            s.endReason = nil
            if input.source == "resume" || input.source == "fork", let tokens = input.contextTokens {
                s.tokens = tokens
                s.tokensAt = now
            }
        default:
            break
        }

        var sawCompaction = false
        if let path = s.transcriptPath {
            let reading = TranscriptReader.read(path: path, cursor: s.cursor, markers: s.sentNonce.map { [$0] } ?? [])
            if let cursor = reading.cursor { s.cursor = cursor }
            sawCompaction = reading.compaction != nil
            Engine.observe(&s, reading, config: config.resolved(for: s), now: now)
        }
        if event == .sessionStart, input.source == "compact", !sawCompaction {
            Engine.compactionStarted(&s, now: now)
        }

        // The thresholds as they apply to this session, now that its size after a compaction may be known.
        let resolved = config.resolved(for: s)
        Engine.apply(Answer.load(input.sessionId, paths), to: &s)
        Engine.advance(&s, config: resolved, watched: !Mute.isMuted(s, paths), now: now)
        if event == .stop { Engine.noteStop(&s) }

        var outcome = HookOutcome.silent
        switch event {
        case .postToolBatch:
            if let text = Engine.claimDelivery(&s, via: .step, config: resolved, nonce: Engine.makeNonce(), now: now) {
                outcome = .addContext(event: HookEvent.postToolBatch.rawValue, text: text)
            }
        case .stop:
            if let text = Engine.claimDelivery(&s, via: .wake, config: resolved, nonce: Engine.makeNonce(), now: now) {
                outcome = .wake(text: text)
                s.waiterToken = nil
            } else if Engine.wantsWaiter(s) {
                let token = UUID().uuidString
                s.waiterToken = token
                let me = ProcessInfo.processInfo.processIdentifier
                s.waiterPid = me
                s.waiterStart = probe.identity(of: me)?.start
                s.waiterSince = now
                outcome = .wait(token: token)
            }
        default:
            break
        }
        // Unrecorded means it could go out twice, so a failed save sends nothing.
        guard (try? s.save(paths)) != nil else { return .silent }
        return outcome
    }

    /// Records which Claude process ran this and whether the session is one you drive.
    func identify(_ s: inout SessionState) {
        guard let pid = claudePid, let id = probe.identity(of: pid) else {
            s.guarded = false
            return
        }
        s.claudePid = pid
        s.claudeStart = id.start
        let entry = registry.entry(pid: pid)
        if let name = entry?.name, !name.isEmpty { s.name = name }
        // Run from a terminal. Windows has no controlling terminal: there Claude Code's own mark says
        // so (`cli`; Claude Desktop's sessions say `claude-desktop`, SDK ones `sdk-…`).
        let inTerminal = id.hasTTY ?? (environment["CLAUDE_CODE_ENTRYPOINT"] == "cli")
        if let entry {
            s.guarded = inTerminal && entry.isInteractiveCLI && entry.sessionId == s.sessionId
        } else {
            // No registry entry: only trust the fallback if Claude Code stopped keeping a registry.
            s.guarded = inTerminal && !registry.isAvailable && environment["CLAUDE_CODE_ENTRYPOINT"] == "cli"
        }
    }

    // MARK: - Waiter

    public struct WaiterResult: Equatable, Sendable {
        public var exitCode: Int32
        public var text: String?
    }

    /// Runs in the background Stop hook after every turn, until the next turn's Stop replaces it,
    /// the session ends, Claude quits, or `maxDuration` passes. Returns exit 2 with the message when a
    /// send is due and the session is idle (Compact, no answer in time, Compact Now, or 500k);
    /// exit 0 otherwise.
    public func runWaiter(sessionId: String, token: String, maxDuration: TimeInterval, poll: TimeInterval = 2) -> WaiterResult {
        let done = WaiterResult(exitCode: 0, text: nil)
        let deadline = clock().addingTimeInterval(maxDuration)
        let changed = DispatchSemaphore(value: 0)
        let watcher = FolderWatcher(paths.answersDir) { changed.signal() }
        defer { withExtendedLifetime(watcher) {} }

        while true {
            _ = changed.wait(timeout: .now() + poll)
            if clock() >= deadline {
                releaseWaiter(sessionId: sessionId, token: token)
                return done
            }
            // Cheap checks without the lock.
            guard let snap = SessionState.load(sessionId, paths), snap.waiterToken == token, !snap.ended else { return done }
            guard let pid = snap.claudePid, probe.isRunning(pid, startedAt: snap.claudeStart) else {
                releaseWaiter(sessionId: sessionId, token: token)
                return done
            }
            let answer = Answer.load(sessionId, paths)
            let newAnswer = answer.map { $0.id != snap.appliedAnswerId } ?? false
            // Settings can change while waiting (a lower later-threshold, a shorter countdown, Off).
            let snapConfig = Config.load(paths)
            let watched = !Mute.isMuted(snap, paths)
            let laterDue = watched && snap.phase == .later && snap.tokens >= snapConfig.resolved(for: snap).laterAt
            let autoYesDue = Engine.autoYesDeadline(snap, config: snapConfig, watched: watched, now: clock()).map { clock() >= $0 } ?? false
            // Stopped watching while a question was up: drop the question now, not at the next turn.
            let unwatchedQuestion = !watched && (snap.phase == .asking || snap.phase == .later)
            let due = newAnswer || laterDue || autoYesDue || unwatchedQuestion
            if !due && snap.phase != .queued && Engine.wantsWaiter(snap) { continue }
            if !due && snap.phase == .queued && !betweenTurns(snap, registry.entry(pid: pid)) { continue }

            guard let lock = FileLock.acquire(paths.lockFile(sessionId), timeout: 1) else { continue }
            guard var s = SessionState.load(sessionId, paths), s.waiterToken == token, !s.ended else {
                lock.release()
                return done
            }
            let config = Config.load(paths).resolved(for: s)
            let now = clock()
            let before = s
            Engine.apply(answer, to: &s)
            Engine.advance(&s, config: config, watched: !Mute.isMuted(s, paths), now: now)

            var result: WaiterResult?
            if s.phase == .queued {
                let entry = registry.entry(pid: pid)
                if let entry, entry.sessionId != sessionId {
                    // This process now runs a different conversation (/clear, /resume): never wake it
                    // with this one's message. The send stays queued for this session's next run.
                    s.waiterToken = nil
                    result = done
                } else if !betweenTurns(s, entry) {
                    // Mid-turn, so leave it queued: the next step or the turn's Stop delivers it, and
                    // this waiter stays for the case where the turn ends without a Stop (Esc).
                } else if let text = Engine.claimDelivery(&s, via: .wake, config: config, nonce: Engine.makeNonce(), now: now) {
                    s.waiterToken = nil
                    result = WaiterResult(exitCode: 2, text: text)
                }
            } else if !Engine.wantsWaiter(s) {
                s.waiterToken = nil
                result = done
            }
            if s != before {
                s.updatedAt = now
                if (try? s.save(paths)) == nil { result = done }
            }
            lock.release()
            if let result { return result }
        }
    }

    /// Whether a wake would start a new turn. Woken mid-turn (`busy`, or `waiting` on a permission
    /// prompt), Claude Code appends the message to a tool result under its "not a message from the
    /// user" banner, and models ignore it as a prompt injection (seen live with Opus). Between turns
    /// with work running in the background, a wake starts a new turn like any other.
    func betweenTurns(_ s: SessionState, _ entry: RegistryEntry?) -> Bool {
        SessionActivity.of(entry, turn: TurnRecord.load(s.sessionId, paths), processStart: s.claudeStart, now: clock()).isBetweenTurns
    }

    /// Clear this waiter's token so the app stops counting on it.
    func releaseWaiter(sessionId: String, token: String) {
        guard let lock = FileLock.acquire(paths.lockFile(sessionId), timeout: 0.5) else { return }
        defer { lock.release() }
        guard var s = SessionState.load(sessionId, paths), s.waiterToken == token else { return }
        s.waiterToken = nil
        try? s.save(paths)
    }
}
