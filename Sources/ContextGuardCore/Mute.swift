import Foundation

/// "Watch This Session" turned off for one tab. Keyed to the Claude process rather than the session,
/// so it lasts through /compact and /clear and ends when the tab closes. A Codex session has no
/// process of its own (the app server runs it), so its mark is keyed to the thread and ends with it;
/// `/new` in Codex starts a new thread, which is watched. Only the app and CLI write these.
public struct Mute: Codable, Equatable, Sendable {
    public var pid: Int32
    public var start: ProcessStart
    public var at: Date
    /// The session it was turned off from (for display only).
    public var sessionId: String?

    public init(pid: Int32, start: ProcessStart, at: Date, sessionId: String? = nil) {
        self.pid = pid
        self.start = start
        self.at = at
        self.sessionId = sessionId
    }

    /// Whether you stopped watching the Claude process that runs this session, or this Codex session.
    public static func isMuted(_ s: SessionState, _ paths: Paths) -> Bool {
        if s.hostKind == .codex { return FileManager.default.fileExists(atPath: paths.codexMuteFile(s.sessionId).path) }
        guard let pid = s.claudePid, let start = s.claudeStart else { return false }
        return isMuted(pid: pid, start: start, paths)
    }

    public static func isMuted(pid: Int32, start: ProcessStart, _ paths: Paths) -> Bool {
        guard let m = FileIO.readJSON(Mute.self, from: paths.muteFile(pid: pid, start: start)) else { return false }
        return m.pid == pid && m.start == start
    }

    /// Turning watching off for a session whose Claude process isn't known yet.
    public struct UnknownProcess: LocalizedError {
        public var errorDescription: String? {
            "Context Guard doesn't know which Claude process runs this session yet. It will after the session's next turn."
        }
    }

    /// Stop or start watching the Claude process that runs `s`. Stopping throws `UnknownProcess`
    /// when the session hasn't said which process that is.
    public static func set(_ muted: Bool, for s: SessionState, _ paths: Paths, now: Date = Date()) throws {
        if s.hostKind == .codex {
            let file = paths.codexMuteFile(s.sessionId)
            if muted {
                try paths.ensureDirectories()
                try FileIO.writeJSON(CodexMute(threadId: s.sessionId, at: now), to: file)
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        guard let pid = s.claudePid, let start = s.claudeStart else {
            // Without a process there's no mark to remove, so it's already watched.
            if muted { throw UnknownProcess() }
            return
        }
        let file = paths.muteFile(pid: pid, start: start)
        if muted {
            try paths.ensureDirectories()
            try FileIO.writeJSON(Mute(pid: pid, start: start, at: now, sessionId: s.sessionId), to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Remove the files of Claude processes that have exited, and of Codex sessions that ended or
    /// are gone.
    public static func prune(_ paths: Paths, probe: any ProcessProbing) {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.mutedDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let c = FileIO.readJSON(CodexMute.self, from: file), file.lastPathComponent.hasPrefix("codex-") {
                if let s = SessionState.load(c.threadId, paths), !s.ended { continue }
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if let m = FileIO.readJSON(Mute.self, from: file), probe.isRunning(m.pid, startedAt: m.start) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// A Codex session you stopped watching (`Paths.codexMuteFile`).
public struct CodexMute: Codable, Equatable, Sendable {
    public var threadId: String
    public var at: Date

    public init(threadId: String, at: Date) {
        self.threadId = threadId
        self.at = at
    }
}
