import Foundation

/// The per-session rules. Pure functions over `SessionState`, so every rule is unit-tested.
public enum Engine {
    /// Phases where the save message is still pending; a compaction during one of these cuts it short.
    static let pendingPhases: Set<Phase> = [.asking, .later, .queued]

    // MARK: Observing the transcript

    /// Fold in what the transcript showed: compaction, new size, title, delivery confirmation.
    public static func observe(_ s: inout SessionState, _ r: TranscriptReading, config: Config, now: Date) {
        if case .compaction(let trigger, let pre, let post)? = r.compaction {
            if s.awaitingCompactionRecord, var known = s.lastCompaction {
                // The record of a compaction SessionStart already handled: fill in its details.
                known.trigger = trigger ?? known.trigger
                known.preTokens = pre ?? known.preTokens
                known.postTokens = post
                s.lastCompaction = known
                if var f = s.followUp, f.compactedAt != nil, f.tokensAfter == nil {
                    f.tokensBefore = pre ?? f.tokensBefore
                    f.tokensAfter = post
                    s.followUp = f
                }
            } else {
                compacted(&s, trigger: trigger, preTokens: pre, postTokens: post, now: now)
            }
        }
        if let tokens = r.tokens {
            s.tokens = tokens
            s.tokensAt = now
            s.awaitingCompactionRecord = false
        }
        if let title = r.title { s.title = title }
        if s.phase == .sent, s.confirmedAt == nil, let nonce = s.sentNonce, r.markersSeen.contains(nonce) {
            s.confirmedAt = now
            s.confirmedOffset = r.from
        }
        // Context fell far below the ask threshold without a compaction record (rewind, /clear-like
        // resets): treat it as a fresh start. Small dips (idle tool-result clearing) don't re-arm.
        if s.phase != .watching, s.tokens < config.askAt / 2 {
            rearm(&s)
        }
    }

    /// A compaction happened: note what it interrupted and start over.
    public static func compacted(_ s: inout SessionState, trigger: String?, preTokens: Int?, postTokens: Int?, now: Date) {
        s.lastCompaction = Compaction(
            at: now, trigger: trigger, preTokens: preTokens ?? s.tokens, postTokens: postTokens,
            interruptedPhase: pendingPhases.contains(s.phase) ? s.phase : nil)
        Compactor.compacted(&s, trigger: trigger, preTokens: preTokens ?? s.tokens, postTokens: postTokens, now: now)
        if let postTokens {
            s.tokens = postTokens
            s.tokensAt = now
        }
        rearm(&s)
    }

    /// SessionStart(compact) arrived before the compaction record: start over with the size unknown.
    public static func compactionStarted(_ s: inout SessionState, now: Date) {
        compacted(&s, trigger: nil, preTokens: nil, postTokens: nil, now: now)
        s.tokens = 0
        s.tokensAt = nil
        s.awaitingCompactionRecord = true
    }

    public static func rearm(_ s: inout SessionState) {
        s.phase = .watching
        s.askedAt = nil
        s.askedTokens = nil
        clearSend(&s)
    }

    static func clearSend(_ s: inout SessionState) {
        s.sendReason = nil
        s.sentAt = nil
        s.sentNonce = nil
        s.sentVia = nil
        s.sentTokens = nil
        s.confirmedAt = nil
        s.confirmedOffset = nil
        s.askTimedOut = nil
        s.stopsSinceSent = 0
        s.resendCount = 0
    }

    // MARK: Answers

    /// Apply your answer once. Answers for an older cycle are recorded and ignored.
    public static func apply(_ answer: Answer?, to s: inout SessionState) {
        guard let answer, answer.id != s.appliedAnswerId else { return }
        s.appliedAnswerId = answer.id
        guard answer.cycle == s.cycle else { return }
        switch answer.action {
        case .yes:
            let inFlight = s.phase == .queued || (s.phase == .sent && s.confirmedAt == nil)
            guard !inFlight else { return }
            if var f = s.followUp, f.isActive, s.phase == .sent, s.sentNonce == f.nonce {
                // It already has this save message, so it isn't asked again. Before compacting,
                // Compact Now makes the follow-up yours: turning Context Guard off or not watching
                // the tab no longer stops it.
                if f.isBeforeCompacting, f.manual != true {
                    f.manual = true
                    s.followUp = f
                }
                return
            }
            // Answering the question (the popup, or the CLI as the popup would) is a yes. Compact Now
            // in the menu is always a request of its own, even while a question is open.
            let reason: SendReason = s.phase == .asking && answer.source != .menu ? .yes : .manual
            clearSend(&s)
            s.phase = .queued
            s.sendReason = reason
        case .later:
            if s.phase == .asking { s.phase = .later }
        case .skip:
            if s.phase == .asking || s.phase == .later { s.phase = .skipped }
        }
    }

    // MARK: Thresholds

    /// Threshold transitions. Only for guarded sessions; Off pauses asking and the automatic send.
    /// `watched` is false when you stopped watching this session's tab: any question is dropped and
    /// nothing is asked or sent by itself until you watch it again (then it asks again if it's big).
    public static func advance(_ s: inout SessionState, config: Config, watched: Bool = true, now: Date) {
        guard s.guarded else { return }
        guard watched else {
            if s.phase == .asking || s.phase == .later {
                s.phase = .watching
                s.askedAt = nil
                s.askedTokens = nil
            }
            return
        }
        if config.enabled {
            switch s.phase {
            case .watching where s.tokens >= config.askAt:
                ask(&s, now: now)
            case .asking where autoYesDeadline(s, config: config, now: now).map({ now >= $0 }) ?? false:
                // No answer in time counts as Yes.
                s.phase = .queued
                s.sendReason = .yes
                s.askTimedOut = true
            case .sent where s.sendReason == .manual && (s.sentTokens ?? 0) < config.askAt && s.tokens >= config.askAt:
                // A manual send below the threshold doesn't use up this cycle's question.
                ask(&s, now: now)
            case .later where s.tokens >= config.laterAt:
                s.phase = .queued
                s.sendReason = .later
            default:
                break
            }
        } else if s.phase == .later, s.tokens >= config.laterAt {
            // Passed the automatic-send point while Off: ask again when back On, don't send blind.
            s.phase = .asking
            s.askedAt = now
        }
    }

    /// When an unanswered question counts as Yes: `autoYesSeconds` after it was asked, or after
    /// Context Guard was last turned on if that's later. nil when nothing is counting down.
    public static func autoYesDeadline(_ s: SessionState, config: Config, watched: Bool = true, now: Date) -> Date? {
        guard s.guarded, watched, config.enabled, config.autoYesSeconds > 0, s.phase == .asking, let asked = s.askedAt else { return nil }
        // A config without `enabledAt` holds the countdown (the deadline moves with `now`).
        let start = max(asked, config.enabledAt ?? now)
        return start.addingTimeInterval(TimeInterval(config.autoYesSeconds))
    }

    static func ask(_ s: inout SessionState, now: Date) {
        s.cycle += 1
        s.phase = .asking
        s.askedAt = now
        s.askedTokens = s.tokens
        clearSend(&s)
    }

    // MARK: Delivery

    /// Count a Stop after sending. If two pass without the message showing up in the transcript
    /// (cancelled step, crash between marking and printing), queue it once more.
    public static func noteStop(_ s: inout SessionState) {
        guard s.phase == .sent, s.confirmedAt == nil else { return }
        s.stopsSinceSent += 1
        if s.stopsSinceSent >= 2, s.resendCount < 1 {
            let resends = s.resendCount + 1
            let reason = s.sendReason
            let timedOut = s.askTimedOut
            clearSend(&s)
            s.phase = .queued
            s.sendReason = reason
            s.askTimedOut = timedOut
            s.resendCount = resends
        }
    }

    /// If a send is due, mark it sent and return the text to hand Claude Code.
    public static func claimDelivery(_ s: inout SessionState, via channel: DeliveryChannel, config: Config, nonce: String, now: Date) -> String? {
        guard s.guarded, s.phase == .queued else { return nil }
        s.phase = .sent
        s.sentAt = now
        s.sentNonce = nonce
        s.sentVia = channel
        s.sentTokens = s.tokens
        s.confirmedAt = nil
        s.stopsSinceSent = 0
        return deliveryText(config.message, nonce: nonce, reason: s.sendReason ?? .yes,
                            askedAt: s.askedTokens ?? s.tokens, laterAt: config.laterAt,
                            timedOutAfter: s.askTimedOut == true ? config.autoYesSeconds : nil)
    }

    /// The text Claude sees. Claude Code presents a woken session's message as a background event
    /// ("not user input"), so it says what relays it and why, then quotes the user's own words.
    /// The tag lets the hook confirm the message reached the transcript.
    public static func deliveryText(_ message: String, nonce: String, reason: SendReason, askedAt: Int, laterAt: Int, timedOutAfter: Int? = nil) -> String {
        let relay = "Context Guard (a Claude Code hook the user installed to watch context size) is relaying a message the user chose to send"
        let why: String
        switch reason {
        case .yes where timedOutAfter != nil:
            why = "its popup asked them when this session reached \(Format.tokens(askedAt)) tokens, and they set it to send by itself when they don't answer within \(Format.seconds(timedOutAfter ?? 0))"
        case .yes: why = "they clicked Yes on its popup when this session reached \(Format.tokens(askedAt)) tokens"
        case .later: why = "they set it to go out when this session reached \(Format.tokens(laterAt)) tokens, and it just did"
        case .manual: why = "they chose Compact Now in its menu"
        }
        return "\(relay): \(why). Their message: \u{201C}\(message)\u{201D} [\(nonce)]"
    }

    public static func makeNonce() -> String {
        "cg-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    }

    /// Whether this session keeps a background Stop hook after each turn. Every guarded session does,
    /// in every phase and with Context Guard Off, because Compact Now can come at any time and
    /// the waiter is the only way to reach a session that's sitting idle.
    public static func wantsWaiter(_ s: SessionState) -> Bool {
        s.guarded && !s.ended
    }
}
