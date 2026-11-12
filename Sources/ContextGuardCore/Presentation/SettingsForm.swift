import Foundation

/// Settings as you edit them: each field as typed, and whether each card's changes are on disk.
/// Settings saves as you type: a change is saved at once when it can be; thresholds that don't
/// make sense aren't saved, and their card says why. Both apps keep one while Settings is open,
/// made fresh from the settings each time it opens.
public struct SettingsForm: Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        /// Claude Code's thresholds, in thousands of tokens.
        case askK, laterK
        /// Codex's thresholds, in percent of a session's window.
        case codexAsk, codexLater
        /// The question's countdown, in seconds.
        case autoYes
        case message, continueMessage

        public var isNumber: Bool { self != .message && self != .continueMessage }
    }

    /// Number fields as typed; 0 while a field doesn't hold a number.
    public private(set) var askK: Int
    public private(set) var laterK: Int
    public private(set) var codexAsk: Int
    public private(set) var codexLater: Int
    public private(set) var autoYes: Int
    public private(set) var message: String
    public private(set) var continueMessage: String

    /// Whether each card's changes are on disk.
    public private(set) var thresholdsSaved = SaveStatus.unchanged
    public private(set) var codexSaved = SaveStatus.unchanged
    public private(set) var countdownSaved = SaveStatus.unchanged
    public private(set) var messageSaved = SaveStatus.unchanged
    public private(set) var continueSaved = SaveStatus.unchanged

    public init(_ c: Config) {
        askK = c.askAt / 1_000
        laterK = c.laterAt / 1_000
        codexAsk = c.codexAskPercent
        codexLater = c.codexLaterPercent
        autoYes = c.autoYesSeconds
        message = c.message
        continueMessage = c.continueMessage
    }

    /// Changes the settings on disk and says why that didn't work, or nil once it did.
    public typealias Save = (_ change: @escaping (inout Config) -> Void) -> String?

    // MARK: Editing

    public func number(_ f: Field) -> Int {
        switch f {
        case .askK: return askK
        case .laterK: return laterK
        case .codexAsk: return codexAsk
        case .codexLater: return codexLater
        case .autoYes: return autoYes
        case .message, .continueMessage: return 0
        }
    }

    public func text(_ f: Field) -> String {
        switch f {
        case .message: return message
        case .continueMessage: return continueMessage
        default: return String(number(f))
        }
    }

    /// Sets a field to what was typed (a number field reads it as a number), and saves what can be
    /// saved. Nothing happens when the value is the same.
    public mutating func set(_ f: Field, typed: String, now: Date = Date(), save: Save) {
        if f.isNumber {
            set(f, number: SettingsText.Field.parse(typed), now: now, save: save)
            return
        }
        guard typed != text(f) else { return }
        if f == .message {
            message = typed
            messageSaved = Self.saved(now, save) { $0.message = typed }
        } else {
            continueMessage = typed
            continueSaved = Self.saved(now, save) { $0.continueMessage = typed }
        }
    }

    /// Sets a number field, and saves what can be saved.
    public mutating func set(_ f: Field, number: Int, now: Date = Date(), save: Save) {
        guard f.isNumber, number != self.number(f) else { return }
        switch f {
        case .askK: askK = number
        case .laterK: laterK = number
        case .codexAsk: codexAsk = number
        case .codexLater: codexLater = number
        case .autoYes: autoYes = number
        case .message, .continueMessage: return
        }
        switch f {
        case .askK, .laterK:
            guard thresholdProblem == nil else { return }
            let (ask, later) = (askK * 1_000, laterK * 1_000)
            thresholdsSaved = Self.saved(now, save) {
                $0.askAt = ask
                $0.laterAt = later
            }
        case .codexAsk, .codexLater:
            guard codexProblem == nil else { return }
            let (ask, later) = (codexAsk, codexLater)
            codexSaved = Self.saved(now, save) {
                $0.codexAskPercent = ask
                $0.codexLaterPercent = later
            }
        case .autoYes:
            let seconds = autoYes
            countdownSaved = Self.saved(now, save) { $0.autoYesSeconds = seconds }
        case .message, .continueMessage:
            return
        }
    }

    /// A number field's − or + button.
    public mutating func step(_ f: Field, up: Bool, showsCodex: Bool, now: Date = Date(), save: Save) {
        guard f.isNumber else { return }
        set(f, number: field(f, showsCodex: showsCodex).stepped(number(f), up: up), now: now, save: save)
    }

    /// Restore Default under a message.
    public mutating func restore(_ f: Field, now: Date = Date(), save: Save) {
        switch f {
        case .message: set(f, typed: Config.defaultMessage, now: now, save: save)
        case .continueMessage: set(f, typed: Config.defaultContinueMessage, now: now, save: save)
        default: return
        }
    }

    public func canRestore(_ f: Field) -> Bool {
        switch f {
        case .message: return message != Config.defaultMessage
        case .continueMessage: return continueMessage != Config.defaultContinueMessage
        default: return false
        }
    }

    private static func saved(_ now: Date, _ save: Save, _ change: @escaping (inout Config) -> Void) -> SaveStatus {
        save(change).map(SaveStatus.notSaved) ?? .saved(now)
    }

    // MARK: What each field and card shows

    /// A number field's label, unit, step and range. The countdown's label depends on whether it
    /// has its own card (once Codex is in the picture).
    public func field(_ f: Field, showsCodex: Bool) -> SettingsText.Field {
        switch f {
        case .askK: return SettingsText.askField
        case .laterK: return SettingsText.laterField
        case .codexAsk: return SettingsText.codexAskField
        case .codexLater: return SettingsText.codexLaterField
        case .autoYes, .message, .continueMessage: return SettingsText.countdownField(showsCodex: showsCodex)
        }
    }

    /// The field is marked as the one to fix.
    public func invalid(_ f: Field) -> Bool {
        switch f {
        case .askK: return SettingsText.askInvalid(askK: askK, laterK: laterK)
        case .laterK: return SettingsText.laterInvalid(askK: askK, laterK: laterK)
        case .codexAsk: return SettingsText.codexAskInvalid(codexAsk)
        case .codexLater: return SettingsText.codexLaterInvalid(ask: codexAsk, later: codexLater)
        case .autoYes, .message, .continueMessage: return false
        }
    }

    public var thresholdProblem: String? { SettingsText.thresholdProblem(askK: askK, laterK: laterK) }
    public var codexProblem: String? { SettingsText.codexProblem(ask: codexAsk, later: codexLater) }

    /// Claude Code's card, once Codex is in the picture.
    public var claudeStatus: SaveStatus { thresholdProblem.map(SaveStatus.notSaved) ?? thresholdsSaved }
    public var claudeNote: SettingsNote {
        SettingsNote(problem: thresholdProblem, else: SettingsText.claudeThresholdsNote(askK: askK, laterK: laterK))
    }

    public var codexStatus: SaveStatus { codexProblem.map(SaveStatus.notSaved) ?? codexSaved }
    public var codexNote: SettingsNote {
        SettingsNote(problem: codexProblem, else: SettingsText.codexThresholdsNote(ask: codexAsk, later: codexLater))
    }

    /// The countdown's own card, once Codex is in the picture.
    public var countdownStatus: SaveStatus { countdownSaved }
    public var countdownNote: SettingsNote { SettingsNote(text: SettingsText.countdownNote(autoYes), tone: .muted) }

    /// The one "When to ask" card before Codex: thresholds and countdown together.
    public var whenToAskStatus: SaveStatus {
        thresholdProblem.map(SaveStatus.notSaved) ?? .latest(thresholdsSaved, countdownSaved)
    }
    public var whenToAskNote: SettingsNote {
        SettingsNote(problem: thresholdProblem, else: SettingsText.whenToAskNote(askK: askK, laterK: laterK, autoYes: autoYes))
    }

    public func status(_ f: Field) -> SaveStatus {
        switch f {
        case .message: return messageSaved
        case .continueMessage: return continueSaved
        case .askK, .laterK: return claudeStatus
        case .codexAsk, .codexLater: return codexStatus
        case .autoYes: return countdownStatus
        }
    }

    /// The note under a message: why it isn't saved, that an empty one sends the default, or what
    /// it's for.
    public func messageNote(_ f: Field) -> SettingsNote {
        let about = f == .message ? Words.Settings.beforeCompactingAbout : Words.Settings.afterCompactingAbout
        let note = SettingsText.messageNote(text(f), status: status(f), about: about)
        return SettingsNote(text: note.text, tone: note.tone)
    }
}

/// A line of text under a Settings card, in a status color.
public struct SettingsNote: Equatable, Sendable {
    public var text: String
    public var tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    /// Why the card's values can't be saved, or else what they do.
    public init(problem: String?, else text: String) {
        self.init(text: problem ?? text, tone: problem == nil ? .muted : .danger)
    }
}
