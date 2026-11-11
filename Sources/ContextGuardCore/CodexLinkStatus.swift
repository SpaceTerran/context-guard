import Foundation

/// What `context-guard codex` says about its link to the Codex app server. It rewrites the file
/// every few seconds while it runs; the app, `status` and the session list read it.
public struct CodexLinkStatus: Codable, Equatable, Sendable {
    /// Rewritten at least this often while the link runs.
    public static let heartbeat: TimeInterval = 5
    /// Older than this: the link isn't running.
    public static let stale: TimeInterval = 20

    public var at: Date
    /// Connected to the app server now.
    public var connected: Bool
    public var pid: Int32?
    /// The app server's version (`codex-tui/0.167.1 …`).
    public var serverVersion: String?
    /// The model that judges Codex sessions.
    public var judgeModel: String?
    /// Why it can only watch, not act (a method or field this Codex lacks), if so.
    public var observeOnly: String?
    public var lastError: String?
    /// It was told to stop (and has, or is about to): not running, however recent `at` is.
    public var stopped: Bool

    public init(at: Date, connected: Bool, pid: Int32? = nil, serverVersion: String? = nil, judgeModel: String? = nil,
                observeOnly: String? = nil, lastError: String? = nil, stopped: Bool = false) {
        self.at = at
        self.connected = connected
        self.pid = pid
        self.serverVersion = serverVersion
        self.judgeModel = judgeModel
        self.observeOnly = observeOnly
        self.lastError = lastError
        self.stopped = stopped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        connected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        pid = try? c.decode(Int32.self, forKey: .pid)
        serverVersion = try? c.decode(String.self, forKey: .serverVersion)
        judgeModel = try? c.decode(String.self, forKey: .judgeModel)
        observeOnly = try? c.decode(String.self, forKey: .observeOnly)
        lastError = try? c.decode(String.self, forKey: .lastError)
        stopped = (try? c.decode(Bool.self, forKey: .stopped)) ?? false
    }

    public static func load(_ paths: Paths) -> CodexLinkStatus? {
        FileIO.readJSON(CodexLinkStatus.self, from: paths.codexLinkFile)
    }

    public func save(_ paths: Paths) throws {
        try paths.ensureDirectories()
        try FileIO.writeJSON(self, to: paths.codexLinkFile)
    }

    /// The link is running: it wrote lately and hasn't stopped.
    public func isRunning(now: Date) -> Bool { !stopped && now.timeIntervalSince(at) <= Self.stale }

    /// The link is running and connected to the app server.
    public func isUp(now: Date) -> Bool { connected && isRunning(now: now) }
}
