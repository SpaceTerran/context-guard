import Foundation

/// What the link says about its connection to the Codex app (the ChatGPT desktop app).
public struct CodexAppLinkStatus: Codable, Equatable, Sendable {
    /// Joined the app's router: the app is running.
    public var connected: Bool
    /// The app's chats it follows now (open in the app).
    public var chats: Int
    /// Why it only watches the app's chats, if so: an app version that speaks differently.
    public var unsupported: String?
    public var lastError: String?
    /// The model that judges the app's chats, once the app's own app server has run.
    public var judgeModel: String?

    public init(connected: Bool, chats: Int = 0, unsupported: String? = nil, lastError: String? = nil,
                judgeModel: String? = nil) {
        self.connected = connected
        self.chats = chats
        self.unsupported = unsupported
        self.lastError = lastError
        self.judgeModel = judgeModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        chats = (try? c.decode(Int.self, forKey: .chats)) ?? 0
        unsupported = try? c.decode(String.self, forKey: .unsupported)
        lastError = try? c.decode(String.self, forKey: .lastError)
        judgeModel = try? c.decode(String.self, forKey: .judgeModel)
    }
}

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
    /// Its connection to the Codex app, once it has looked for one.
    public var app: CodexAppLinkStatus?

    public init(at: Date, connected: Bool, pid: Int32? = nil, serverVersion: String? = nil, judgeModel: String? = nil,
                observeOnly: String? = nil, lastError: String? = nil, stopped: Bool = false, app: CodexAppLinkStatus? = nil) {
        self.at = at
        self.connected = connected
        self.pid = pid
        self.serverVersion = serverVersion
        self.judgeModel = judgeModel
        self.observeOnly = observeOnly
        self.lastError = lastError
        self.stopped = stopped
        self.app = app
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
        app = try? c.decode(CodexAppLinkStatus.self, forKey: .app)
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

    /// The link is running and has joined the Codex app.
    public func isAppUp(now: Date) -> Bool { app?.connected == true && isRunning(now: now) }

    /// The link is running and connected to where a session is open: the Codex app for the
    /// app's chats, the app server for a terminal's.
    public func isUp(for surface: CodexSurface?, now: Date) -> Bool {
        surface == .app ? isAppUp(now: now) : isUp(now: now)
    }

    /// Where the link stands, as Settings shows it.
    public enum State: Equatable, Sendable {
        case notRunning
        /// Running, not connected: no Codex terminal lately or the app server isn't up, and the
        /// Codex app isn't running.
        case waiting
        case connected
        /// Connected, but this Codex lacks something it needs to act (why).
        case onlyWatching(String)
    }

    /// nil (no file) reads as not running. Connected to the app server or the Codex app counts;
    /// either one that can only watch says why.
    public static func state(_ link: CodexLinkStatus?, now: Date) -> State {
        guard let link, link.isRunning(now: now) else { return .notRunning }
        let app = link.app?.connected == true ? link.app : nil
        guard link.connected || app != nil else { return .waiting }
        let why = (link.connected ? link.observeOnly : nil) ?? app?.unsupported
        return why.map(State.onlyWatching) ?? .connected
    }
}
