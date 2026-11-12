import Foundation

/// What Settings says and checks, apart from how it's drawn: what each field takes, why a value
/// can't be saved, the notes under the cards, and how the installs, judges and Codex link stand.
/// Thresholds are taken as typed (Claude Code's in thousands of tokens, Codex's in percent); 0
/// means the field doesn't hold a number.
public enum SettingsText {
    /// A number field: its label, unit, the step of its − and + buttons, and the values it takes.
    public struct Field: Equatable, Sendable {
        public var label: String
        public var unit: String
        public var step: Int
        public var range: ClosedRange<Int>

        /// What a field holds as typed: a number, or 0 when it doesn't hold one.
        public static func parse(_ typed: String) -> Int {
            max(Int(typed.trimmingCharacters(in: .whitespaces)) ?? 0, 0)
        }

        /// The value after its − or + button: to the step below or above, within the range.
        public func stepped(_ value: Int, up: Bool) -> Int {
            up ? min((value / step + 1) * step, range.upperBound) : max((value - 1) / step * step, range.lowerBound)
        }
    }

    public static let askField = Field(label: Words.Settings.askAt, unit: Words.Settings.kTokens, step: 50, range: 50...10_000)
    public static let laterField = Field(label: Words.Settings.compactAtIfWait, unit: Words.Settings.kTokens, step: 50, range: 50...10_000)
    public static let codexAskField = Field(label: Words.Settings.askAt, unit: Words.Settings.percent, step: 5, range: Config.codexAskPercentRange)
    public static let codexLaterField = Field(label: Words.Settings.compactAtIfWait, unit: Words.Settings.percent, step: 5,
                                              range: Config.codexLaterPercentRange)

    /// The countdown's field: in its own card once Codex is in the picture, else with the thresholds.
    public static func countdownField(showsCodex: Bool) -> Field {
        Field(label: showsCodex ? Words.Settings.compactAfter : Words.Settings.ifYouDontAnswerCompactAfter,
              unit: Words.Settings.seconds, step: 15, range: 0...3_600)
    }

    // MARK: Claude Code's thresholds

    /// What's wrong with the thresholds as typed, or nil when they can be saved.
    public static func thresholdProblem(askK: Int, laterK: Int) -> String? {
        if askK < 1 { return "“Ask at” needs a number, like 300." }
        if laterK < 1 { return "“If you choose Wait, compact at” needs a number, like 500." }
        if laterK <= askK { return "“If you choose Wait, compact at” has to be more than “Ask at”." }
        return nil
    }

    public static func askInvalid(askK: Int, laterK: Int) -> Bool { askK < 1 || laterK <= askK }
    public static func laterInvalid(askK: Int, laterK: Int) -> Bool { laterK < 1 || laterK <= askK }

    /// The note under Claude Code's card once Codex is in the picture.
    public static func claudeThresholdsNote(askK: Int, laterK: Int) -> String {
        "When a session reaches \(askK)k tokens, a popup asks whether to compact it. If you choose Wait, it compacts at \(laterK)k."
    }

    /// The note under the one "When to ask" card before Codex.
    public static func whenToAskNote(askK: Int, laterK: Int, autoYes: Int) -> String {
        let ask = "When a session reaches \(askK)k tokens, a popup asks whether to compact it."
        let answer = autoYes > 0
            ? " If you don't answer within \(Format.seconds(autoYes)), it compacts."
            : " It waits for your answer (0 seconds: it never compacts on its own)."
        return ask + answer + " If you choose Wait, it compacts at \(laterK)k."
    }

    // MARK: Codex's thresholds

    public static func codexAskInvalid(_ ask: Int) -> Bool { !Config.codexAskPercentRange.contains(ask) }

    /// What's wrong with Codex's thresholds as typed, or nil when they can be saved. The same
    /// limits as `Config.normalized`, so what's saved is what's shown.
    public static func codexProblem(ask: Int, later: Int) -> String? {
        let asks = Config.codexAskPercentRange, laters = Config.codexLaterPercentRange
        if ask < 1 { return "Codex's “Ask at” needs a number, like \(Config.defaultCodexAskPercent)." }
        if codexAskInvalid(ask) { return "Codex's “Ask at” has to be from \(asks.lowerBound)% to \(asks.upperBound)%." }
        if later < 1 { return "Codex's “If you choose Wait, compact at” needs a number, like \(Config.defaultCodexLaterPercent)." }
        if later > laters.upperBound {
            return "Codex's “If you choose Wait, compact at” goes up to \(laters.upperBound)%: Codex compacts by itself at about 95%, and saving needs room before that."
        }
        if later < ask + 5 { return "Codex's “If you choose Wait, compact at” has to be at least 5% more than its “Ask at”." }
        return nil
    }

    /// The compact-at field is marked only when "Ask at" itself is fine.
    public static func codexLaterInvalid(ask: Int, later: Int) -> Bool {
        !codexAskInvalid(ask) && codexProblem(ask: ask, later: later) != nil
    }

    /// The note under Codex's card, with what the shares come to in a typical window.
    public static func codexThresholdsNote(ask: Int, later: Int) -> String {
        var c = Config()
        c.codexAskPercent = ask
        c.codexLaterPercent = later
        let t = c.codexThresholds()
        return "When a session reaches \(ask)% of its window, a popup asks whether to compact it. If you choose Wait, it compacts at \(later)%. In a \(Format.tokens(Config.typicalCodexWindow)) window, that's \(Format.tokens(t.askAt)) and \(Format.tokens(t.laterAt))."
    }

    /// The note under the countdown's own card.
    public static func countdownNote(_ autoYes: Int) -> String {
        autoYes > 0
            ? "If you don't answer a popup within \(Format.seconds(autoYes)), it compacts the session, whichever tool it runs in."
            : "A popup waits for your answer, whichever tool the session runs in (0 seconds: it never compacts on its own)."
    }

    // MARK: General

    public static func watchLabel(showsCodex: Bool) -> String {
        showsCodex ? "Watch sessions" : "Watch Claude Code sessions"
    }

    /// Under each tool's card: the judge needs no key of its own.
    public static func signInNote(_ host: SessionHost) -> String {
        "No API key: the judge uses your \(host.name) sign-in."
    }

    public static func onlyWatchingNote(_ why: String) -> String {
        "Only watching, not compacting: \(why). A newer Codex may fix this."
    }

    public static func installed(_ ok: Bool) -> StatusLine {
        ok ? StatusLine(text: "Installed", symbol: .success, tone: .success)
            : StatusLine(text: "Not installed: run \(Words.installer)", symbol: .warning, tone: .warning)
    }

    /// The Codex link's row.
    public static func link(_ state: CodexLinkStatus.State, installed: Bool) -> StatusLine {
        switch state {
        case .connected: return StatusLine(text: "Connected", symbol: .success, tone: .success)
        case .onlyWatching: return StatusLine(text: "Only watching", symbol: .warning, tone: .warning)
        case .waiting: return StatusLine(text: "Waiting for Codex", symbol: .waiting, tone: .muted)
        case .notRunning:
            guard installed else { return Self.installed(false) }
            return StatusLine(text: "Not running: run \(Words.installer)", symbol: .warning, tone: .warning)
        }
    }

    /// Claude Code's judge row.
    public static var claudeJudge: StatusLine {
        StatusLine(text: SessionHost.claude.judgeName, symbol: .success, tone: .success)
    }

    /// Codex's judge row: the model the link picked, the session's own when Codex offers no small
    /// one, or nothing yet until it connects.
    public static func codexJudge(_ model: String?, link: CodexLinkStatus.State) -> StatusLine {
        if let model { return StatusLine(text: model, symbol: .success, tone: .success) }
        switch link {
        case .connected, .onlyWatching: return StatusLine(text: "Each session's own model", symbol: .success, tone: .success)
        case .waiting, .notRunning: return StatusLine(text: "Picked when Codex connects", symbol: .waiting, tone: .muted)
        }
    }

    /// Codex's judge as notes name it, in a sentence.
    public static func codexJudgeName(_ model: String?, link: CodexLinkStatus.State) -> String {
        if let model { return model }
        switch link {
        case .connected, .onlyWatching: return "each session's own model"
        case .waiting, .notRunning: return "a small OpenAI model"
        }
    }

    // MARK: Messages

    /// The note under a message card: why it isn't saved, that an empty one sends the default, or
    /// what it's for.
    public static func messageNote(_ text: String, status: SaveStatus, about: String) -> (text: String, tone: Tone) {
        if case .notSaved(let problem) = status { return ("Not saved: \(problem)", .danger) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (Words.Settings.emptySendsDefault, .warning) }
        return (about, .muted)
    }

    /// Restore Default's help.
    public static func restoreHelp(_ what: String) -> String { "Put back the default \(what)" }

    /// The note under both message cards.
    public static func messagesNote(showsCodex: Bool, codexJudgeName: String) -> String {
        let judge = showsCodex ? "The judge (Haiku for Claude Code, \(codexJudgeName) for Codex)" : "The judge (Haiku)"
        return "Changes save as you type. Both go to the session as your words. \(judge) reads what the session does after the first one; once it has saved and is idle, Context Guard compacts it, then sends the second. If you type in the session first, it leaves the rest to you."
    }
}

/// Where a card's changes stand, shown in its header: Settings saves as you type, and this is how
/// you can tell.
public enum SaveStatus: Equatable, Sendable {
    /// Nothing changed since Settings opened: the card shows what's on disk.
    case unchanged
    /// Changed here, and the file read back holds it.
    case saved(Date)
    /// Changed here but not on disk, and why.
    case notSaved(String)

    /// One header for two settings: a problem first, else the later save.
    public static func latest(_ a: SaveStatus, _ b: SaveStatus) -> SaveStatus {
        switch (a, b) {
        case (.notSaved, _): return a
        case (_, .notSaved): return b
        case (.saved(let x), .saved(let y)): return x >= y ? a : b
        case (.saved, .unchanged): return a
        case (.unchanged, _): return b
        }
    }

    /// The time a save shows: "3:41 PM", as this computer writes times.
    public static let shortTime: @Sendable (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }

    /// The header: "Saved", "Saved 3:41 PM" or "Not saved".
    public var line: StatusLine { line(time: Self.shortTime) }

    public func line(time: (Date) -> String) -> StatusLine {
        switch self {
        case .unchanged: return StatusLine(text: "Saved", symbol: .saved, tone: .muted)
        case .saved(let at): return StatusLine(text: "Saved \(time(at))", symbol: .success, tone: .success)
        case .notSaved: return StatusLine(text: "Not saved", symbol: .warning, tone: .danger)
        }
    }
}
