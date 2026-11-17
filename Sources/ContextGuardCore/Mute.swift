import Foundation

/// "Watch This Session" turned off for one tab. Keyed to the Claude process rather than the session,
/// so it lasts through /compact and /clear and ends when the tab closes. A Codex session has no
/// process of its own (the app server runs it), so its mark is keyed to the thread and ends with it;
/// `/new` in Codex starts a new thread, which is watched. A Cursor chat's is keyed to the chat (the
/// app runs every chat) and ends with it. Only the app and CLI write these.
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

    /// Whether you stopped watching the Claude process that runs this session, or this Codex session
    /// or Cursor chat.
    public static func isMuted(_ s: SessionState, _ paths: Paths) -> Bool {
        if let file = sessionFile(s, paths) { return FileManager.default.fileExists(atPath: file.path) }
        guard let pid = s.claudePid, let start = s.claudeStart else { return false }
        return isMuted(pid: pid, start: start, paths)
    }

    /// The mark of a session that has no process of its own: Codex and Cursor's. nil for Claude
    /// Code, whose mark is its process's, and for a tool this build doesn't know.
    static func sessionFile(_ s: SessionState, _ paths: Paths) -> URL? {
        switch s.hostKind {
        case .codex: return paths.codexMuteFile(s.sessionId)
        case .cursor: return paths.cursorMuteFile(s.sessionId)
        case .claude, nil: return nil
        }
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
        if let file = sessionFile(s, paths) {
            if muted {
                try paths.ensureDirectories()
                try FileIO.writeJSON(SessionMute(sessionId: s.sessionId, at: now), to: file)
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

    /// Remove the files of Claude processes that have exited, and of Codex sessions and Cursor chats
    /// that ended or are gone.
    public static func prune(_ paths: Paths, probe: any ProcessProbing) {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.mutedDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let name = file.lastPathComponent
            if name.hasPrefix("codex-") || name.hasPrefix("cursor-"), let c = FileIO.readJSON(SessionMute.self, from: file) {
                if let s = SessionState.load(c.sessionId, paths), !s.ended { continue }
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if let m = FileIO.readJSON(Mute.self, from: file), probe.isRunning(m.pid, startedAt: m.start) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// A Codex session or Cursor chat you stopped watching (`Paths.codexMuteFile`, `cursorMuteFile`).
public struct SessionMute: Codable, Equatable, Sendable {
    /// The Codex thread or Cursor conversation.
    public var sessionId: String
    public var at: Date

    public init(sessionId: String, at: Date) {
        self.sessionId = sessionId
        self.at = at
    }

    // Codex's marks were written before Cursor's, with the thread's name for the key.
    enum CodingKeys: String, CodingKey {
        case sessionId = "threadId"
        case at
    }
}
