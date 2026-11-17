import Foundation

/// The Cursor hook events Context Guard runs on.
public enum CursorEvent: String, Sendable, CaseIterable {
    /// A prompt is about to go in: yours, a hook's follow-up, or the continue message. A turn starts.
    case beforeSubmitPrompt
    /// A tool finished inside a turn: the save message can go in here, mid-turn.
    case postToolUse
    /// Cursor is summarizing the chat, by itself (`auto`) or because `/summarize` was typed (`manual`).
    case preCompact
    /// A turn ended: the save message can go in as the next prompt, and the hook waits on.
    case stop
    /// The chat was closed.
    case sessionEnd
}

/// The fields Context Guard uses from a Cursor hook's input.
public struct CursorHookInput: Equatable, Sendable {
    public var event: String
    /// The chat (`conversation_id`).
    public var conversationId: String
    /// The turn (`generation_id`).
    public var generationId: String?
    public var model: String?
    public var transcriptPath: String?
    /// The chat's folder (the first of `workspace_roots`).
    public var workspace: String?
    /// beforeSubmitPrompt: the prompt.
    public var prompt: String?
    /// stop: `completed`, `aborted` or `error`.
    public var status: String?
    /// preCompact: `auto` or `manual`.
    public var trigger: String?
    /// preCompact: the size, window and share before summarizing.
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var contextPercent: Double?
    /// sessionEnd: why it closed.
    public var reason: String?
    /// postToolUse: about how many characters the step added to the chat (`stepChars(input:output:)`).
    public var stepChars: Int?

    public init(event: String, conversationId: String, generationId: String? = nil, model: String? = nil,
                transcriptPath: String? = nil, workspace: String? = nil, prompt: String? = nil, status: String? = nil,
                trigger: String? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil, contextPercent: Double? = nil,
                reason: String? = nil, stepChars: Int? = nil) {
        self.event = event
        self.conversationId = conversationId
        self.generationId = generationId
        self.model = model
        self.transcriptPath = transcriptPath
        self.workspace = workspace
        self.prompt = prompt
        self.status = status
        self.trigger = trigger
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.reason = reason
        self.stepChars = stepChars
    }

    public static func parse(_ data: Data) -> CursorHookInput? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = obj["hook_event_name"] as? String,
              let id = (obj["conversation_id"] as? String) ?? (obj["session_id"] as? String), !id.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        return CursorHookInput(
            event: event, conversationId: id, generationId: text("generation_id"), model: text("model"),
            transcriptPath: text("transcript_path"), workspace: (obj["workspace_roots"] as? [String])?.first { !$0.isEmpty },
            prompt: obj["prompt"] as? String, status: text("status"), trigger: text("trigger"),
            contextTokens: TranscriptReader.int(obj["context_tokens"]), contextWindow: TranscriptReader.int(obj["context_window_size"]),
            contextPercent: (obj["context_usage_percent"] as? NSNumber)?.doubleValue, reason: text("reason"),
            stepChars: stepChars(input: obj["tool_input"], output: obj["tool_output"]))
    }

    /// About how many characters a step added to the chat: the tool call's input and what the tool gave
    /// back. A file read counts at its length, since that's all the hook is given of it
    /// (`{"file_path":…,"content_length":N}`). nil: not a step.
    static func stepChars(input: Any?, output: Any?) -> Int? {
        guard input != nil || output != nil else { return nil }
        var result = output as? [String: Any]
        if result == nil, let text = output as? String, text.hasPrefix("{") {
            result = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        let read = result.flatMap { TranscriptReader.int($0["content_length"]) }.flatMap { $0 >= 0 ? $0 : nil }
        return length(input) + (read ?? length(output))
    }

    static func length(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let text = value as? String { return text.utf16.count }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return 0 }
        return String(decoding: data, as: UTF8.self).utf16.count
    }
}

/// The chat as Cursor has it, gathered for one hook call (`ContextGuardCursor` reads Cursor's stores
/// and the hook's process).
public struct CursorChatLook: Equatable, Sendable {
    /// Where the chat runs. nil for a call Context Guard leaves alone: its own judge, a `-p` run, or
    /// a chat in neither the app's store nor the CLI's.
    public var surface: CursorSurface?
    /// A subagent's chat, or a background agent's: only tracked, never guarded.
    public var helper: Bool
    /// Its context now, and its window, as Cursor counts them.
    public var tokens: Int?
    public var window: Int?
    /// The chat's name.
    public var name: String?
    /// The process that runs the chat: the Cursor app, or `cursor-agent`.
    public var pid: Int32?
    public var start: ProcessStart?
    /// The CLI's terminal pane, when Context Guard can type into it.
    public var terminal: CursorTerminal?
    /// In the app: whether Cursor holds the Accessibility permission Context Guard types with.
    public var canType: Bool?

    public init(surface: CursorSurface?, helper: Bool = false, tokens: Int? = nil, window: Int? = nil, name: String? = nil,
                pid: Int32? = nil, start: ProcessStart? = nil, terminal: CursorTerminal? = nil, canType: Bool? = nil) {
        self.surface = surface
        self.helper = helper
        self.tokens = tokens
        self.window = window
        self.name = name
        self.pid = pid
        self.start = start
        self.terminal = terminal
        self.canType = canType
    }
}

/// What the hook answers Cursor.
public enum CursorReply: Equatable, Sendable {
    case none
    /// stop: the save message, as your next prompt (`followup_message`).
    case followUp(String)
    /// postToolUse: the save message, added to the tool's result (`additional_context`).
    case context(String)
    /// stop: stay in the background between turns (`CursorRunner.hold`).
    case hold(token: String)

    /// The JSON the hook prints. Waiting prints what the wait ends with.
    public var json: [String: Any] {
        switch self {
        case .none, .hold: return [:]
        case .followUp(let text): return ["followup_message": text]
        case .context(let text): return ["additional_context": text]
        }
    }
}

/// A chat to type into.
public struct CursorChatRef: Equatable, Sendable {
    public var id: String
    /// Its name, as Cursor shows it.
    public var name: String?
    public var surface: CursorSurface
    /// The process that runs it.
    public var pid: Int32
    /// The CLI's terminal pane, if Context Guard can type into it.
    public var terminal: CursorTerminal?

    public init(id: String, name: String?, surface: CursorSurface = .app, pid: Int32, terminal: CursorTerminal? = nil) {
        self.id = id
        self.name = name
        self.surface = surface
        self.pid = pid
        self.terminal = terminal
    }
}

/// How typing into a chat went.
public enum CursorTypingResult: Equatable, Sendable {
    /// `/summarize` went in and Cursor began summarizing; `continued`: the continue message went in
    /// after it (Cursor sends it once the summary is done).
    case compacted(continued: Bool)
    /// The prompt went in.
    case sent
    /// The prompt box had text in it: nothing was typed.
    case draft
    /// Not now (you're using the computer, or the chat is working): nothing was typed.
    case notNow(String)
    /// It didn't work, and why. Nothing was sent.
    case failed(String)
}

/// Types into a Cursor chat, as you would. In the app it runs inside a Cursor hook, so it uses
/// Cursor's own Accessibility permission; in the CLI it goes through the chat's tmux or herdr pane
/// (`ContextGuardCursor`).
public protocol CursorTyping: Sendable {
    /// Whether typing into the chat could start now. Cheap: it changes nothing on screen.
    func reach(_ chat: CursorChatRef) -> TypingReach
    /// Opens the chat, checks its prompt box is empty, types `/summarize` and picks Summarize. In the
    /// app, once `started()` says the summary began, types `continueText()` (nil: nothing) and sends
    /// it, which Cursor holds until the summary is done; all in one go, and focus goes back where it
    /// was. In the CLI the continue message isn't typed: it goes in through the `stop` hook that ends
    /// the summary.
    func compact(_ chat: CursorChatRef, started: @escaping @Sendable () -> Bool,
                 continueText: @escaping @Sendable () -> String?) -> CursorTypingResult
    /// Sends `text` as your prompt, if the box is empty.
    func send(_ chat: CursorChatRef, text: String) -> CursorTypingResult
}

/// Asks Cursor's model whether a chat is done saving.
public protocol CursorJudging: Sendable {
    /// The judge's reply, or why there's none.
    func judge(_ prompt: String) -> Result<String, CursorJudgeFailure>
}

public struct CursorJudgeFailure: Error, Equatable, Sendable {
    public var reason: String
    /// No judge can answer until you do something (the Cursor CLI isn't installed or signed in): you
    /// are asked instead, with `reason`, rather than the judge being tried again.
    public var asksYou: Bool
    public init(_ reason: String, asksYou: Bool = false) {
        self.reason = reason
        self.asksYou = asksYou
    }

    /// What a judge would have said: it's yours to decide.
    var reply: String {
        let obj = ["verdict": "needs_user", "reason": reason]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The rules for Cursor chats against the state files, run by `context-guard cursor hook`: the
/// counterpart of `HookRunner` and `ModRunner` together. A Cursor chat has no process of its own and
/// no mod, so the `stop` hook stays in the background between turns (`hold`) and does what Claude
/// Code's waiter and mod do: sends the save message when it's due, asks the judge, compacts the chat
/// by typing `/summarize` into it, and sends the continue message. Every failure ends in `.none`.
public struct CursorRunner: Sendable {
    public let paths: Paths
    public let probe: any ProcessProbing
    public let clock: @Sendable () -> Date
    /// How long the hot path waits for the chat's lock before giving up (the next event catches up).
    public var lockTimeout: TimeInterval = 0.3

    /// How long the `stop` hook waits after a turn (as long as Claude Code's), and so how long a
    /// chat with no turns counts as open.
    public static let holdFor: TimeInterval = 12 * 3600 - 300
    /// A prompt box found with text in it is looked at again after this long.
    static let draftRecheck: TimeInterval = 60
    /// Typing that said "not now" is tried again after this long.
    static let notNowWait: TimeInterval = 30
    /// Characters per token, near enough: a chat's steps came out at 4.2 in Cursor's own counts, and
    /// counting a little high asks a little early rather than late.
    static let charsPerToken = 4

    public init(paths: Paths, probe: any ProcessProbing = SystemProcessProbe(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.probe = probe
        self.clock = clock
    }

    // MARK: - One hook call

    public func handle(_ input: CursorHookInput, look: CursorChatLook) -> CursorReply {
        let id = input.conversationId
        guard look.surface != nil, let event = CursorEvent(rawValue: input.event), Paths.isValidSessionID(id),
              (try? paths.ensureDirectories()) != nil else { return .none }
        // A chat Context Guard never saw a turn of has nothing to end.
        if event == .sessionEnd, SessionState.load(id, paths) == nil { return .none }
        let now = clock()
        // A turn starting is recorded first, without the lock: a hook still waiting after the last
        // turn must never send or type into this one.
        if event == .beforeSubmitPrompt, SessionState.load(id, paths).map({ $0.hostKind == .cursor }) ?? true {
            try? TurnRecord(active: true, at: now).save(for: id, paths)
        }
        guard let lock = FileLock.acquire(paths.lockFile(id), timeout: event == .stop ? 2 : lockTimeout) else { return .none }
        defer { lock.release() }

        var s = SessionState.load(id, paths) ?? SessionState(sessionId: id, host: .cursor, now: now)
        // Another tool's session is never Cursor's hooks' to touch.
        guard s.hostKind == .cursor else { return .none }
        s.updatedAt = now
        s.lastEvent = input.event
        note(&s, input, look)
        let config = Config.load(paths)

        switch event {
        case .sessionEnd:
            s.ended = true
            s.endedAt = now
            s.endReason = input.reason
            s.waiterToken = nil
            try? s.save(paths)
            return .none
        case .preCompact:
            compactionStarted(&s, input, now: now)
        case .beforeSubmitPrompt:
            promptSent(&s, input)
        case .postToolUse, .stop:
            // The store has the size once a model call is done; a prompt's or a summary's start
            // still shows the size before it.
            if let tokens = look.tokens {
                observe(&s, stored: tokens, size: estimate(&s, stored: tokens, event: event, stepChars: input.stepChars),
                        config: config, now: now)
            }
        }
        confirmStep(&s, input, event)
        if event == .stop {
            confirmPrompted(&s)
            try? TurnRecord(active: false, at: now).save(for: id, paths)
            s.cursorChat?.turnCutShort = (input.status ?? "completed") != "completed" ? true : nil
        }
        if event == .beforeSubmitPrompt { s.cursorChat?.turnCutShort = nil }

        let resolved = config.resolved(for: s)
        Engine.apply(Answer.load(id, paths), to: &s)
        Engine.advance(&s, config: resolved, watched: !Mute.isMuted(s, paths), now: now)

        var reply = CursorReply.none
        switch event {
        case .postToolUse:
            if let text = claim(&s, via: .step, turn: input.generationId, config: resolved, now: now) { reply = .context(text) }
        case .stop:
            if s.cursorChat?.turnCutShort != true, let text = claim(&s, via: .turn, turn: nil, config: resolved, now: now) {
                reply = .followUp(text)
                s.waiterToken = nil
            } else if let text = continueAfterSummary(&s, config: config, now: now) {
                reply = .followUp(text)
                s.waiterToken = nil
            } else if Engine.wantsWaiter(s) {
                let token = UUID().uuidString
                let me = ProcessInfo.processInfo.processIdentifier
                s.waiterToken = token
                s.waiterPid = me
                s.waiterStart = probe.identity(of: me)?.start
                s.waiterSince = now
                reply = .hold(token: token)
            } else {
                s.waiterToken = nil
            }
        case .beforeSubmitPrompt:
            // A new turn: the hook that waited after the last one is done.
            s.waiterToken = nil
        case .preCompact, .sessionEnd:
            break
        }
        // Unrecorded means it could go out twice, so a failed save sends nothing.
        guard (try? s.save(paths)) != nil else { return .none }
        return reply
    }

    /// What every call says about the chat: where it is, what it's called, its window, which app runs it.
    func note(_ s: inout SessionState, _ input: CursorHookInput, _ look: CursorChatLook) {
        if s.ended {
            // Opened again.
            s.ended = false
            s.endedAt = nil
            s.endReason = nil
        }
        if let w = input.workspace { s.cwd = w }
        if let path = input.transcriptPath {
            if path != s.transcriptPath { s.cursor = nil }
            s.transcriptPath = path
        }
        if let name = look.name, !name.isEmpty { s.title = name }
        var c = s.cursorChat ?? CursorFacts()
        if let w = look.window ?? input.contextWindow, w > 0 { c.window = w }
        if let m = input.model { c.model = m }
        if let surface = look.surface { c.surface = surface }
        if let pid = look.pid {
            c.pid = pid
            c.start = look.start
        }
        c.terminal = look.terminal
        if let canType = look.canType { c.canType = canType }
        s.cursorChat = c
        s.guarded = !look.helper && (c.window ?? 0) > 0 && c.pid != nil
    }

    /// The CLI ends a summary with a `stop` of its own (the app doesn't), so a CLI chat's continue
    /// message goes in as that stop's follow-up rather than being typed. Not when you sent something
    /// since the summary began: it's yours from there.
    func continueAfterSummary(_ s: inout SessionState, config: Config, now: Date) -> String? {
        guard s.cursorChat?.runsIn == .cli, let f = s.followUp, f.stage == .continuing else { return nil }
        var look = SessionLook(activity: .idle, quiet: true)
        if let path = s.transcriptPath, let from = f.compactFrom {
            look.promptSinceCompacting = (CursorConversation.read(path: path, from: from)?.userPrompts ?? 0) > 0
        }
        guard case .continue(_, let text) = Compactor.tick(&s, config: config, watched: !Mute.isMuted(s, paths),
                                                            look: look, now: now) else { return nil }
        return text
    }

    /// The chat's size now: `size`, from Cursor's figure (`stored`) and what the turn added since.
    /// The first figure after a summary is what it came to.
    func observe(_ s: inout SessionState, stored: Int, size: Int, config: Config, now: Date) {
        if s.awaitingCompactionRecord {
            s.lastCompaction?.postTokens = stored
            if var f = s.followUp, f.compactedAt != nil, f.tokensAfter == nil {
                f.tokensAfter = stored
                s.followUp = f
            }
        }
        var reading = TranscriptReading()
        reading.latest = .response(tokens: size)
        reading.firstTokens = stored
        Engine.observe(&s, reading, config: config.resolved(for: s), now: now)
    }

    /// The chat's size, as near as is known. The app's store has a chat's size only as of the end of
    /// its last turn, so a turn's growth would show only once it's over, past where Ask or Wait should
    /// have acted. Each step's characters are counted on top of Cursor's figure until that figure
    /// moves (in the CLI, with every model call) or the turn ends, when Cursor's figure is the size.
    func estimate(_ s: inout SessionState, stored: Int, event: CursorEvent, stepChars: Int?) -> Int {
        var c = s.cursorChat ?? CursorFacts()
        if event == .stop || c.sizeSeen != stored {
            c.sizeSeen = stored
            c.charsSince = nil
        }
        if event == .postToolUse, let added = stepChars, added > 0 {
            c.charsSince = (c.charsSince ?? 0) + added
        }
        s.cursorChat = c
        return stored + (c.charsSince ?? 0) / Self.charsPerToken
    }

    /// Cursor began summarizing the chat. Its size afterwards comes with the next model call.
    func compactionStarted(_ s: inout SessionState, _ input: CursorHookInput, now: Date) {
        if input.trigger == "auto", let pct = input.contextPercent, pct > 0 {
            s.cursorChat?.autoCompactPercent = Int(pct)
        }
        Engine.compacted(&s, trigger: input.trigger, preTokens: input.contextTokens, postTokens: nil, now: now)
        s.cursorChat?.sizeSeen = nil
        s.cursorChat?.charsSince = nil
        s.tokens = 0
        s.tokensAt = nil
        s.awaitingCompactionRecord = true
    }

    /// A prompt is going in. The save message handed over as the next prompt is confirmed by its tag;
    /// any other prompt first means Cursor dropped it (a newer turn of yours came first), so it goes
    /// in at this turn's next step instead. The CLI sends it without this hook: unless its turn is
    /// in the transcript, it was dropped.
    func promptSent(_ s: inout SessionState, _ input: CursorHookInput) {
        guard s.phase == .sent, s.confirmedAt == nil, s.sentVia == .turn, let nonce = s.sentNonce else { return }
        if (input.prompt ?? "").contains(nonce) || prompted(s, nonce) {
            s.confirmedAt = clock()
        } else {
            Engine.unclaim(&s)
        }
    }

    /// The save message handed over as the next prompt went in, by the transcript: the Cursor CLI
    /// sends a hook's follow-up without `beforeSubmitPrompt`, so its turn's `stop` is the first word
    /// of it.
    func confirmPrompted(_ s: inout SessionState) {
        guard s.phase == .sent, s.confirmedAt == nil, s.sentVia == .turn, let nonce = s.sentNonce, prompted(s, nonce) else { return }
        s.confirmedAt = clock()
    }

    func prompted(_ s: SessionState, _ nonce: String) -> Bool {
        guard let path = s.transcriptPath else { return false }
        return CursorConversation.prompted(path: path, from: s.confirmedOffset, marker: nonce)
    }

    /// The save message that went in mid-turn reached the model once that turn went on: another tool
    /// call, or the turn ending as it should. A turn stopped or failed right after it may not have.
    func confirmStep(_ s: inout SessionState, _ input: CursorHookInput, _ event: CursorEvent) {
        guard s.phase == .sent, s.confirmedAt == nil, s.sentVia == .step, let turn = s.cursorChat?.stepTurn else { return }
        let sameTurn = input.generationId == turn
        switch event {
        case .postToolUse where sameTurn:
            s.confirmedAt = clock()
        case .stop where sameTurn:
            if (input.status ?? "completed") == "completed" {
                s.confirmedAt = clock()
            } else {
                Engine.requeueUnconfirmed(&s)
            }
        case .beforeSubmitPrompt:
            Engine.requeueUnconfirmed(&s)
        default:
            break
        }
    }

    /// Hands over the save message if it's due, noting where the transcript ended: the judge reads
    /// what the chat did from there.
    func claim(_ s: inout SessionState, via channel: DeliveryChannel, turn: String?, config: Config, now: Date) -> String? {
        guard let text = Engine.claimDelivery(&s, via: channel, config: config, nonce: Engine.makeNonce(), now: now) else { return nil }
        s.confirmedOffset = s.transcriptPath.flatMap(Self.size)
        s.cursorChat?.stepTurn = channel == .step ? turn : nil
        return text
    }

    static func size(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
    }

    // MARK: - Between turns

    /// Runs in the `stop` hook after every turn, until a new turn starts, the chat closes, Cursor
    /// quits or `maxDuration` passes. Returns the save message once it's due (Cursor sends it as your
    /// next prompt); meanwhile asks the judge and compacts the chat once it has saved. nil: nothing to
    /// send.
    public func hold(sessionId id: String, token: String, maxDuration: TimeInterval, poll: TimeInterval = 2,
                     typing: any CursorTyping, judge: any CursorJudging) -> String? {
        let deadline = clock().addingTimeInterval(maxDuration)
        let changed = DispatchSemaphore(value: 0)
        let watcher = FolderWatcher(paths.answersDir) { changed.signal() }
        defer { withExtendedLifetime(watcher) {} }
        var again = false

        while true {
            if !again { _ = changed.wait(timeout: .now() + poll) }
            again = false
            let now = clock()
            if now >= deadline {
                release(id, token: token)
                return nil
            }
            // Cheap checks without the lock.
            guard let snap = SessionState.load(id, paths), snap.waiterToken == token, !snap.ended else { return nil }
            guard let facts = snap.cursorChat, let pid = facts.pid, probe.isRunning(pid, startedAt: facts.start) else {
                release(id, token: token)
                return nil
            }
            if let turn = TurnRecord.load(id, paths), turn.active, turn.at >= (snap.waiterSince ?? .distantPast) {
                // A new turn started; its own stop hook takes over.
                release(id, token: token)
                return nil
            }
            guard due(snap, now: now) else { continue }

            // Gathered before taking the lock: reading the transcript can take a moment.
            var look = SessionLook(activity: .idle, quiet: true)
            look.draft = snap.cursorChat?.draftAt.map { now.timeIntervalSince($0) < Self.draftRecheck } ?? false
            let chat = CursorChatRef(id: id, name: snap.title, surface: facts.runsIn, pid: pid, terminal: facts.terminal)
            // Asked only when typing is next: finding the chat on screen takes a moment.
            if let f = snap.followUp, f.verdict == .ready || f.stage == .continuing {
                look.typing = typing.reach(chat)
                if look.typing == .ready, let until = facts.typingWaitUntil, now < until { look.typing = .notNow }
            }
            // A CLI chat's continue message goes in through the stop that ends its summary.
            if chat.surface == .cli, snap.followUp?.stage == .continuing { look.typing = .never }
            if let path = snap.transcriptPath, let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                look.transcriptSize = (attrs[.size] as? NSNumber)?.uint64Value
                look.lastWrite = attrs[.modificationDate] as? Date
                look.quiet = look.lastWrite.map { now.timeIntervalSince($0) >= 1 } ?? true
                if look.quiet, let nonce = Compactor.nonceToJudge(snap, now: now) {
                    look.conversation = CursorConversation.read(path: path, from: snap.confirmedOffset, after: nonce)
                }
                if let f = snap.followUp, f.stage == .continuing, let from = f.compactFrom {
                    look.promptSinceCompacting = (CursorConversation.read(path: path, from: from)?.userPrompts ?? 0) > 0
                }
            }

            guard let lock = FileLock.acquire(paths.lockFile(id), timeout: 1) else { continue }
            guard var s = SessionState.load(id, paths), s.waiterToken == token, !s.ended else {
                lock.release()
                return nil
            }
            let config = Config.load(paths)
            let resolved = config.resolved(for: s)
            let watched = !Mute.isMuted(s, paths)
            let before = s
            Engine.apply(Answer.load(id, paths), to: &s)
            Engine.advance(&s, config: resolved, watched: watched, now: now)
            var text: String?
            var action = ModAction.none
            if s.cursorChat?.turnCutShort != true, let t = claim(&s, via: .turn, turn: nil, config: resolved, now: now) {
                text = t
                s.waiterToken = nil
            } else {
                action = Compactor.tick(&s, config: config, watched: watched, look: look, now: now)
            }
            if s != before {
                s.updatedAt = now
                if (try? s.save(paths)) == nil {
                    lock.release()
                    continue
                }
            }
            lock.release()
            if let text { return text }

            switch action {
            case .none:
                break
            case .judge(let nonce, let mark, let prompt):
                let report: ModReport
                switch judge.judge(prompt) {
                case .success(let reply): report = ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: reply)
                case .failure(let why) where why.asksYou:
                    report = ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: why.reply)
                case .failure(let why): report = ModReport(sessionId: id, nonce: nonce, kind: .judgeFailed, error: why.reason)
                }
                again = update(id) { s, now in Compactor.apply(report, to: &s, now: now) } ?? false
            case .compact(let nonce):
                let since = clock()
                let paths = self.paths
                let result = typing.compact(chat, started: { Self.compactionSeen(id, since: since, paths) },
                                            continueText: { self.claimContinue(id, nonce: nonce) })
                typed(result, id: id, nonce: nonce)
            case .continue(let nonce, let text):
                typed(typing.send(chat, text: text), id: id, nonce: nonce, continuing: true)
            }
        }
    }

    /// Whether anything could be for the hold to do: an answer, a deadline, the save message, or the
    /// steps after it.
    func due(_ s: SessionState, now: Date) -> Bool {
        if s.phase == .queued { return true }
        if Compactor.startableNonce(s, now: now) != nil || (s.followUp?.isActive ?? false) { return true }
        if let a = Answer.load(s.sessionId, paths), a.id != s.appliedAnswerId { return true }
        let config = Config.load(paths)
        let watched = !Mute.isMuted(s, paths)
        if watched, s.phase == .later, s.tokens >= config.resolved(for: s).laterAt { return true }
        if let deadline = Engine.autoYesDeadline(s, config: config, watched: watched, now: now), now >= deadline { return true }
        return !watched && (s.phase == .asking || s.phase == .later)
    }

    /// Cursor began summarizing since `since` (its `preCompact` hook said so). Dates in the state
    /// file are whole seconds.
    static func compactionSeen(_ id: String, since: Date, _ paths: Paths) -> Bool {
        guard let at = SessionState.load(id, paths)?.lastCompaction?.at else { return false }
        return at >= since.addingTimeInterval(-1)
    }

    /// Right after the summary began: the continue message, marked as sent (Cursor sends it once the
    /// summary is done). nil when it isn't due: the follow-up moved on, or it was stopped.
    func claimContinue(_ id: String, nonce: String) -> String? {
        let paths = self.paths
        return update(id) { s, now -> String? in
            guard let f = s.followUp, f.nonce == nonce, f.stage == .continuing else { return nil }
            let look = SessionLook(activity: .idle, quiet: true)
            guard case .continue(_, let text) = Compactor.tick(&s, config: Config.load(paths), watched: !Mute.isMuted(s, paths),
                                                                 look: look, now: now) else { return nil }
            return text
        } ?? nil
    }

    /// Folds in how typing went.
    func typed(_ result: CursorTypingResult, id: String, nonce: String, continuing: Bool = false) {
        _ = update(id) { s, now in
            var c = s.cursorChat ?? CursorFacts()
            switch result {
            case .compacted(let continued):
                c.typingProblem = nil
                c.typingProblemAt = nil
                // The continue message was marked as sent but didn't go in: it's tried again.
                if !continued, let f = s.followUp, f.nonce == nonce, f.stage == .done, f.continuedAt != nil {
                    Compactor.apply(ModReport(sessionId: id, nonce: nonce, kind: .continueFailed,
                                              error: "the continue message couldn't be typed"), to: &s, now: now)
                }
            case .sent:
                c.typingProblem = nil
                c.typingProblemAt = nil
            case .draft:
                c.draftAt = now
                if continuing {
                    // What you typed comes first; the rest is yours (`Compactor`: took over).
                    Compactor.apply(ModReport(sessionId: id, nonce: nonce, kind: .continueFailed, error: "you were typing"), to: &s, now: now)
                } else {
                    Compactor.apply(ModReport(sessionId: id, nonce: nonce, kind: .compactDeferred), to: &s, now: now)
                }
            case .notNow:
                c.typingWaitUntil = now.addingTimeInterval(Self.notNowWait)
                if continuing {
                    s.followUp?.stage = .continuing
                    s.followUp?.continuedAt = nil
                } else {
                    Compactor.apply(ModReport(sessionId: id, nonce: nonce, kind: .compactDeferred), to: &s, now: now)
                }
            case .failed(let why):
                c.typingProblem = why
                c.typingProblemAt = now
                Compactor.apply(ModReport(sessionId: id, nonce: nonce, kind: continuing ? .continueFailed : .compactFailed, error: why),
                                to: &s, now: now)
            }
            s.cursorChat = c
            return true
        }
    }

    func update<T>(_ id: String, _ change: (inout SessionState, Date) -> T) -> T? {
        guard Paths.isValidSessionID(id), let lock = FileLock.acquire(paths.lockFile(id), timeout: 2) else { return nil }
        defer { lock.release() }
        guard var s = SessionState.load(id, paths), s.hostKind == .cursor else { return nil }
        let now = clock()
        let before = s
        let out = change(&s, now)
        if s != before {
            s.updatedAt = now
            guard (try? s.save(paths)) != nil else { return nil }
        }
        return out
    }

    /// Clears this hold's token so the apps stop counting on it.
    func release(_ id: String, token: String) {
        guard let lock = FileLock.acquire(paths.lockFile(id), timeout: 0.5) else { return }
        defer { lock.release() }
        guard var s = SessionState.load(id, paths), s.waiterToken == token else { return }
        s.waiterToken = nil
        try? s.save(paths)
    }
}
