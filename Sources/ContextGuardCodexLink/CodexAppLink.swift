import ContextGuardCore
import Foundation

/// `context-guard codex`'s connection to the Codex app (the ChatGPT desktop app): Context Guard's
/// rules for the chats you have open there. It joins the app's router as one more client and
/// follows each chat Codex has loaded (`thread-writer-locks`); the app window that has a chat open
/// (its owner) streams the chat's state to it: working or not, its folder, its rollout. Sizes and
/// turns come from the rollout, as for a terminal's session. What `CodexRunner` decides goes to the
/// owner, the way the app's other windows send it (a prompt, a message into the running turn, a
/// compaction), and the app shows it as its own. The judge runs on an app server of the app's own
/// Codex, on the app's sign-in. It never answers anyone's requests and never touches the app's
/// windows.
public final class CodexAppLink: @unchecked Sendable {
    public struct Options: Sendable {
        /// Only chats in this folder or below (live tests).
        public var onlyCwd: String?
        public var pass: TimeInterval = 1
        /// How long the owner has to answer a request (the router gives up then too).
        public var callTimeout: TimeInterval = 10
        public var judgeTimeout: TimeInterval = CodexJudge.timeout
        /// Between tries while no app answers.
        public var retry: TimeInterval = 5
        /// A chat Codex has loaded that nobody streams yet is asked for again this often. The app
        /// starts streaming a chat once it opens it.
        public var askAgain: TimeInterval = 30
        /// The app server for judging and settings stops after this long with no chat open.
        public var serverIdle: TimeInterval = 300
        /// After it failed to start, it's tried again this much later.
        public var serverRetry: TimeInterval = 60
        public var configRefresh: TimeInterval = 60
        /// At most this many judges at once.
        public var judges = 2
        /// Each chat's work runs on the calling thread (tests).
        public var inline = false

        public init(onlyCwd: String? = nil) {
            self.onlyCwd = onlyCwd
        }
    }

    /// A chat the link follows.
    struct Chat {
        var state = CodexAppThreadState()
        /// The client streaming it to the link: the app window that has it open.
        var owner: String?
        /// When the link last asked to follow it.
        var askedAt: Date?
    }

    /// The app server of the app's own Codex, for the judge and for Codex's settings.
    final class Server: @unchecked Sendable {
        let daemon: CodexDaemon
        let waiters: TurnWaiters
        let model: String?
        var configs: [String: (facts: CodexConfigFacts, at: Date)] = [:]

        init(daemon: CodexDaemon, waiters: TurnWaiters, model: String?) {
            self.daemon = daemon
            self.waiters = waiters
            self.model = model
        }
    }

    public let paths: Paths
    let runner: CodexRunner
    let connector: CodexAppConnecting
    let launcher: CodexAppServerLaunching
    /// Codex's folder: its `thread-writer-locks`, `sessions` and `archived_sessions`.
    let codexHome: String
    let drivers: CodexDrivers
    let options: Options
    let clock: @Sendable () -> Date
    let log: CodexLinkLog
    /// An empty folder outside any project, so the judge reads no AGENTS.md.
    let judgeFolder: URL
    /// Runs when what `status` says changes (the link writes `codex-link.json`).
    public var onStatusChange: (@Sendable () -> Void)?
    private let onlyCwd: String?
    private let workers: SessionWorkers<CodexThreadLook>
    private let judgeSlots: DispatchSemaphore
    private let wake = DispatchSemaphore(value: 0)
    private let serverStart = NSLock()

    private let lock = NSLock()
    private var chats: [String: Chat] = [:]
    /// Chats the app said it archived, until it says it unarchived them.
    private var archived: Set<String> = []
    private var connected = false
    private var connectionClosed = false
    private var closingItself = false
    private var generation = 0
    private var hostExecutable: String?
    /// The app speaks another version of something the link reads: from now on it only watches.
    private var unsupported: String?
    private var lastError: String?
    private var server: Server?
    /// The model the app's own app server picked to judge with, kept while it's stopped.
    private var judgeModel: String?
    private var serverFailedAt: Date?
    private var noChatsSince: Date?
    private var stopped = false

    public init(paths: Paths, connector: CodexAppConnecting, launcher: CodexAppServerLaunching, codexHome: String,
                drivers: CodexDrivers, options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() },
                log: CodexLinkLog? = nil, judgeFolder: URL = CodexLink.defaultJudgeFolder) {
        self.paths = paths
        self.runner = CodexRunner(paths: paths, clock: clock)
        self.connector = connector
        self.launcher = launcher
        self.codexHome = codexHome
        self.drivers = drivers
        self.options = options
        self.clock = clock
        self.log = log ?? CodexLinkLog(url: nil)
        self.judgeFolder = judgeFolder
        self.onlyCwd = options.onlyCwd.map { CodexAttachment.resolved(($0 as NSString).expandingTildeInPath) }
        self.workers = SessionWorkers(label: "codex-app-link", inline: options.inline)
        self.judgeSlots = DispatchSemaphore(value: max(1, options.judges))
    }

    // MARK: - Running

    /// Runs `run()` on a thread of its own.
    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "codex-app-link"
        thread.start()
    }

    /// Runs until `stop()`: connects whenever the app is running.
    public func run() {
        var announced = false
        while !isStopped {
            let router: CodexAppRouter
            do {
                router = try connector.connect()
            } catch {
                // No app: its chats close after a while.
                if !announced {
                    log.write("the Codex app isn't running (\(describe(error))); looking again every \(Int(options.retry)) s")
                    announced = true
                }
                sweep(now: clock(), except: [], nil)
                stopIdleServer(now: clock())
                sleep(options.retry)
                continue
            }
            announced = false
            let gen = newConnection()
            let connection = CodexAppConnection(transport: router.transport) { [weak self] in self?.handle($0, from: gen) }
            do {
                let id = try connection.start(timeout: options.callTimeout)
                log.write("joined the Codex app (\(router.hostExecutable ?? "its router")) as \(short(id))")
                serve(connection, host: router.hostExecutable)
            } catch {
                note(error: describe(error))
                log.write("couldn't join the Codex app: \(describe(error))")
                connection.close()
                sleep(options.retry)
            }
            lostEveryOwner()
        }
        closeServer()
        log.write("stopped following the Codex app")
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        poke()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func serve(_ connection: CodexAppConnection, host: String?) {
        lock.lock()
        connected = true
        hostExecutable = host
        lastError = nil
        lock.unlock()
        statusChanged()
        while !isStopped, !isClosed {
            pass(connection, now: clock())
            // Many changes at once make one pass.
            _ = wake.wait(timeout: .now() + options.pass)
            while wake.wait(timeout: .now()) == .success {}
        }
        lock.lock()
        closingItself = true
        connected = false
        lock.unlock()
        connection.close()
        statusChanged()
    }

    func poke() { wake.signal() }

    func sleep(_ seconds: TimeInterval) {
        _ = wake.wait(timeout: .now() + seconds)
    }

    func newConnection() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        connectionClosed = false
        closingItself = false
        return generation
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectionClosed
    }

    // MARK: - What the app says

    func handle(_ event: CodexAppEvent, from gen: Int) {
        lock.lock()
        let current = gen == generation
        lock.unlock()
        guard current else { return }
        switch event {
        case .broadcast(let b):
            handle(b)
        case .closed(let why):
            lock.lock()
            connectionClosed = true
            let expected = closingItself
            if !expected { lastError = why }
            lock.unlock()
            if !expected { log.write("disconnected: \(why)") }
            poke()
        }
    }

    /// One broadcast. Runs on the connection's reader: short.
    func handle(_ b: CodexAppBroadcast) {
        if b.isUnknownVersion, let known = CodexAppMethod.broadcast(named: b.method) {
            noteUnsupported("the Codex app sends \(b.method) version \(b.version ?? -1); this Context Guard reads version \(known.version)")
        }
        // The router carries other hosts' chats too (remote ones).
        guard (b.params["hostId"]?.string ?? CodexAppRequests.localHost.string) == CodexAppRequests.localHost.string else { return }
        var notes: [String] = []
        lock.lock()
        switch b.method {
        case CodexAppMethod.streamStateChanged.name:
            guard let id = b.conversationId, let change = b.params["change"] else { break }
            var chat = chats[id] ?? Chat()
            if change["type"]?.string == "snapshot" {
                if chat.owner == nil { notes.append("\(short(id)): open in the Codex app") }
                chat.owner = b.source
                archived.remove(id)
            } else if chat.owner != b.source {
                // A window that had it before.
                break
            }
            if chat.state.apply(change) == .outOfStep {
                // A change went missing: asked for afresh.
                chat.askedAt = nil
                notes.append("\(short(id)): missed a change; asking the app for the chat again")
            }
            chats[id] = chat
        case CodexAppMethod.followingChanged.name:
            // Its owner stopped streaming it: archived, or the app is quitting. (One that starts
            // streaming without being asked sends a snapshot first.)
            guard let id = b.conversationId, b.params["following"]?.bool == false,
                  let owner = chats[id]?.owner, owner == b.source else { break }
            chats[id] = Chat(askedAt: clock())
            notes.append("\(short(id)): no longer open in the Codex app")
        case CodexAppMethod.threadArchived.name:
            guard let id = b.conversationId else { break }
            archived.insert(id)
            if chats[id] != nil { chats[id] = Chat(askedAt: clock()) }
            notes.append("\(short(id)): archived in the Codex app")
        case CodexAppMethod.threadUnarchived.name:
            guard let id = b.conversationId else { break }
            archived.remove(id)
            if chats[id]?.owner == nil { chats[id]?.askedAt = nil }
        case CodexAppMethod.clientStatusChanged.name:
            guard let client = b.params["clientId"]?.string else { break }
            switch b.params["status"]?.string {
            case "disconnected":
                for id in chats.keys.sorted() where chats[id]?.owner == client {
                    chats[id] = Chat(askedAt: clock())
                    notes.append("\(short(id)): its Codex app window went away")
                }
            case "connected":
                // A new window may have chats open: the ones nobody streams are asked for again.
                for id in chats.keys.sorted() where chats[id]?.owner == nil { chats[id]?.askedAt = nil }
            default:
                break
            }
        default:
            break
        }
        lock.unlock()
        for n in notes { log.write(n) }
        poke()
    }

    /// The connection ended: nobody streams anything to the link now.
    func lostEveryOwner() {
        lock.lock()
        chats = [:]
        lock.unlock()
        drivers.setApp([])
    }

    func noteUnsupported(_ why: String) {
        lock.lock()
        let first = unsupported == nil
        if first { unsupported = why }
        lock.unlock()
        guard first else { return }
        log.write("only watching the Codex app's chats from now on: \(why)")
        statusChanged()
    }

    func note(error: String) {
        lock.lock()
        lastError = error
        lock.unlock()
    }

    // MARK: - One look

    /// Follows what Codex has loaded, and looks at every chat the app has open once.
    public func pass(_ connection: CodexAppConnection, now: Date) {
        let live = loadedThreads()
        var ask: [String] = []
        lock.lock()
        for id in live {
            var chat = chats[id] ?? Chat()
            // Nobody streams it yet, or a change went missing: its owner sends it afresh when asked.
            let wanting = chat.owner == nil || !chat.state.isCurrent
            if wanting, chat.askedAt.map({ now.timeIntervalSince($0) >= options.askAgain }) ?? true {
                chat.askedAt = now
                ask.append(id)
            }
            chats[id] = chat
        }
        // Unloaded, and nobody streams it: forgotten until Codex loads it again.
        chats = chats.filter { live.contains($0.key) || $0.value.owner != nil }
        lock.unlock()
        for id in ask {
            // A failure means the connection is gone; `serve` sees that.
            try? connection.broadcast(.followingChanged, params: CodexAppRequests.following(id, true))
        }
        look(now: now, connection)
    }

    /// The chats Codex has loaded, by their writer locks: `thread-writer-locks/<id>.lock`.
    func loadedThreads() -> Set<String> {
        let folder = (codexHome as NSString).appendingPathComponent("thread-writer-locks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return Set(names.compactMap { name -> String? in
            guard name.hasSuffix(".lock") else { return nil }
            let id = String(name.dropLast(".lock".count))
            return Paths.isValidSessionID(id) && !id.hasPrefix(".") ? id : nil
        })
    }

    /// Hands each chat the app has open to the runner, and closes the app's other chats.
    func look(now: Date, _ connection: CodexAppConnection) {
        lock.lock()
        let open = chats.filter { $0.value.owner != nil }
        let actOnNothing = unsupported != nil
        lock.unlock()
        drivers.setApp(Set(open.keys))
        noteChats(open.isEmpty, now: now)
        var looked = Set(open.keys)
        for (id, chat) in open {
            let s = chat.state
            // A terminal shows it: the terminal's connection drives it.
            guard s.isCurrent, !drivers.terminalHas(id) else { continue }
            guard Paths.isValidSessionID(id), !s.ephemeral, let path = s.rolloutPath, wanted(s.cwd) else {
                looked.remove(id)
                continue
            }
            let facts = config(for: s.cwd, now: now)
            schedule(CodexThreadLook(
                threadId: id, path: path, cwd: s.cwd, name: s.title, status: s.status ?? "active", flags: s.activeFlags,
                attached: true, autoCompactAt: facts.autoCompactLimit,
                postTurnCompactPercent: facts.postTurnCompactPercent, onlyWatching: actOnNothing, surface: .app), connection)
        }
        sweep(now: now, except: looked, connection)
    }

    /// The app's chats it doesn't have open now close after a while (`CodexRunner.closedAfter`),
    /// or at once when you archived or deleted them.
    func sweep(now: Date, except open: Set<String>, _ connection: CodexAppConnection?) {
        lock.lock()
        let archived = self.archived
        lock.unlock()
        for s in runner.openSessions() where s.codex?.surface == .app && !open.contains(s.sessionId) && wanted(s.cwd) {
            // A terminal has it now: its connection decides.
            if drivers.terminalHas(s.sessionId) { continue }
            let look = CodexThreadLook(threadId: s.sessionId, status: "notLoaded",
                                       endReason: endReason(s, archived: archived.contains(s.sessionId)))
            if let connection {
                schedule(look, connection)
            } else {
                _ = runner.tick(look)
            }
        }
    }

    /// Archived (the app said so, or its rollout moved to `archived_sessions`), deleted (its
    /// rollout is gone), or neither.
    func endReason(_ s: SessionState, archived: Bool) -> String? {
        if archived { return "archived" }
        guard let path = s.transcriptPath, !FileManager.default.fileExists(atPath: path) else { return nil }
        let name = (path as NSString).lastPathComponent
        let moved = ((codexHome as NSString).appendingPathComponent("archived_sessions") as NSString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: moved) ? "archived" : "deleted"
    }

    func wanted(_ cwd: String?) -> Bool {
        guard let onlyCwd else { return true }
        guard let cwd, !cwd.isEmpty else { return false }
        return PathRules.isSameOrInside(CodexAttachment.resolved(cwd), onlyCwd)
    }

    // MARK: - Each chat in turn

    func schedule(_ look: CodexThreadLook, _ connection: CodexAppConnection) {
        workers.schedule(look.threadId, look) { [self] look, waited in
            var look = look
            // A look that waited takes the chat's state as it is now.
            if waited, look.status != "notLoaded" {
                look = refreshed(look)
            }
            return perform(runner.tick(look), look, connection)
        }
    }

    /// The same look with the chat's state as the app streams it now. A chat no longer open is
    /// treated as busy, so nothing is done to it.
    func refreshed(_ look: CodexThreadLook) -> CodexThreadLook {
        var l = look
        lock.lock()
        let chat = chats[look.threadId]
        lock.unlock()
        guard let chat, chat.owner != nil, chat.state.isCurrent else {
            l.status = "active"
            return l
        }
        l.status = chat.state.status ?? "active"
        l.flags = chat.state.activeFlags
        l.name = chat.state.title ?? l.name
        l.cwd = chat.state.cwd ?? l.cwd
        return l
    }

    enum Sent: Equatable {
        case done
        /// It didn't happen (why).
        case refused(String)
        /// It may or may not have happened (why).
        case unknown(String)
    }

    /// A request to the chat's owner.
    func send(_ method: CodexAppMethod, _ params: JSONValue, to id: String, _ connection: CodexAppConnection) -> Sent {
        lock.lock()
        let owner = chats[id]?.owner
        let unsupported = self.unsupported
        lock.unlock()
        if let unsupported { return .refused(unsupported) }
        guard let owner else { return .refused(CodexAppError.noOwner.description) }
        do {
            _ = try connection.request(method, params: params, to: owner, timeout: options.callTimeout)
            return .done
        } catch let e as CodexAppError {
            switch e {
            case .timeout, .routerClosed:
                return .unknown(e.description)
            case .versionMismatch:
                noteUnsupported("the Codex app speaks another version of \(method.name) than \(method.version)")
                return .refused(e.description)
            case .noOwner, .clientGone:
                lock.lock()
                if chats[id]?.owner == owner { chats[id] = Chat(askedAt: clock()) }
                lock.unlock()
                return .refused(e.description)
            case .failed:
                return .refused(e.description)
            }
        } catch {
            return .unknown(describe(error))
        }
    }

    /// Does what the runner decided. Returns whether to look at the chat again right away.
    func perform(_ command: CodexCommand, _ look: CodexThreadLook, _ connection: CodexAppConnection) -> Bool {
        let id = look.threadId
        switch command {
        case .none:
            return false

        case .deliver(let nonce, let text):
            switch send(.startTurn, CodexAppRequests.startTurn(id, text: text), to: id, connection) {
            case .done:
                log.write("\(short(id)): sent the save message in the Codex app (\(nonce))")
            case .refused(let why):
                runner.refused(threadId: id, nonce: nonce)
                log.write("\(short(id)): the Codex app didn't take the save message: \(why)")
            case .unknown(let why):
                // It may have gone in: the rollout shows it, or it's sent again later.
                log.write("\(short(id)): sending the save message: \(why)")
            }
            return false

        case .steer(let nonce, let text):
            guard let cwd = look.cwd, !cwd.isEmpty else {
                runner.refused(threadId: id, nonce: nonce, midTurn: true)
                return false
            }
            let params = CodexAppRequests.steerTurn(id, messageId: CodexClientID.make(nonce: nonce, kind: "save"), text: text, cwd: cwd)
            switch send(.steerTurn, params, to: id, connection) {
            case .done:
                log.write("\(short(id)): sent the save message into the running turn in the Codex app (\(nonce))")
            case .refused(let why):
                runner.refused(threadId: id, nonce: nonce, midTurn: true)
                log.write("\(short(id)): the Codex app wouldn't take the save message mid-turn, so it goes in when the turn ends: \(why)")
            case .unknown(let why):
                log.write("\(short(id)): sending the save message: \(why)")
            }
            return false

        case .continue(let nonce, let text):
            switch send(.startTurn, CodexAppRequests.startTurn(id, text: text), to: id, connection) {
            case .done:
                log.write("\(short(id)): sent the continue message in the Codex app")
            case .refused(let why):
                log.write("\(short(id)): the Codex app didn't take the continue message: \(why)")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .continueFailed, error: why))
            case .unknown(let why):
                // Never sent twice: a lost one stays unsent.
                log.write("\(short(id)): sending the continue message: \(why)")
            }
            return false

        case .compact(let nonce):
            // Compacting cuts off a turn that's running, so the chat is checked once more first.
            guard refreshed(look).status == "idle" else {
                log.write("\(short(id)): not compacting, it started a turn")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .compactDeferred))
            }
            switch send(.compactThread, CodexAppRequests.compact(id), to: id, connection) {
            case .done:
                log.write("\(short(id)): compacting in the Codex app")
            case .refused(let why):
                log.write("\(short(id)): the Codex app didn't compact: \(why)")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .compactFailed, error: why))
            case .unknown(let why):
                // The rollout shows whether it happened; if not, it's looked at again later.
                log.write("\(short(id)): compacting: \(why)")
            }
            return false

        case .judge(let nonce, let mark, let prompt):
            judgeSlots.wait()
            defer { judgeSlots.signal() }
            let started = clock()
            guard let server = server(now: started) else {
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judgeFailed,
                                               error: "the Codex app's own Codex couldn't be started to judge"))
            }
            guard let model = server.model ?? SessionState.load(id, paths)?.codex?.model else {
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judgeFailed, error: "no model to judge with"))
            }
            let result = CodexJudge.ask(prompt, model: model, cwd: judgeFolder.path,
                                        mcpServers: config(for: judgeFolder.path, now: started).mcpServers,
                                        daemon: server.daemon, waiters: server.waiters, callTimeout: options.callTimeout,
                                        timeout: options.judgeTimeout)
            switch result {
            case .success(let text):
                log.write("\(short(id)): \(model) answered in \(String(format: "%.1f", clock().timeIntervalSince(started))) s: \(text.prefix(160))")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: text))
            case .failure(let e):
                log.write("\(short(id)): the judge didn't answer: \(e)")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judgeFailed, error: e.description))
            }
        }
    }

    // MARK: - The app's own app server

    /// Running, or started now. nil when it can't be: no Codex in the app, or it failed lately.
    func server(now: Date) -> Server? {
        serverStart.lock()
        defer { serverStart.unlock() }
        lock.lock()
        if let server {
            lock.unlock()
            return server
        }
        if let failed = serverFailedAt, now.timeIntervalSince(failed) < options.serverRetry {
            lock.unlock()
            return nil
        }
        let host = hostExecutable
        lock.unlock()

        let waiters = TurnWaiters()
        let daemon: CodexDaemon
        do {
            daemon = try launcher.launch(hostExecutable: host) { [weak self] event in
                waiters.handle(event)
                if case .closed(let why) = event { self?.serverEnded(why) }
            }
        } catch {
            serverFailed(describe(error), now: now)
            return nil
        }
        do {
            let agent = try daemon.initialize(version: CodexLink.version, timeout: options.callTimeout)
            let model = (try? daemon.models(timeout: options.callTimeout)).flatMap(CodexJudge.pickModel)
            let s = Server(daemon: daemon, waiters: waiters, model: model)
            lock.lock()
            server = s
            judgeModel = model
            serverFailedAt = nil
            lock.unlock()
            statusChanged()
            log.write("started the Codex app's own app server (\(agent ?? "codex")); judge: \(model ?? "each chat's own model")")
            return s
        } catch {
            daemon.close()
            serverFailed(describe(error), now: now)
            return nil
        }
    }

    func serverFailed(_ why: String, now: Date) {
        lock.lock()
        serverFailedAt = now
        lock.unlock()
        log.write("couldn't start the Codex app's own app server: \(why)")
    }

    func serverEnded(_ why: String) {
        lock.lock()
        let had = server != nil
        server = nil
        lock.unlock()
        if had { log.write("the Codex app's own app server ended: \(why)") }
    }

    func closeServer() {
        lock.lock()
        let s = server
        server = nil
        lock.unlock()
        s?.daemon.close()
    }

    /// Notes whether the app has chats open; the app server stops after `serverIdle` without one.
    func noteChats(_ none: Bool, now: Date) {
        lock.lock()
        if !none {
            noChatsSince = nil
        } else if noChatsSince == nil {
            noChatsSince = now
        }
        lock.unlock()
        stopIdleServer(now: now)
    }

    func stopIdleServer(now: Date) {
        lock.lock()
        if noChatsSince == nil, chats.allSatisfy({ $0.value.owner == nil }) { noChatsSince = now }
        let idle = noChatsSince.map { now.timeIntervalSince($0) >= options.serverIdle } ?? false
        let s = idle ? server : nil
        if s != nil { server = nil }
        lock.unlock()
        if let s {
            s.daemon.close()
            log.write("stopped the Codex app's own app server: no chat open in the app for \(Int(options.serverIdle)) s")
        }
    }

    /// Codex's settings for a folder, from the app's own app server, read again once a minute.
    /// Codex's defaults when there's no app server.
    func config(for cwd: String?, now: Date) -> CodexConfigFacts {
        guard let server = server(now: now) else { return CodexConfigFacts() }
        let key = cwd ?? ""
        lock.lock()
        let cached = server.configs[key]
        lock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < options.configRefresh { return cached.facts }
        let facts = (try? server.daemon.configFacts(cwd: cwd, timeout: options.callTimeout)) ?? cached?.facts ?? CodexConfigFacts()
        lock.lock()
        server.configs[key] = (facts, now)
        lock.unlock()
        return facts
    }

    // MARK: - Status

    /// The chat as the link follows it.
    func chat(_ id: String) -> Chat? {
        lock.lock()
        defer { lock.unlock() }
        return chats[id]
    }

    public func status(stopped linkStopped: Bool) -> CodexAppLinkStatus {
        lock.lock()
        defer { lock.unlock() }
        return CodexAppLinkStatus(connected: connected && !stopped && !linkStopped,
                                  chats: chats.values.filter { $0.owner != nil }.count,
                                  unsupported: unsupported, lastError: lastError, judgeModel: judgeModel)
    }

    func statusChanged() { onStatusChange?() }

    func describe(_ error: Error) -> String {
        (error as? CodexLinkError)?.description ?? (error as? CodexAppError)?.description ?? "\(error)"
    }

    func short(_ id: String) -> String { String(id.prefix(8)) }
}
