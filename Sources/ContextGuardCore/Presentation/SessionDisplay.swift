import Foundation

/// What the menu and popups show for one session. Each is worked out from the session and the
/// settings alone, so an app redraws whenever either changes.
extension SessionInfo {
    /// The settings as they apply to this session: Codex's thresholds are shares of its window.
    public func thresholds(_ config: Config) -> Config { config.resolved(for: state) }

    /// Its size in the menu: "302k", or "compacted" until the compaction's record arrives.
    public var tokensText: String {
        state.awaitingCompactionRecord ? "compacted" : Format.tokens(state.tokens)
    }

    /// Its size in a popup's heading: for Codex, its share of the window too.
    public var sizeText: String {
        state.awaitingCompactionRecord ? "compacted" : size(state.tokens)
    }

    /// Its location line. A Codex session's starts with the tool ("Codex · ~/code"); Claude Code
    /// sessions' read as they always have.
    public var toolSubtitle: String {
        guard host == .codex else { return subtitle }
        return subtitle.isEmpty ? host.name : "\(host.name) · \(subtitle)"
    }

    /// Where it stands, the first line of its menu.
    public func statusText(_ config: Config) -> String {
        let c = thresholds(config)
        let ask = size(c.askAt), later = size(c.laterAt)
        if muted, config.enabled, !isSending { return "Not watching this session" }
        switch effectivePhase {
        case .watching:
            return config.enabled ? "Asks at \(ask)" : "Not watching: Context Guard is off"
        case .asking:
            guard config.enabled else { return "Asks again when Context Guard is on" }
            guard config.autoYesSeconds > 0 else { return "Waiting for your answer" }
            return "Waiting for your answer · compacts after \(Format.seconds(config.autoYesSeconds))"
        case .later:
            return config.enabled ? "Compacts by itself at \(later)" : "Waiting for \(later): paused while off"
        case .queued:
            if !isIdle { return "Asking it to save at its next step" }
            return reachableNow ? "Asking it to save…" : "Asks it to save \(host.whenOutOfReach)"
        case .sent:
            guard state.confirmedAt != nil else { return "Asking it to save…" }
            return "Asked it to save at \(size(state.sentTokens ?? state.tokens))"
        case .skipped:
            return "Not asking again until it compacts"
        }
    }

    /// The icon beside its title in the menu.
    public var symbol: Symbol {
        if muted, !isSending { return .notWatching }
        switch effectivePhase {
        case .watching: return .watching
        case .asking: return .asking
        case .later: return .waiting
        case .queued: return .sending
        case .sent: return state.confirmedAt != nil ? .sent : .sending
        case .skipped: return .skipped
        }
    }

    /// The save message is on its way and not yet confirmed: sending again would repeat it.
    public var isSending: Bool {
        effectivePhase == .queued || (state.phase == .sent && state.confirmedAt == nil)
    }

    /// Compact Now is off while one is already under way, since it would ask the session to save
    /// twice.
    public var canCompactNow: Bool {
        !isSending && !(state.followUp?.isActive ?? false)
    }

    /// When an unanswered question sends by itself (the hook's own rule), or nil when it won't.
    public func autoYesDeadline(_ config: Config, now: Date) -> Date? {
        Engine.autoYesDeadline(state, config: config, watched: !muted, now: now)
    }

    /// Where the session stands after its save message, for its menu.
    public func followUpText(_ config: Config, now: Date) -> String? {
        state.followUp.flatMap { FollowUpText.line($0, continueMessage: config.continueMessage, now: now) }
    }

    /// The question's second answer: Wait until it reaches the compact-at size, or Not Now once
    /// it's past that.
    public func deferral(_ config: Config) -> Deferral {
        let laterAt = thresholds(config).laterAt
        return state.tokens < laterAt ? .wait(at: laterAt) : .notNow
    }

    /// The deferral's button: "Wait until 500k", "Wait until 80%" or "Not Now".
    public func label(for d: Deferral) -> String {
        switch d {
        case .wait(let at): return "Wait until \(shortSize(at))"
        case .notNow: return Words.Popup.notNow
        }
    }

    /// The deferral's help in a popup.
    public func help(for d: Deferral) -> String {
        switch d {
        case .wait(let at): return "Compact by itself when this session reaches \(size(at))"
        case .notNow: return Words.Popup.notNowHelp
        }
    }

    /// A popup's heading.
    public var questionHeading: String { "Context at \(sizeText)" }

    /// A popup's question.
    public var questionText: String {
        let base = Words.Popup.question
        // Rare: no background hook is waiting (it timed out), so an idle session hears it on its next
        // turn; a Codex session no terminal shows hears it once one does.
        guard isIdle, !reachableNow else { return base }
        if host == .codex { return base + " No terminal shows it, so it starts when one does." }
        return base + " It's idle, so it starts when it next runs."
    }

    /// The countdown under a popup's question.
    public func countdownText(deadline: Date, now: Date) -> String {
        let left = Int(deadline.timeIntervalSince(now).rounded(.up))
        if left > 0 { return "Compacts in \(Format.seconds(left)) unless you answer" }
        // It goes out at the session's next step, or now if it can be reached.
        guard isIdle, !reachableNow else { return "Starting…" }
        return host == .codex ? "Starts \(host.whenOutOfReach)" : "Starts when this session next runs"
    }
}

/// The question's second answer, besides Compact.
public enum Deferral: Equatable, Sendable {
    /// Compact by itself once the session reaches this size.
    case wait(at: Int)
    /// Past that size already: don't ask again until it compacts.
    case notNow

    public var action: Answer.Action {
        switch self {
        case .wait: return .later
        case .notNow: return .skip
        }
    }
}

/// What the menu shows besides each session.
public enum Display {
    /// Terminal sessions that are running now, largest context first.
    public static func live(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.filter { $0.isLive && $0.state.guarded }
    }

    /// A question waits for an answer: the menu bar icon says so.
    public static func hasQuestion(_ sessions: [SessionInfo], config: Config) -> Bool {
        config.enabled && live(sessions).contains { !$0.muted && $0.effectivePhase == .asking }
    }

    /// The settings at the top of the menu: one line, or one per tool once Codex is in the picture.
    public static func thresholdLines(_ config: Config, showsCodex: Bool) -> [String] {
        let claude = "\(Format.tokens(config.askAt)) · Wait until \(Format.tokens(config.laterAt))"
        guard showsCodex else { return ["Asks at \(claude)"] }
        return ["Claude Code: asks at \(claude)",
                "Codex: asks at \(config.codexAskPercent)% · Wait until \(config.codexLaterPercent)%"]
    }

    /// Menus don't truncate; keep one long title from widening the whole menu.
    public static func shortened(_ s: String, max: Int = 44) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
