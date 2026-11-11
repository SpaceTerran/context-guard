import Foundation

/// What you answered in a popup, for the cycle it asked in. The popup shows progress in place of
/// its buttons until the session moves on.
public struct Reply: Equatable, Sendable {
    public var cycle: Int
    public var action: Answer.Action
    public var at: Date

    public init(cycle: Int, action: Answer.Action, at: Date) {
        self.cycle = cycle
        self.action = action
        self.at = at
    }
}

/// What a question popup shows.
public enum QuestionProgress: Equatable, Sendable {
    case question
    /// Busy: it goes in at the session's next step (the hook for Claude Code, the link for Codex).
    case nextStep
    /// Idle and reachable now (a waiter, or the link): going out now.
    case waking
    /// Idle and out of reach: it goes out when the session next runs, or a terminal shows it.
    case nextRun
    case sent
    case scheduled(at: Int)
    case closed

    /// What a popup shows for a session, given what you answered in it.
    public static func of(_ info: SessionInfo, config: Config, reply: Reply?) -> QuestionProgress {
        // A question left to its countdown went out as a Yes.
        let timedOut = info.state.askTimedOut == true && [.queued, .sent].contains(info.effectivePhase)
        let answered = reply.flatMap { $0.cycle == info.state.cycle ? $0.action : nil } ?? (timedOut ? .yes : nil)
        guard let action = answered else {
            return config.enabled && !info.muted && info.effectivePhase == .asking ? .question : .closed
        }
        switch action {
        case .skip: return .closed
        case .later: return .scheduled(at: info.thresholds(config).laterAt)
        case .yes:
            switch info.effectivePhase {
            case .queued:
                if !info.isIdle { return .nextStep }
                return info.reachableNow ? .waking : .nextRun
            case .sent:
                return info.state.confirmedAt != nil ? .sent : .waking
            default:
                return .closed
            }
        }
    }

    /// How long the popup stays once it shows this; nil stays until something changes.
    public var linger: TimeInterval? {
        switch self {
        case .question: return nil
        case .nextStep, .waking: return 45
        case .nextRun: return 6
        case .sent: return 2.5
        case .scheduled: return 2.5
        case .closed: return 0
        }
    }

    /// The line in place of the buttons once you've answered.
    public func text(_ info: SessionInfo) -> String {
        switch self {
        case .nextStep: return "Asking it to save at its next step…"
        case .waking: return "Asking it to save…"
        case .nextRun: return "Asks it to save \(info.host.whenOutOfReach)"
        case .sent: return "Asked it to save, then it compacts"
        case .scheduled(let at): return "Compacts by itself at \(info.size(at))"
        case .question, .closed: return ""
        }
    }

    /// The mark beside that line.
    public var mark: Mark {
        switch self {
        case .nextStep, .waking: return .working
        case .sent: return .icon(.success, .success)
        case .nextRun, .scheduled: return .icon(.waiting, .muted)
        case .question, .closed: return .none
        }
    }

    public enum Mark: Equatable, Sendable {
        /// Something turning: it's under way.
        case working
        case icon(Symbol, Tone)
        case none
    }
}
