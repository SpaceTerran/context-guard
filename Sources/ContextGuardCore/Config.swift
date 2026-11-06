import Foundation

/// Settings shared by the app (writer) and the hook (reader).
public struct Config: Codable, Equatable, Sendable {
    public static let schema = 1
    public static let defaultMessage = "I'm about to compact this conversation. Check in, push, or save anything else you need before I complete compaction, and then I will let you know when to resume."
    public static let defaultAskAt = 300_000
    public static let defaultLaterAt = 500_000
    public static let defaultAutoYesSeconds = 60
    public static let defaultContinueMessage = "continue now"

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

    public init() {}

    public init(enabled: Bool = true, askAt: Int = Config.defaultAskAt, laterAt: Int = Config.defaultLaterAt,
                message: String = Config.defaultMessage, autoYesSeconds: Int = Config.defaultAutoYesSeconds,
                continueMessage: String = Config.defaultContinueMessage, enabledAt: Date? = nil) {
        self.enabled = enabled
        self.askAt = askAt
        self.laterAt = laterAt
        self.message = message
        self.autoYesSeconds = autoYesSeconds
        self.continueMessage = continueMessage
        self.enabledAt = enabledAt
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
    }

    /// Values the rules can rely on: thresholds positive and ordered, messages never empty.
    public var normalized: Config {
        var c = self
        c.askAt = max(1_000, c.askAt)
        if c.laterAt <= c.askAt { c.laterAt = c.askAt + 100_000 }
        if c.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.message = Config.defaultMessage }
        c.autoYesSeconds = min(max(0, c.autoYesSeconds), 3_600)
        if c.continueMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.continueMessage = Config.defaultContinueMessage }
        return c
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
}
