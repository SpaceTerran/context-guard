import Foundation

/// What happens after the save message reaches the session: wait until it has finished saving (Haiku
/// reads the conversation to decide), compact it, then send the continue message. Kept in the session's
/// state file and moved along by `Compactor`, which the Context Guard mod runs inside the session.
public struct FollowUp: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, CaseIterable, Sendable {
        /// Waiting for the session to finish its turn, or for Haiku's verdict.
        case checking
        /// Haiku: the session is still saving.
        case working
        /// Haiku: the session asked the user something, or is blocked on them.
        case needsYou
        /// Ready, but there's text in the prompt box.
        case draft
        case compacting
        /// Compacted; the continue message goes out once the session is idle.
        case continuing
        /// The continue message went out.
        case done
        /// You typed or sent something before the continue message went out, so it didn't.
        case tookOver
        /// Ended without finishing, because something changed (a newer request, watching off, …);
        /// `note` says what.
        case stopped
        /// Gave up after errors (Haiku, compacting or the continue message kept failing); `note` says which.
        case failed

        // A stage from a newer build reads as stopped rather than failing the whole state file.
        public init(from decoder: Decoder) throws {
            self = Stage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .stopped
        }
    }

    public enum Verdict: String, Codable, Sendable {
        case ready, working
        case needsUser = "needs_user"
    }

    /// The save message this follows.
    public var nonce: String
    /// Started by Compact Now: you asked for it, so turning Context Guard off or not watching the
    /// tab doesn't stop it. nil in files from before this existed (they were all automatic).
    public var manual: Bool?
    public var stage: Stage
    public var startedAt: Date
    public var stageAt: Date
    /// Haiku's reason for its verdict, or why the follow-up stopped.
    public var note: String?

    public var verdict: Verdict?
    public var verdictAt: Date?
    /// The conversation as the verdict saw it (`Conversation.mark`): anything newer outdates it.
    public var verdictMark: UInt64?
    /// "working" verdicts in a row on an unchanged conversation (asked again while it sits idle).
    public var workingRepeats = 0
    /// A question handed to the mod that hasn't come back yet.
    public var judgeAskedAt: Date?
    public var judgeFailures = 0
    public var nextJudgeAt: Date?

    public var compactAttempts = 0
    /// Transcript size when compacting began: a prompt of yours after it means you took over.
    public var compactFrom: UInt64?
    public var compactStartedAt: Date?
    public var compactedAt: Date?
    public var tokensBefore: Int?
    public var tokensAfter: Int?
    public var continuedAt: Date?
    public var continueFailures = 0

    public init(nonce: String, manual: Bool = false, now: Date) {
        self.nonce = nonce
        self.manual = manual ? true : nil
        self.stage = .checking
        self.startedAt = now
        self.stageAt = now
    }

    public var isActive: Bool { ![.done, .tookOver, .stopped, .failed].contains(stage) }

    /// Still waiting for the session to be ready.
    public var isBeforeCompacting: Bool { [.checking, .working, .needsYou, .draft].contains(stage) }

    // Missing keys fall back to defaults, so a file from another build still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nonce = try c.decode(String.self, forKey: .nonce)
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual)
        stage = try c.decode(Stage.self, forKey: .stage)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        stageAt = try c.decodeIfPresent(Date.self, forKey: .stageAt) ?? startedAt
        note = try c.decodeIfPresent(String.self, forKey: .note)
        verdict = try? c.decodeIfPresent(Verdict.self, forKey: .verdict)
        verdictAt = try c.decodeIfPresent(Date.self, forKey: .verdictAt)
        verdictMark = try c.decodeIfPresent(UInt64.self, forKey: .verdictMark)
        workingRepeats = try c.decodeIfPresent(Int.self, forKey: .workingRepeats) ?? 0
        judgeAskedAt = try c.decodeIfPresent(Date.self, forKey: .judgeAskedAt)
        judgeFailures = try c.decodeIfPresent(Int.self, forKey: .judgeFailures) ?? 0
        nextJudgeAt = try c.decodeIfPresent(Date.self, forKey: .nextJudgeAt)
        compactAttempts = try c.decodeIfPresent(Int.self, forKey: .compactAttempts) ?? 0
        compactFrom = try c.decodeIfPresent(UInt64.self, forKey: .compactFrom)
        compactStartedAt = try c.decodeIfPresent(Date.self, forKey: .compactStartedAt)
        compactedAt = try c.decodeIfPresent(Date.self, forKey: .compactedAt)
        tokensBefore = try c.decodeIfPresent(Int.self, forKey: .tokensBefore)
        tokensAfter = try c.decodeIfPresent(Int.self, forKey: .tokensAfter)
        continuedAt = try c.decodeIfPresent(Date.self, forKey: .continuedAt)
        continueFailures = try c.decodeIfPresent(Int.self, forKey: .continueFailures) ?? 0
    }
}

/// What the mod should do next.
public enum ModAction: Equatable, Sendable {
    case none
    /// Ask Haiku `prompt`, then report the reply with `mark`.
    case judge(nonce: String, mark: UInt64, prompt: String)
    /// Compact the session (`$.session.compact()`), then report how it went.
    case compact(nonce: String)
    /// Submit `text` as the user's prompt, if the prompt box is still empty.
    case `continue`(nonce: String, text: String)
}

/// What the mod reports back after an action.
public struct ModReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case judged, judgeFailed, compacted, compactSkipped, compactFailed, continueFailed
    }

    public var sessionId: String
    public var nonce: String
    public var kind: Kind
    /// judged: the `mark` the judge action came with.
    public var mark: UInt64?
    /// judged: Haiku's reply.
    public var text: String?
    public var error: String?
    public var tokensBefore: Int?
    public var tokensAfter: Int?

    public init(sessionId: String, nonce: String, kind: Kind, mark: UInt64? = nil, text: String? = nil,
                error: String? = nil, tokensBefore: Int? = nil, tokensAfter: Int? = nil) {
        self.sessionId = sessionId
        self.nonce = nonce
        self.kind = kind
        self.mark = mark
        self.text = text
        self.error = error
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}

/// The session as it is right now, gathered for one tick.
public struct SessionLook: Equatable, Sendable {
    /// Its Claude process is running this conversation and is between turns.
    public var idle = false
    /// Nothing written to the transcript in the last second, so a finished turn's last lines are in.
    public var quiet = false
    /// Subagents still running.
    public var agents = 0
    /// Text in the prompt box.
    public var draft = false
    /// The conversation after the save message (read only when a verdict depends on it).
    public var conversation: Conversation?
    /// You sent a prompt or ran a command after compacting began.
    public var promptSinceCompacting = false
    public var transcriptSize: UInt64?
    public var lastWrite: Date?

    public init(idle: Bool = false, quiet: Bool = false, agents: Int = 0, draft: Bool = false,
                conversation: Conversation? = nil, promptSinceCompacting: Bool = false,
                transcriptSize: UInt64? = nil, lastWrite: Date? = nil) {
        self.idle = idle
        self.quiet = quiet
        self.agents = agents
        self.draft = draft
        self.conversation = conversation
        self.promptSinceCompacting = promptSinceCompacting
        self.transcriptSize = transcriptSize
        self.lastWrite = lastWrite
    }
}

/// The follow-up rules. Pure functions over `SessionState`, like `Engine`.
public enum Compactor {
    public static let judgeModel = "haiku"
    public static let judgeMaxTokens = 300
    public static let judgeTimeoutMs = 30_000
    /// A judge handed out this long ago without a report is abandoned (the mod reloaded).
    static let judgeAbandoned: TimeInterval = 90
    /// An idle session Haiku called "working" is looked at again after this long.
    static let workingRecheck: TimeInterval = 300
    static let maxWorkingRepeats = 6
    static let maxJudgeFailures = 8
    static let maxCompactAttempts = 3
    static let maxContinueFailures = 3
    /// Compacting this long with no compaction seen, and idle: it never happened (the mod reloaded).
    static let compactStall: TimeInterval = 600
    /// A save message confirmed longer ago than this wasn't followed when it arrived (no mod then,
    /// or Context Guard before this feature): it's left alone rather than compacted out of the blue.
    static let startWindow: TimeInterval = 600

    /// Why the follow-up can't run for this session now, or nil if it can. Compact Now (`manual`)
    /// was your own request, so only the session going away stops it.
    public static func blocker(_ s: SessionState, config: Config, watched: Bool, manual: Bool) -> String? {
        if !s.guarded || s.ended { return "the session isn't watched" }
        if manual { return nil }
        if !config.enabled { return "Context Guard is off" }
        if !watched { return "you stopped watching this session" }
        return nil
    }

    /// The save message a follow-up would start for now, if there is one.
    public static func startableNonce(_ s: SessionState, now: Date) -> String? {
        guard s.phase == .sent, let nonce = s.sentNonce, let confirmed = s.confirmedAt,
              s.followUp?.nonce != nonce, now.timeIntervalSince(confirmed) <= startWindow else { return nil }
        return nonce
    }

    /// The save message whose conversation the next tick would judge, if any.
    public static func nonceToJudge(_ s: SessionState, now: Date) -> String? {
        if let nonce = startableNonce(s, now: now) { return nonce }
        guard let f = s.followUp, f.isBeforeCompacting, s.phase == .sent, s.sentNonce == f.nonce else { return nil }
        return f.nonce
    }

    /// One tick of the mod: move the follow-up along and say what the mod should do.
    public static func tick(_ s: inout SessionState, config: Config, watched: Bool, look: SessionLook, now: Date) -> ModAction {
        if var f = s.followUp, f.isBeforeCompacting, s.phase != .sent || s.sentNonce != f.nonce {
            // The save message it waited on was replaced (a new question, a new send) or reset.
            stop(&f, "a newer request replaced it", now: now)
            s.followUp = f
        }
        if let nonce = startableNonce(s, now: now) {
            let manual = s.sendReason == .manual
            if blocker(s, config: config, watched: watched, manual: manual) == nil {
                s.followUp = FollowUp(nonce: nonce, manual: manual, now: now)
            }
        }
        guard var f = s.followUp, f.isActive else { return .none }
        if let blocked = blocker(s, config: config, watched: watched, manual: f.manual == true) {
            stop(&f, blocked, now: now)
            s.followUp = f
            return .none
        }
        let action = step(&f, config: config, look: look, now: now)
        s.followUp = f
        return action
    }

    static func step(_ f: inout FollowUp, config: Config, look: SessionLook, now: Date) -> ModAction {
        switch f.stage {
        case .compacting:
            if look.idle, now.timeIntervalSince(f.compactStartedAt ?? f.stageAt) > compactStall {
                // The mod never got to compact (it reloaded mid-call): check again.
                set(&f, .checking, now: now)
                f.verdict = nil
            }
            return .none

        case .continuing:
            if look.promptSinceCompacting {
                set(&f, .tookOver, now: now)
                return .none
            }
            guard look.idle else { return .none }
            if look.draft {
                set(&f, .tookOver, now: now)
                return .none
            }
            guard look.quiet else { return .none }
            // Marked done before it goes out: a lost report can leave one unsent, never send two.
            set(&f, .done, now: now)
            f.continuedAt = now
            return .continue(nonce: f.nonce, text: config.continueMessage)

        case .checking, .working, .needsYou, .draft:
            if let asked = f.judgeAskedAt, now.timeIntervalSince(asked) < judgeAbandoned { return .none }
            f.judgeAskedAt = nil
            guard look.idle, look.agents == 0, look.quiet,
                  let conversation = look.conversation, conversation.after == f.nonce, conversation.mark > 0 else { return .none }

            if let verdict = f.verdict, f.verdictMark == conversation.mark {
                switch verdict {
                case .ready:
                    if look.draft {
                        if f.stage != .draft { set(&f, .draft, now: now) }
                        return .none
                    }
                    guard f.compactAttempts < maxCompactAttempts else {
                        fail(&f, "compacting didn't go through after \(maxCompactAttempts) tries", now: now)
                        return .none
                    }
                    // Marked before the mod compacts, so a reload mid-call can't compact twice.
                    set(&f, .compacting, now: now)
                    f.compactAttempts += 1
                    f.compactStartedAt = now
                    f.compactFrom = look.transcriptSize
                    return .compact(nonce: f.nonce)
                case .needsUser:
                    return .none
                case .working:
                    guard now.timeIntervalSince(f.verdictAt ?? now) >= workingRecheck else { return .none }
                    guard f.workingRepeats < maxWorkingRepeats else {
                        // Idle for half an hour and still "working": hand it to you.
                        f.verdict = .needsUser
                        f.note = "it has been idle a long time but doesn't look finished"
                        set(&f, .needsYou, now: now)
                        return .none
                    }
                }
            }
            if let next = f.nextJudgeAt, now < next { return .none }
            f.judgeAskedAt = now
            let idleFor = look.lastWrite.map { now.timeIntervalSince($0) } ?? 0
            return .judge(nonce: f.nonce, mark: conversation.mark,
                          prompt: JudgePrompt.make(message: config.message, conversation: conversation.text, idleFor: idleFor))

        case .done, .tookOver, .stopped, .failed:
            return .none
        }
    }

    /// Fold in what the mod reports. Returns whether the mod should tick again right away.
    @discardableResult
    public static func apply(_ r: ModReport, to s: inout SessionState, now: Date) -> Bool {
        guard var f = s.followUp, f.nonce == r.nonce else { return false }
        defer { s.followUp = f }
        switch r.kind {
        case .judged:
            guard f.isBeforeCompacting, let mark = r.mark else { return false }
            f.judgeAskedAt = nil
            guard let reply = JudgeReply.parse(r.text ?? "") else {
                failJudge(&f, "its answer wasn't readable", now: now)
                return false
            }
            f.judgeFailures = 0
            f.nextJudgeAt = nil
            let again = reply.verdict == .working && f.verdict == .working && f.verdictMark == mark
            f.workingRepeats = again ? f.workingRepeats + 1 : 0
            f.verdict = reply.verdict
            f.verdictAt = now
            f.verdictMark = mark
            f.note = reply.reason
            switch reply.verdict {
            case .ready: set(&f, .checking, now: now)
            case .working: set(&f, .working, now: now)
            case .needsUser: set(&f, .needsYou, now: now)
            }
            return reply.verdict == .ready

        case .judgeFailed:
            guard f.isBeforeCompacting else { return false }
            f.judgeAskedAt = nil
            failJudge(&f, r.error ?? "no answer", now: now)
            return false

        case .compacted:
            guard f.stage == .compacting || f.stage == .continuing else { return false }
            if f.stage == .compacting { set(&f, .continuing, now: now) }
            f.compactedAt = f.compactedAt ?? now
            f.tokensBefore = r.tokensBefore ?? f.tokensBefore
            f.tokensAfter = r.tokensAfter ?? f.tokensAfter
            return false

        case .compactSkipped, .compactFailed:
            guard f.stage == .compacting else { return false }
            // A turn that started in the meantime changes the conversation, so it's judged again.
            set(&f, .checking, now: now)
            f.note = r.kind == .compactSkipped ? "a hook stopped the compaction" : "compacting failed: \(r.error ?? "no reason given")"
            return false

        case .continueFailed:
            guard f.stage == .done, f.continuedAt != nil else { return false }
            f.continueFailures += 1
            f.continuedAt = nil
            if f.continueFailures >= maxContinueFailures {
                // Compacted, so the note is only why the message didn't go in.
                fail(&f, r.error ?? "no reason given", now: now)
            } else {
                set(&f, .continuing, now: now)
            }
            return false
        }
    }

    /// A compaction happened (seen by the hooks). Ours moves on to the continue message; any other
    /// before it was ready ends the follow-up, since that conversation is gone.
    static func compacted(_ s: inout SessionState, trigger: String?, preTokens: Int?, postTokens: Int?, now: Date) {
        guard var f = s.followUp, f.isActive else { return }
        switch f.stage {
        case .compacting:
            set(&f, .continuing, now: now)
            f.compactedAt = now
            f.tokensBefore = preTokens
            f.tokensAfter = postTokens
        case .continuing:
            break
        default:
            stop(&f, trigger == "auto" ? "Claude Code compacted it by itself" : "it was compacted before it was ready", now: now)
        }
        s.followUp = f
    }

    static func failJudge(_ f: inout FollowUp, _ error: String, now: Date) {
        f.judgeFailures += 1
        if f.judgeFailures >= maxJudgeFailures {
            fail(&f, "Haiku didn't answer (\(error))", now: now)
            return
        }
        // 15 s, 30 s, 1 min, 2 min, 4 min, then every 5 min.
        let delay = min(300, 15 * pow(2, Double(f.judgeFailures - 1)))
        f.nextJudgeAt = now.addingTimeInterval(delay)
    }

    static func set(_ f: inout FollowUp, _ stage: FollowUp.Stage, now: Date) {
        f.stage = stage
        f.stageAt = now
    }

    static func stop(_ f: inout FollowUp, _ note: String, now: Date) {
        set(&f, .stopped, now: now)
        f.note = note
    }

    static func fail(_ f: inout FollowUp, _ note: String, now: Date) {
        set(&f, .failed, now: now)
        f.note = note
    }
}
