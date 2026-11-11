import Foundation

/// Where Context Guard and Claude Code keep their files.
public struct Paths: Sendable, Equatable {
    /// Context Guard's own folder: config, per-session state, answers.
    public let root: URL
    /// Claude Code's folder (`~/.claude` unless `CLAUDE_CONFIG_DIR` is set).
    public let claudeDir: URL
    /// Claude Code's registry of running sessions (`<claudeDir>/sessions/<pid>.json`).
    public let registryDir: URL

    public init(root: URL, claudeDir: URL, registryDir: URL? = nil) {
        self.root = root
        self.claudeDir = claudeDir
        self.registryDir = registryDir ?? claudeDir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// `CONTEXT_GUARD_HOME` moves Context Guard's folder (tests run against a scratch folder this way).
    /// `CONTEXT_GUARD_REGISTRY` moves the session registry (unit tests only).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        func dir(_ key: String) -> URL? {
            guard let value = env[key], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = dir("CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude", isDirectory: true)
        let root = dir("CONTEXT_GUARD_HOME") ?? claude.appendingPathComponent("context-guard", isDirectory: true)
        return Paths(root: root, claudeDir: claude, registryDir: dir("CONTEXT_GUARD_REGISTRY"))
    }

    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var answersDir: URL { root.appendingPathComponent("answers", isDirectory: true) }
    /// One file per Claude process you stopped watching (`Mute`).
    public var mutedDir: URL { root.appendingPathComponent("muted", isDirectory: true) }
    /// Each session's latest turn start or end, from the mod (`TurnRecord`).
    public var turnsDir: URL { root.appendingPathComponent("turns", isDirectory: true) }

    public func stateFile(_ id: String) -> URL { sessionsDir.appendingPathComponent("\(id).json") }
    public func lockFile(_ id: String) -> URL { sessionsDir.appendingPathComponent("\(id).lock") }
    public func answerFile(_ id: String) -> URL { answersDir.appendingPathComponent("\(id).json") }
    public func turnFile(_ id: String) -> URL { turnsDir.appendingPathComponent("\(id).json") }
    public func muteFile(pid: Int32, start: ProcessStart) -> URL {
        mutedDir.appendingPathComponent("\(pid)-\(start.seconds).json")
    }
    /// A Codex session you stopped watching: keyed to its thread, since no process of its own runs it.
    public func codexMuteFile(_ threadId: String) -> URL { mutedDir.appendingPathComponent("codex-\(threadId).json") }
    /// What `context-guard codex` last said about its link to the Codex app server (`CodexLinkStatus`).
    public var codexLinkFile: URL { root.appendingPathComponent("codex-link.json") }
    /// Held by the running `context-guard codex`, so only one runs.
    public var codexLinkLock: URL { root.appendingPathComponent("codex-link.lock") }
    /// What `context-guard codex` did, newest last (kept under a megabyte, the older part in `.1`).
    public var codexLinkLog: URL { root.appendingPathComponent("codex-link.log") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, sessionsDir, answersDir, mutedDir, turnsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Session ids become file names, so only plain id characters are accepted.
    public static func isValidSessionID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }
}
