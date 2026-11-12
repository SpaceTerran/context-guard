import ContextGuardCore
import Darwin
import Foundation

/// `context-guard codex`: keeps Context Guard's rules running for Codex sessions. It connects to the
/// Codex app server while a Codex terminal app runs, looks at each session every second (and when
/// the app server or an answer says something changed), and does what `CodexRunner` decides. It
/// never starts or stops the app server and never follows a session of yours (no subscriptions),
/// so it gets none of your approval requests.
public final class CodexLink: @unchecked Sendable {
    public struct Options: Sendable {
        /// Only sessions in this folder or below (live tests against your real Codex).
        public var onlyCwd: String?
        public var pass: TimeInterval = 1
        public var callTimeout: TimeInterval = 10
        public var judgeTimeout: TimeInterval = CodexJudge.timeout
        /// No Codex terminal app this long: let the connection go until one starts.
        public var idleDisconnect: TimeInterval = 300
        public var backoff: [TimeInterval] = [1, 2, 5, 10, 30]
        /// How long an app server must have been there before the link connects: Codex names every
        /// session on a server after its first client, and a server that just started belongs to the
        /// terminal that started it, which connects within a second or so.
        public var newServerWait: TimeInterval = 10
        public var configRefresh: TimeInterval = 60
        /// At most this many judges at once.
        public var judges = 2
        /// Each session's work runs on the calling thread (tests).
        public var inline = false

        public init(onlyCwd: String? = nil) {
            self.onlyCwd = onlyCwd
        }
    }

    public static let version = "1"

    final class Worker: @unchecked Sendable {
        let queue: DispatchQueue
        var busy = false
        var pending: CodexThreadLook?

        init(_ id: String) {
            queue = DispatchQueue(label: "codex-link.\(id)")
        }
    }

    public let paths: Paths
    let runner: CodexRunner
    let connector: CodexConnecting
    let terminals: CodexTerminalProbing
    let options: Options
    let clock: @Sendable () -> Date
    let log: CodexLinkLog
    let waiters = TurnWaiters()
    /// An empty folder outside any project, so the judge reads no AGENTS.md.
    let judgeFolder: URL
    private let onlyCwd: String?
    private let judgeSlots: DispatchSemaphore
    private let wake = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var workers: [String: Worker] = [:]
    private var configs: [String: (facts: CodexConfigFacts, at: Date)] = [:]
    private var connected = false
    private var connectionClosed = false
    /// Counts connections, so a late event from an old one can't touch the one after it.
    private var generation = 0
    /// The link is closing the connection itself: its end isn't an error.
    private var closingItself = false
    private var serverVersion: String?
    private var judgeModel: String?
    private var observeOnly: String?
    /// This Codex can't send into a running turn: the save message waits for each turn to end.
    private var noSteer = false
    private var lastError: String?
    private var lastStatusAt: Date?
    private var lastTerminalAt: Date?
    private var stopped = false

    public init(paths: Paths, connector: CodexConnecting, terminals: CodexTerminalProbing = SystemCodexTerminals(),
                options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() }, log: CodexLinkLog? = nil) {
        self.paths = paths
        self.runner = CodexRunner(paths: paths, clock: clock)
        self.connector = connector
        self.terminals = terminals
        self.options = options
        self.clock = clock
        self.log = log ?? CodexLinkLog(url: nil)
        self.judgeSlots = DispatchSemaphore(value: max(1, options.judges))
        self.onlyCwd = options.onlyCwd.map { CodexAttachment.resolved(($0 as NSString).expandingTildeInPath) }
        self.judgeFolder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("context-guard-codex-judge", isDirectory: true)
    }

    // MARK: - Running

    /// Runs until `stop()`.
    public func run() {
        try? paths.ensureDirectories()
        try? FileManager.default.createDirectory(at: judgeFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let watch = FolderWatch(paths.answersDir) { [weak self] in self?.poke() }
        defer { withExtendedLifetime(watch) {} }
        log.write("started (pid \(getpid()))\(onlyCwd.map { ", only sessions in \($0)" } ?? "")")
        var failures = 0
        // Since when the app server has been there, as far as the link knows: since it first saw it,
        // or since its last connection ended (the server may be a new one).
        var serverSince: Date?
        while !isStopped {
            let now = clock()
            let haveTerminal = noteTerminals(terminals.terminals(), now: now)
            let available = connector.available()
            if !available {
                serverSince = nil
            } else if serverSince == nil {
                serverSince = now
            }
            guard available, haveTerminal || recentlyHadTerminal(now) else {
                if !haveTerminal { closeAbandoned() }
                writeStatus(now: now, force: false)
                sleep(options.pass * 2)
                continue
            }
            if let since = serverSince, now.timeIntervalSince(since) < options.newServerWait {
                writeStatus(now: now, force: false)
                sleep(min(options.pass, options.newServerWait - now.timeIntervalSince(since)))
                continue
            }
            do {
                let gen = newConnection()
                let daemon = try connector.connect(onEvent: { [weak self] in self?.handle($0, from: gen) })
                let agent: String?
                do {
                    agent = try daemon.initialize(version: Self.version, timeout: options.callTimeout)
                } catch {
                    close(daemon)
                    throw error
                }
                failures = 0
                serve(daemon, serverVersion: agent)
                serverSince = nil
            } catch {
                note(error: describe(error))
                writeStatus(now: clock(), force: true)
                let delay = options.backoff[min(failures, options.backoff.count - 1)]
                failures += 1
                sleep(delay)
            }
        }
        log.write("stopped")
    }

    /// Says so in `codex-link.json` at once, so nothing waits for the file to go stale, even if the
    /// process ends before `run()` returns.
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        writeStatus(now: clock(), force: true)
        poke()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Connected: one pass a second, or sooner when something changes.
    func serve(_ daemon: CodexDaemon, serverVersion agent: String?) {
        lock.lock()
        connected = true
        serverVersion = agent
        observeOnly = nil
        noSteer = false
        lastError = nil
        lock.unlock()
        let model = (try? daemon.models(timeout: options.callTimeout)).flatMap(CodexJudge.pickModel)
        lock.lock()
        judgeModel = model
        lock.unlock()
        log.write("connected to \(agent ?? "the Codex app server"); judge: \(model ?? "each session's own model")")
        if agent?.hasPrefix(CodexMeta.linkOriginator + "/") == true {
            log.write("the link was this app server's first client, so Codex names its new sessions \(CodexMeta.linkOriginator)")
        }
        writeStatus(now: clock(), force: true)

        while !isStopped, !isClosed {
            let now = clock()
            do {
                try pass(daemon, now: now)
            } catch {
                note(error: describe(error))
                log.write("lost the app server: \(describe(error))")
                break
            }
            if !recentlyHadTerminal(now) {
                log.write("no Codex terminal for \(Int(options.idleDisconnect)) s; disconnecting until one starts")
                break
            }
            writeStatus(now: now, force: false)
            // Many changes at once make one pass.
            _ = wake.wait(timeout: .now() + options.pass)
            while wake.wait(timeout: .now()) == .success {}
        }
        close(daemon)
        lock.lock()
        connected = false
        lock.unlock()
        writeStatus(now: clock(), force: true)
    }

    /// Something changed: look again now.
    func poke() { wake.signal() }

    /// An event from connection `gen`. One from an older connection is dropped.
    func handle(_ event: CodexEvent, from gen: Int) {
        lock.lock()
        let current = gen == generation
        lock.unlock()
        if current { handle(event) }
    }

    /// An event from the connection in use.
    func handle(_ event: CodexEvent) {
        waiters.handle(event)
        switch event {
        case .notification(let method, _):
            if ["thread/status/changed", "thread/started", "thread/closed", "thread/name/updated"].contains(method) { poke() }
        case .request:
            // Only the judge's own threads could ask, and they have no tools.
            break
        case .closed(let why):
            lock.lock()
            connectionClosed = true
            if !closingItself { lastError = why }
            lock.unlock()
            poke()
        }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectionClosed
    }

    /// Lets the connection go. Its end that follows isn't an error.
    func close(_ daemon: CodexDaemon) {
        lock.lock()
        closingItself = true
        lock.unlock()
        daemon.close()
    }

    /// Starts counting a new connection. Returns its number.
    func newConnection() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        connectionClosed = false
        closingItself = false
        return generation
    }

    // MARK: - One look

    /// Looks at every Codex session once and starts what each one needs. Throws when the connection
    /// is gone.
    public func pass(_ daemon: CodexDaemon, now: Date) throws {
        let terms = terminals.terminals()
        noteTerminals(terms, now: now)
        let ids = try daemon.loadedThreadIds(timeout: options.callTimeout)
        var infos: [CodexThreadInfo] = []
        for id in ids {
            do {
                let info = try daemon.readThread(id, timeout: options.callTimeout)
                if !info.ephemeral, info.path != nil, wanted(info.cwd) { infos.append(info) }
            } catch let e as CodexLinkError where e.isRefusal {
                // Gone between the list and the read.
                continue
            }
        }
        let attached = CodexAttachment.attached(threads: infos, terminals: terms)
        let actOnNothing = currentObserveOnly != nil
        let canSteer = !currentNoSteer
        for info in infos {
            let facts = config(for: info.cwd, daemon, now: now)
            schedule(CodexThreadLook(
                threadId: info.id, path: info.path, cwd: info.cwd, name: info.name, status: info.status,
                flags: info.flags, ephemeral: info.ephemeral,
                attached: actOnNothing ? false : attached[info.id],
                autoCompactAt: facts.autoCompactLimit, postTurnCompactPercent: facts.postTurnCompactPercent,
                canSteer: canSteer), daemon)
        }
        // Closed while the link was away, or the app server restarted: they close after a while.
        let loaded = Set(ids)
        for s in runner.openSessions() where !loaded.contains(s.sessionId) && wanted(s.cwd) {
            schedule(CodexThreadLook(threadId: s.sessionId, status: "notLoaded"), daemon)
        }
    }

    /// Not connected and no Codex terminal: its sessions have closed (after `closedAfter`).
    func closeAbandoned() {
        for s in runner.openSessions() where wanted(s.cwd) {
            _ = runner.tick(CodexThreadLook(threadId: s.sessionId, status: "notLoaded"))
        }
    }

    func wanted(_ cwd: String?) -> Bool {
        guard let onlyCwd else { return true }
        guard let cwd, !cwd.isEmpty else { return false }
        let r = CodexAttachment.resolved(cwd)
        return r == onlyCwd || r.hasPrefix(onlyCwd.hasSuffix("/") ? onlyCwd : onlyCwd + "/")
    }

    /// Codex's settings for a folder, read again once a minute.
    func config(for cwd: String?, _ daemon: CodexDaemon, now: Date) -> CodexConfigFacts {
        let key = cwd ?? ""
        lock.lock()
        let cached = configs[key]
        lock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < options.configRefresh { return cached.facts }
        let facts = (try? daemon.configFacts(cwd: cwd, timeout: options.callTimeout)) ?? cached?.facts ?? CodexConfigFacts()
        lock.lock()
        configs[key] = (facts, now)
        lock.unlock()
        return facts
    }

    // MARK: - Each session in turn

    /// One session's work runs in order; a newer look waits for the one being handled.
    func schedule(_ look: CodexThreadLook, _ daemon: CodexDaemon) {
        lock.lock()
        let w = workers[look.threadId] ?? Worker(look.threadId)
        workers[look.threadId] = w
        if w.busy {
            w.pending = look
            lock.unlock()
            return
        }
        w.busy = true
        lock.unlock()
        if options.inline {
            work(w, look, daemon)
        } else {
            w.queue.async { [self] in work(w, look, daemon) }
        }
    }

    func work(_ w: Worker, _ first: CodexThreadLook, _ daemon: CodexDaemon) {
        var next: CodexThreadLook? = first
        var fresh = true
        while true {
            if var look = next {
                // A look that waited is read again first: acting on an old one could compact a
                // session that has started a turn since.
                if !fresh, look.status != "notLoaded" {
                    look = refreshed(look, daemon) ?? look
                }
                let again = perform(runner.tick(look), look, daemon)
                next = again ? look : nil
                fresh = !again
                if again { continue }
            }
            lock.lock()
            if let p = w.pending {
                w.pending = nil
                lock.unlock()
                next = p
                fresh = false
                continue
            }
            w.busy = false
            lock.unlock()
            return
        }
    }

    /// The same look with the session's status as it is now. A session that can't be read is
    /// treated as busy, so nothing is done to it.
    func refreshed(_ look: CodexThreadLook, _ daemon: CodexDaemon) -> CodexThreadLook? {
        var l = look
        guard let info = try? daemon.readThread(look.threadId, timeout: options.callTimeout) else {
            l.status = "active"
            return l
        }
        l.status = info.status
        l.flags = info.flags
        l.name = info.name ?? l.name
        l.path = info.path ?? l.path
        return l
    }

    /// Does what the runner decided. Returns whether to look at the session again right away.
    func perform(_ command: CodexCommand, _ look: CodexThreadLook, _ daemon: CodexDaemon) -> Bool {
        let id = look.threadId
        let t = options.callTimeout
        switch command {
        case .none:
            return false

        case .deliver(let nonce, let text):
            clearOurQueue(id, daemon)
            queueSaveMessage(id, nonce: nonce, text: text, daemon)
            return false

        case .steer(let nonce, let text):
            clearOurQueue(id, daemon)
            let turn: String?
            do {
                turn = try daemon.runningTurnId(threadId: id, timeout: t)
            } catch let e as CodexLinkError where e.isRefusal {
                noteNoSteer(e, "thread/turns/list")
                runner.refused(threadId: id, nonce: nonce, midTurn: true)
                log.write("\(short(id)): couldn't find the running turn, so the save message waits for it to end: \(e)")
                return false
            } catch {
                // Nothing went out: it's tried again on the next look.
                runner.refused(threadId: id, nonce: nonce)
                log.write("\(short(id)): looking for the running turn: \(describe(error))")
                return false
            }
            // The turn ended a moment ago: it goes in as the next prompt instead.
            guard let turn else {
                queueSaveMessage(id, nonce: nonce, text: text, daemon)
                return false
            }
            do {
                try daemon.steer(threadId: id, turnId: turn, text: text, clientId: CodexClientID.make(nonce: nonce, kind: "save"), timeout: t)
                log.write("\(short(id)): sent the save message into the running turn (\(nonce))")
            } catch let e as CodexLinkError where e.isRefusal {
                noteNoSteer(e, "turn/steer")
                runner.refused(threadId: id, nonce: nonce, midTurn: true)
                log.write("\(short(id)): Codex wouldn't take the save message mid-turn, so it goes in when the turn ends: \(e)")
            } catch {
                // It may have gone in: the rollout shows it, or it's sent again once the turn ends.
                log.write("\(short(id)): sending the save message: \(describe(error))")
            }
            return false

        case .continue(let nonce, let text):
            clearOurQueue(id, daemon)
            let clientId = CodexClientID.make(nonce: nonce, kind: "continue")
            do {
                try daemon.addToQueue(threadId: id, text: text, clientId: clientId, timeout: t)
                log.write("\(short(id)): sent the continue message")
                startIfHeld(id, clientId: clientId, daemon)
            } catch let e as CodexLinkError where e.isRefusal {
                noteMissing(e, "thread/queue/add")
                log.write("\(short(id)): Codex refused the continue message: \(e)")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .continueFailed, error: e.description))
            } catch {
                // Never sent twice: a lost one stays unsent.
                log.write("\(short(id)): sending the continue message: \(describe(error))")
            }
            return false

        case .compact(let nonce):
            // Compacting cuts off a turn that's running, so the session is checked once more first.
            guard let now = try? daemon.readThread(id, timeout: t), now.status == "idle" else {
                log.write("\(short(id)): not compacting, it started a turn")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .compactDeferred))
            }
            do {
                try daemon.compact(threadId: id, timeout: t)
                log.write("\(short(id)): compacting")
            } catch let e as CodexLinkError where e.isRefusal {
                noteMissing(e, "thread/compact/start")
                log.write("\(short(id)): Codex refused to compact: \(e)")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .compactFailed, error: e.description))
            } catch {
                // The rollout shows whether it happened; if not, it's looked at again later.
                log.write("\(short(id)): compacting: \(describe(error))")
            }
            return false

        case .judge(let nonce, let mark, let prompt):
            judgeSlots.wait()
            defer { judgeSlots.signal() }
            guard let model = currentJudgeModel ?? SessionState.load(id, paths)?.codex?.model else {
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judgeFailed, error: "no model to judge with"))
            }
            let started = clock()
            // The servers the judge's own folder would load: a project config in the session's
            // folder can add servers that don't exist there, and turning those off fails.
            let result = CodexJudge.ask(prompt, model: model, cwd: judgeFolder.path,
                                        mcpServers: config(for: judgeFolder.path, daemon, now: started).mcpServers,
                                        daemon: daemon, waiters: waiters, callTimeout: t, timeout: options.judgeTimeout)
            switch result {
            case .success(let text):
                log.write("\(short(id)): \(model) answered in \(String(format: "%.1f", clock().timeIntervalSince(started))) s: \(text.prefix(160))")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judged, mark: mark, text: text))
            case .failure(let e):
                noteMissing(e, "thread/start")
                log.write("\(short(id)): the judge didn't answer: \(e)")
                return runner.report(ModReport(sessionId: id, nonce: nonce, kind: .judgeFailed, error: e.description))
            }
        }
    }

    /// The save message as your next prompt: it starts at once between turns, or once the turn
    /// running ends.
    func queueSaveMessage(_ id: String, nonce: String, text: String, _ daemon: CodexDaemon) {
        let clientId = CodexClientID.make(nonce: nonce, kind: "save")
        do {
            try daemon.addToQueue(threadId: id, text: text, clientId: clientId, timeout: options.callTimeout)
            log.write("\(short(id)): sent the save message (\(nonce))")
            startIfHeld(id, clientId: clientId, daemon)
        } catch let e as CodexLinkError where e.isRefusal {
            noteMissing(e, "thread/queue/add")
            runner.refused(threadId: id, nonce: nonce)
            log.write("\(short(id)): Codex refused the save message: \(e)")
        } catch {
            // It may have gone in: the rollout shows it, or it's sent again later.
            log.write("\(short(id)): sending the save message: \(describe(error))")
        }
    }

    /// Takes Context Guard's own messages still waiting in a session's queue out of it (one stuck
    /// after you stopped a turn), so a newer one isn't followed by an old one.
    func clearOurQueue(_ id: String, _ daemon: CodexDaemon) {
        guard let items = try? daemon.queuedItems(threadId: id, timeout: options.callTimeout) else { return }
        for item in items where CodexClientID.isOurs(item.clientUserMessageId) {
            if (try? daemon.removeFromQueue(threadId: id, itemId: item.id, timeout: options.callTimeout)) != nil {
                log.write("\(short(id)): took an older message of ours out of its queue")
            }
        }
    }

    /// Codex holds its queue after you stop a turn (Esc), so a message added between turns waits
    /// there, and the terminal doesn't show it. Ours is started when nothing of yours waits ahead
    /// of it: you agreed to it after stopping. Yours ahead of it stay held for you to send, and
    /// ours runs after them.
    func startIfHeld(_ id: String, clientId: String, _ daemon: CodexDaemon) {
        let t = options.callTimeout
        guard let items = try? daemon.queuedItems(threadId: id, timeout: t),
              let at = items.firstIndex(where: { $0.clientUserMessageId == clientId }) else { return }
        guard !items[..<at].contains(where: { !CodexClientID.isOurs($0.clientUserMessageId) }) else {
            log.write("\(short(id)): Codex is holding its queue; ours waits behind yours")
            return
        }
        // A turn that started since takes it from the queue by itself.
        guard let info = try? daemon.readThread(id, timeout: t), info.status == "idle" else { return }
        do {
            try daemon.startQueued(threadId: id, itemId: items[at].id, timeout: t)
            log.write("\(short(id)): Codex was holding its queue; started ours")
        } catch {
            // Left queued: it runs when the queue moves, or counts as lost and goes again.
            log.write("\(short(id)): starting ours from the queue: \(describe(error))")
        }
    }

    /// A method this Codex doesn't have: from now on the link only watches.
    func noteMissing(_ error: CodexLinkError, _ method: String) {
        guard error.isMissingMethod else { return }
        lock.lock()
        let first = observeOnly == nil
        if first { observeOnly = "this Codex has no \(method)" }
        lock.unlock()
        if first {
            log.write("only watching from now on: this Codex has no \(method)")
            writeStatus(now: clock(), force: true)
        }
    }

    /// A Codex without what sending into a running turn takes: from now on the save message waits
    /// for each turn to end.
    func noteNoSteer(_ error: CodexLinkError, _ method: String) {
        guard error.isMissingMethod else { return }
        lock.lock()
        let first = !noSteer
        noSteer = true
        lock.unlock()
        if first { log.write("this Codex has no \(method): the save message waits for each turn to end") }
    }

    var currentNoSteer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return noSteer
    }

    var currentObserveOnly: String? {
        lock.lock()
        defer { lock.unlock() }
        return observeOnly
    }

    var currentJudgeModel: String? {
        lock.lock()
        defer { lock.unlock() }
        return judgeModel
    }

    // MARK: - Status

    @discardableResult
    func noteTerminals(_ terms: [CodexTerminalProcess], now: Date) -> Bool {
        guard !terms.isEmpty else { return false }
        lock.lock()
        lastTerminalAt = now
        lock.unlock()
        return true
    }

    func recentlyHadTerminal(_ now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = lastTerminalAt else { return false }
        return now.timeIntervalSince(at) < options.idleDisconnect
    }

    func note(error: String) {
        lock.lock()
        lastError = error
        lock.unlock()
    }

    /// `codex-link.json`, every `CodexLinkStatus.heartbeat` (and on every change that matters).
    func writeStatus(now: Date, force: Bool) {
        lock.lock()
        if !force, let last = lastStatusAt, now.timeIntervalSince(last) < CodexLinkStatus.heartbeat {
            lock.unlock()
            return
        }
        lastStatusAt = now
        let status = CodexLinkStatus(at: now, connected: connected && !stopped, pid: getpid(), serverVersion: serverVersion,
                                     judgeModel: judgeModel, observeOnly: observeOnly, lastError: lastError, stopped: stopped)
        lock.unlock()
        try? status.save(paths)
    }

    func sleep(_ seconds: TimeInterval) {
        _ = wake.wait(timeout: .now() + seconds)
    }

    func describe(_ error: Error) -> String {
        (error as? CodexLinkError)?.description ?? "\(error)"
    }

    func short(_ id: String) -> String { String(id.prefix(8)) }
}

/// The link's own log (`codex-link.log`), kept under a megabyte by moving it to `.1`.
public final class CodexLinkLog: @unchecked Sendable {
    public static let maxBytes = 1 << 20
    let url: URL?
    let echo: Bool
    private let lock = NSLock()

    public init(url: URL?, echo: Bool = false) {
        self.url = url
        self.echo = echo
    }

    public func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        lock.lock()
        defer { lock.unlock() }
        if echo { FileHandle.standardError.write(Data(text.utf8)) }
        guard let url else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > Self.maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// Calls back when a folder's contents change (an answer file renamed into place).
final class FolderWatch: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?

    init(_ url: URL, _ changed: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib],
                                                            queue: .global(qos: .utility))
        src.setEventHandler(handler: changed)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
