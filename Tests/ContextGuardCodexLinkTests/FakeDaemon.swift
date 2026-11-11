import ContextGuardCore
import Foundation
@testable import ContextGuardCodexLink

/// The Codex app server, in memory: threads, their queues, compactions, and a judge model that
/// answers. Records every call.
final class FakeDaemon: CodexDaemon, @unchecked Sendable {
    struct Thread {
        var id: String
        var path: String?
        var cwd: String?
        var name: String?
        var status = "idle"
        var flags: [String] = []
        var ephemeral = false
        var originator: String? = "codex-tui"
        var recencyAt: Double = 1_794_355_000
    }

    enum Judge {
        /// `turn/completed` with this final answer.
        case answer(String)
        /// The turn ends this way (`failed`, `interrupted`).
        case ends(String)
        /// Never finishes.
        case silent
    }

    private let lock = NSLock()
    private var threads: [String: Thread] = [:]
    private var order: [String] = []
    private var queues: [String: [JSONValue]] = [:]
    private var paused: Set<String> = []
    private var log: [(method: String, params: JSONValue)] = []
    private var nextId = 1
    private var isClosed = false

    var models: [JSONValue] = [["model": "gpt-5.6-luna", "hidden": false], ["model": "gpt-6-luna", "hidden": false]]
    var config: JSONValue = ["model_auto_compact_token_limit": .null, "mcp_servers": ["docs": ["command": "docs-mcp"]]]
    /// What `config/read` gives for a folder with a project config of its own; `config` elsewhere.
    var projectConfig: [String: JSONValue] = [:]
    var judge: Judge = .answer(#"{"verdict":"ready","reason":"pushed and saved"}"#)
    /// Methods that fail, and how.
    var failing: [String: CodexLinkError] = [:]
    /// Runs on every call, before it's answered (a test changing things mid-pass).
    var onCall: ((String, JSONValue) -> Void)?
    /// The link's event handler.
    var onEvent: (@Sendable (CodexEvent) -> Void)?
    /// Pages this long, to check paging is followed.
    var pageSize = 100

    // MARK: - Setting up

    func add(_ t: Thread) {
        lock.lock(); defer { lock.unlock() }
        if threads[t.id] == nil { order.append(t.id) }
        threads[t.id] = t
    }

    func setStatus(_ id: String, _ status: String, flags: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        threads[id]?.status = status
        threads[id]?.flags = flags
    }

    func unload(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        threads[id] = nil
        order.removeAll { $0 == id }
    }

    /// Queues an item of yours (typed while a turn ran). Returns its id.
    @discardableResult
    func queueYours(_ id: String, text: String = "and the tests") -> String {
        queueItem(id, clientId: UUID().uuidString.lowercased(), text: text)
    }

    /// Queues an item with this client id. Returns its id.
    @discardableResult
    func queueItem(_ id: String, clientId: String, text: String = "an older message") -> String {
        lock.lock(); defer { lock.unlock() }
        let itemId = "q-\(nextId)"
        nextId += 1
        queues[id, default: []].append(["id": .string(itemId), "clientUserMessageId": .string(clientId),
                                        "input": [["type": "text", "text": .string(text)]]])
        return itemId
    }

    /// Codex holds its queue (you pressed Esc).
    func pause(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        paused.insert(id)
    }

    /// The queue's next item starts as a turn: taken out of the queue and returned.
    @discardableResult
    func startNext(_ id: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queues[id], !q.isEmpty else { return nil }
        let item = q.removeFirst()
        queues[id] = q
        threads[id]?.status = "active"
        return item
    }

    // MARK: - Looking

    var calls: [(method: String, params: JSONValue)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func calls(_ method: String) -> [JSONValue] { calls.filter { $0.method == method }.map(\.params) }

    func queue(_ id: String) -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return queues[id] ?? []
    }

    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }

    // MARK: - CodexDaemon

    func call(_ method: String, _ params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        onCall?(method, params)
        lock.lock()
        log.append((method, params))
        lock.unlock()
        if closed { throw CodexLinkError.closed("closed") }
        if let e = failing[method] { throw e }
        let id = params["threadId"]?.string ?? ""
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "initialize":
            return ["userAgent": "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)"]
        case "thread/loaded/list":
            return page(order.filter { threads[$0]?.status != "notLoaded" }.map { .string($0) }, params)
        case "thread/read":
            guard let t = threads[id] else { throw CodexLinkError.rpc(code: -32600, message: "thread not loaded: \(id)") }
            return ["thread": json(t)]
        case "thread/queue/list":
            return page(queues[id] ?? [], params)
        case "thread/queue/add":
            guard threads[id] != nil else { throw CodexLinkError.rpc(code: -32600, message: "thread not found") }
            let item: JSONValue = ["id": .string("q-\(nextId)"), "clientUserMessageId": params["clientUserMessageId"] ?? .null,
                                   "input": params["input"] ?? .null]
            nextId += 1
            queues[id, default: []].append(item)
            // Between turns it starts at once, unless the queue is held.
            if threads[id]?.status == "idle", !paused.contains(id), queues[id]?.count == 1 {
                queues[id] = []
                threads[id]?.status = "active"
            }
            return ["queuedSubmission": item]
        case "thread/queue/delete":
            let item = params["queuedSubmissionId"]?.string
            queues[id]?.removeAll { $0["id"]?.string == item }
            return [:]
        case "thread/queue/start":
            let item = params["queuedSubmissionId"]?.string
            guard var q = queues[id], let at = q.firstIndex(where: { item == nil || $0["id"]?.string == item }) else {
                throw CodexLinkError.rpc(code: -32600, message: "no such queued submission")
            }
            q.remove(at: at)
            queues[id] = q
            paused.remove(id)
            threads[id]?.status = "active"
            return [:]
        case "thread/compact/start":
            guard threads[id] != nil else { throw CodexLinkError.rpc(code: -32600, message: "thread not found") }
            threads[id]?.status = "active"
            return [:]
        case "model/list":
            return page(models, params)
        case "config/read":
            return ["config": params["cwd"]?.string.flatMap { projectConfig[$0] } ?? config]
        case "thread/start":
            let judgeId = "01a1c7f9-0000-7000-8000-\(String(format: "%012d", nextId))"
            nextId += 1
            threads[judgeId] = Thread(id: judgeId, cwd: params["cwd"]?.string, ephemeral: true, originator: "context_guard")
            return ["thread": ["id": .string(judgeId), "ephemeral": true]]
        case "turn/start":
            let turnId = "turn-\(nextId)"
            nextId += 1
            if threads[id]?.ephemeral == true { finishJudge(threadId: id, turnId: turnId) }
            return ["turn": ["id": .string(turnId), "status": "inProgress"]]
        case "thread/unsubscribe":
            threads[id] = threads[id]?.ephemeral == true ? nil : threads[id]
            return [:]
        case "turn/interrupt":
            return [:]
        default:
            throw CodexLinkError.rpc(code: -32600, message: "Invalid request: unknown variant `\(method)`")
        }
    }

    func notify(_ method: String, _ params: JSONValue?) throws {
        lock.lock(); defer { lock.unlock() }
        log.append((method, params ?? .null))
    }

    func close() {
        lock.lock()
        let already = isClosed
        isClosed = true
        lock.unlock()
        if !already { onEvent?(.closed("closed by the link")) }
    }

    /// A new connection to the same app server.
    func reopen() {
        lock.lock(); defer { lock.unlock() }
        isClosed = false
    }

    // MARK: -

    /// The judge's turn ends a moment after it starts, as the app server's does.
    private func finishJudge(threadId: String, turnId: String) {
        let judge = self.judge
        let onEvent = self.onEvent
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
            switch judge {
            case .silent:
                return
            case .answer(let text):
                let item: JSONValue = ["type": "agentMessage", "id": "msg_1", "phase": "final_answer", "text": .string(text)]
                onEvent?(.notification(method: "item/completed", params: ["threadId": .string(threadId), "item": item]))
                onEvent?(.notification(method: "turn/completed", params: [
                    "threadId": .string(threadId),
                    "turn": ["id": .string(turnId), "status": "completed", "items": [["type": "userMessage"], item]],
                ]))
            case .ends(let status):
                onEvent?(.notification(method: "turn/completed", params: [
                    "threadId": .string(threadId),
                    "turn": ["id": .string(turnId), "status": .string(status), "items": [], "error": ["message": "the model refused"]],
                ]))
            }
        }
    }

    private func page(_ all: [JSONValue], _ params: JSONValue) -> JSONValue {
        let from = params["cursor"]?.string.flatMap(Int.init) ?? 0
        let end = min(all.count, from + pageSize)
        return ["data": .array(Array(all[from..<end])), "nextCursor": end < all.count ? .string(String(end)) : .null]
    }

    private func json(_ t: Thread) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(t.id),
            "status": t.status == "active"
                ? ["type": "active", "activeFlags": .array(t.flags.map { .string($0) })]
                : ["type": .string(t.status)],
            "ephemeral": .bool(t.ephemeral),
            "recencyAt": .number(t.recencyAt),
            "path": t.path.map { .string($0) } ?? .null,
        ]
        if let cwd = t.cwd { o["cwd"] = .string(cwd) }
        if let name = t.name { o["name"] = .string(name) }
        if let originator = t.originator { o["originator"] = .string(originator) }
        return .object(o)
    }
}

/// Hands out one daemon.
final class FakeConnector: CodexConnecting, @unchecked Sendable {
    let daemon: FakeDaemon
    var isAvailable = true
    var connects = 0

    init(_ daemon: FakeDaemon) {
        self.daemon = daemon
    }

    func available() -> Bool { isAvailable }

    func connect(onEvent: @escaping @Sendable (CodexEvent) -> Void) throws -> CodexDaemon {
        connects += 1
        daemon.reopen()
        daemon.onEvent = onEvent
        return daemon
    }
}

/// The `codex` processes a test says are running.
final class FakeTerminals: CodexTerminalProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CodexTerminalProcess]

    init(_ list: [CodexTerminalProcess] = []) {
        self.list = list
    }

    func set(_ l: [CodexTerminalProcess]) {
        lock.lock(); defer { lock.unlock() }
        list = l
    }

    func terminals() -> [CodexTerminalProcess] {
        lock.lock(); defer { lock.unlock() }
        return list
    }
}
