import Foundation

/// Settings shared by the app (writer) and the hook (reader).
public struct Config: Codable, Equatable, Sendable {
    public static let schema = 1
    public static let defaultMessage = "I'm about to compact this conversation. Check in, push, or save anything else you need before I complete compaction, and then I will let you know when to resume."
    public static let defaultAskAt = 300_000
    public static let defaultLaterAt = 500_000
    public static let defaultAutoYesSeconds = 60
    public static let defaultContinueMessage = "continue now"
    public static let defaultCodexAskPercent = 60
    public static let defaultCodexLaterPercent = 80
    /// Codex compacts by itself at about 95% of a session's window (90% of the model's), and Wait
    /// keeps a tenth of the window as room for the save, so Wait goes up to 84%. Asking comes at
    /// least 5 points before it.
    public static let codexLaterPercentRange = 15...84
    public static let codexAskPercentRange = 10...79
    /// Most Codex models' window, as sessions report it: the example Settings shows.
    public static let typicalCodexWindow = 258_400

    public var schemaVersion: Int = Config.schema
    public var enabled: Bool = true
    /// Ask once a session's context reaches this many tokens.
    public var askAt: Int = Config.defaultAskAt
    /// "Wait" compacts by itself once the session reaches this many tokens.
    public var laterAt: Int = Config.defaultLaterAt
    /// Sent first, as your words, so the session saves its work before it's compacted.
    public var message: String = Config.defaultMessage
    /// An unanswered question counts as Yes after this many seconds (0: it waits for an answer).
    public var autoYesSeconds: Int = Config.defaultAutoYesSeconds
    /// Sent as your words once the compaction is done.
    public var continueMessage: String = Config.defaultContinueMessage
    /// When Context Guard was last turned on. A question's countdown never starts before this, so
    /// turning it back on doesn't answer an old question at once. nil (a config from before the
    /// countdown existed) holds every countdown until the app stamps it.
    public var enabledAt: Date?
    /// Codex sessions ask once their context reaches this share of the session's own window.
    public var codexAskPercent: Int = Config.defaultCodexAskPercent
    /// For Codex sessions, "Wait" sends once the context reaches this share of the window.
    public var codexLaterPercent: Int = Config.defaultCodexLaterPercent

    public init() {}

    public init(enabled: Bool = true, askAt: Int = Config.defaultAskAt, laterAt: Int = Config.defaultLaterAt,
                message: String = Config.defaultMessage, autoYesSeconds: Int = Config.defaultAutoYesSeconds,
                continueMessage: String = Config.defaultContinueMessage, enabledAt: Date? = nil,
                codexAskPercent: Int = Config.defaultCodexAskPercent, codexLaterPercent: Int = Config.defaultCodexLaterPercent) {
        self.enabled = enabled
        self.askAt = askAt
        self.laterAt = laterAt
        self.message = message
        self.autoYesSeconds = autoYesSeconds
        self.continueMessage = continueMessage
        self.enabledAt = enabledAt
        self.codexAskPercent = codexAskPercent
        self.codexLaterPercent = codexLaterPercent
    }

    // Missing or wrong-typed keys fall back to defaults instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? d.schemaVersion
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        askAt = (try? c.decode(Int.self, forKey: .askAt)) ?? d.askAt
        laterAt = (try? c.decode(Int.self, forKey: .laterAt)) ?? d.laterAt
        message = (try? c.decode(String.self, forKey: .message)) ?? d.message
        autoYesSeconds = (try? c.decode(Int.self, forKey: .autoYesSeconds)) ?? d.autoYesSeconds
        continueMessage = (try? c.decode(String.self, forKey: .continueMessage)) ?? d.continueMessage
        enabledAt = try? c.decode(Date.self, forKey: .enabledAt)
        codexAskPercent = (try? c.decode(Int.self, forKey: .codexAskPercent)) ?? d.codexAskPercent
        codexLaterPercent = (try? c.decode(Int.self, forKey: .codexLaterPercent)) ?? d.codexLaterPercent
    }

    /// Values the rules can rely on: thresholds positive and ordered, messages never empty.
    public var normalized: Config {
        var c = self
        c.askAt = max(1_000, c.askAt)
        if c.laterAt <= c.askAt { c.laterAt = c.askAt + 100_000 }
        if c.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.message = Config.defaultMessage }
        c.autoYesSeconds = min(max(0, c.autoYesSeconds), 3_600)
        if c.continueMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.continueMessage = Config.defaultContinueMessage }
        let ask = Config.codexAskPercentRange, later = Config.codexLaterPercentRange
        c.codexAskPercent = min(max(ask.lowerBound, c.codexAskPercent), ask.upperBound)
        c.codexLaterPercent = min(max(c.codexAskPercent + 5, c.codexLaterPercent), later.upperBound)
        return c
    }

    /// The settings as they apply to one session. Claude Code's thresholds are the token counts
    /// set. Codex's are shares of the session's own window, kept below the point where Codex
    /// compacts by itself. A Codex session whose window isn't known yet keeps the token counts;
    /// it isn't guarded until its window is known.
    public func resolved(for s: SessionState) -> Config {
        guard s.hostKind == .codex, let window = s.codex?.window, window > 0 else { return self }
        var c = self
        c.askAt = window * codexAskPercent / 100
        c.laterAt = window * codexLaterPercent / 100
        if let itself = s.codex?.compactsItselfAt {
            // Room before Codex's own compaction, which would cut the save short. Codex compacts
            // when the next request would pass its limit, and one tool result can add tens of
            // thousands of tokens, so the room is a tenth of the window.
            c.laterAt = min(c.laterAt, itself - window / 10)
        }
        c.askAt = max(1_000, min(c.askAt, c.laterAt - window / 20))
        c.laterAt = max(c.laterAt, c.askAt + 1_000)
        return c
    }

    /// Where a Codex session with this window would ask and, told to wait, compact (Settings'
    /// example).
    public func codexThresholds(window: Int = Config.typicalCodexWindow) -> (askAt: Int, laterAt: Int) {
        var s = SessionState(sessionId: "example", host: .codex, now: Date(timeIntervalSince1970: 0))
        s.codex = CodexFacts(window: window)
        let r = resolved(for: s)
        return (r.askAt, r.laterAt)
    }

    /// Turn Context Guard on or off. Turning it on restarts every question's countdown.
    public mutating func setEnabled(_ on: Bool, now: Date) {
        if on && (!enabled || enabledAt == nil) { enabledAt = now }
        enabled = on
    }

    public static func load(_ paths: Paths) -> Config {
        (FileIO.readJSON(Config.self, from: paths.configFile) ?? Config()).normalized
    }

    public func save(_ paths: Paths) throws {
        try paths.ensureDirectories()
        try FileIO.writeJSON(self, to: paths.configFile)
    }

    /// Saves the settings, normalized, and reads the file back. nil once the file holds them;
    /// otherwise why not, for Settings to show.
    public func saveConfirmed(_ paths: Paths) -> String? {
        let saved = normalized
        do {
            try saved.save(paths)
            // Dates are written in whole seconds, so compare with what the file can hold.
            let expected = try FileIO.decoder().decode(Config.self, from: FileIO.encoder().encode(saved))
            guard FileIO.readJSON(Config.self, from: paths.configFile) == expected else {
                return "the settings file reads back differently."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
