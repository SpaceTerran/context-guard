import Foundation

/// Where a session is in its cycle: watching, asking, sending the save message, sent.
public enum Phase: String, Codable, Sendable, CaseIterable {
    /// Below the ask threshold (or re-armed after compaction).
    case watching
    /// Crossed the ask threshold; the popup is waiting for an answer.
    case asking
    /// "Wait until 500k": sends automatically at the later threshold.
    case later
    /// Answered yes (or reached the later threshold); goes out at the next chance.
    case queued
    /// Handed to Claude Code; `confirmedAt` is set once it shows up in the transcript.
    case sent
    /// "Not now" after the later threshold had already passed; nothing more until compaction.
    case skipped
}

public enum SendReason: String, Codable, Sendable {
    case yes, later, manual
}

public enum DeliveryChannel: String, Codable, Sendable {
    /// Added as context after a main-thread step (PostToolBatch).
    case step
    /// Woke the idle session from the background Stop hook.
    case wake
}

public struct Compaction: Codable, Equatable, Sendable {
    public var at: Date
    /// "auto" or "manual", as Claude Code records it.
    public var trigger: String?
    public var preTokens: Int?
    public var postTokens: Int?
    /// The phase it cut short, if the save message was still pending.
    public var interruptedPhase: Phase?

    public init(at: Date, trigger: String?, preTokens: Int?, postTokens: Int?, interruptedPhase: Phase? = nil) {
        self.at = at
        self.trigger = trigger
        self.preTokens = preTokens
        self.postTokens = postTokens
        self.interruptedPhase = interruptedPhase
    }
}

/// Start time of a process. Together with the pid it identifies one process even after pid reuse.
public struct ProcessStart: Codable, Equatable, Sendable {
    public var seconds: Int
    public var microseconds: Int

    public init(seconds: Int, microseconds: Int) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct TranscriptCursor: Codable, Equatable, Sendable {
    public var inode: UInt64
    /// Byte offset just past the last complete line already read.
    public var offset: UInt64

    public init(inode: UInt64, offset: UInt64) {
        self.inode = inode
        self.offset = offset
    }
}

/// Everything known about one session. Only the hook writes this file.
public struct SessionState: Codable, Equatable, Sendable {
    public static let schema = 1

    public var schemaVersion: Int = SessionState.schema
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var title: String?
    /// Claude Code's own name for the session (from its registry).
    public var name: String?

    public var tokens: Int = 0
    public var tokensAt: Date?
    public var updatedAt: Date
    public var lastEvent: String?

    public var claudePid: Int32?
    public var claudeStart: ProcessStart?
    /// A terminal session you drive: popups and delivery apply. Everything else is only tracked.
    public var guarded: Bool = false

    public var phase: Phase = .watching
    /// Increments each time the session starts asking; answers name the cycle they belong to.
    public var cycle: Int = 0
    public var askedAt: Date?
    public var askedTokens: Int?
    public var appliedAnswerId: String?

    public var sendReason: SendReason?
    public var sentAt: Date?
    public var sentNonce: String?
    public var sentVia: DeliveryChannel?
    public var sentTokens: Int?
    public var confirmedAt: Date?
    /// Where the transcript read that confirmed it began: the save message's line is at or after this.
    public var confirmedOffset: UInt64?
    /// The question went unanswered for `autoYesSeconds`, which counts as Yes.
    public var askTimedOut: Bool?
    /// Stops seen since sending without the message appearing in the transcript.
    public var stopsSinceSent: Int = 0
    public var resendCount: Int = 0

    /// The newest background Stop hook waiting on an answer. Older waiters exit when this changes.
    public var waiterToken: String?
    public var waiterPid: Int32?
    public var waiterStart: ProcessStart?
    public var waiterSince: Date?

    public var cursor: TranscriptCursor?
    public var lastCompaction: Compaction?
    /// SessionStart(compact) fires before Claude Code writes the compaction record, so the new size
    /// is unknown until that record (or the next response) shows up.
    public var awaitingCompactionRecord: Bool = false
    /// What happens after the save message: compacting once the session is done saving, then continuing.
    /// Survives the re-arm after the compaction. The Context Guard mod drives it (`ModRunner`).
    public var followUp: FollowUp?

    public var ended: Bool = false
    public var endedAt: Date?
    public var endReason: String?

    public init(sessionId: String, now: Date) {
        self.sessionId = sessionId
        self.updatedAt = now
    }

    public static func load(_ id: String, _ paths: Paths) -> SessionState? {
        guard let s = FileIO.readJSON(SessionState.self, from: paths.stateFile(id)),
              s.schemaVersion == SessionState.schema, s.sessionId == id else { return nil }
        return s
    }

    public func save(_ paths: Paths) throws {
        try FileIO.writeJSON(self, to: paths.stateFile(sessionId))
    }
}

/// Your answer to a popup (or a menu command). Only the app and CLI write this file.
public struct Answer: Codable, Equatable, Sendable {
    public static let schema = 1

    public enum Action: String, Codable, Sendable {
        /// Send the save message now, then compact.
        case yes
        /// Wait until the later threshold, then send.
        case later
        /// Don't send this cycle.
        case skip
    }

    public enum Source: String, Codable, Sendable {
        case popup, menu, cli
    }

    public var schemaVersion: Int = Answer.schema
    public var id: String
    public var cycle: Int
    public var action: Action
    public var source: Source
    public var at: Date

    public init(id: String = UUID().uuidString, cycle: Int, action: Action, source: Source, at: Date) {
        self.id = id
        self.cycle = cycle
        self.action = action
        self.source = source
        self.at = at
    }

    public static func load(_ id: String, _ paths: Paths) -> Answer? {
        guard let a = FileIO.readJSON(Answer.self, from: paths.answerFile(id)), a.schemaVersion == Answer.schema else { return nil }
        return a
    }

    public func save(for sessionId: String, _ paths: Paths) throws {
        try paths.ensureDirectories()
        try FileIO.writeJSON(self, to: paths.answerFile(sessionId))
    }
}
