import CryptoKit
import Foundation

/// A thread as `thread/read` or `thread/started` describes it.
public struct CodexThreadInfo: Equatable, Sendable {
    public var id: String
    /// Its rollout file. nil for an ephemeral thread.
    public var path: String?
    public var cwd: String?
    public var name: String?
    /// `idle`, `active`, `systemError` or `notLoaded`.
    public var status: String
    public var flags: [String]
    public var ephemeral: Bool
    public var model: String?
    /// Which Codex client started it: `codex-tui` for the terminal app.
    public var originator: String?
    /// When it was last used (Unix seconds).
    public var recencyAt: Double?

    public init(id: String, path: String? = nil, cwd: String? = nil, name: String? = nil, status: String,
                flags: [String] = [], ephemeral: Bool = false, model: String? = nil, originator: String? = nil,
                recencyAt: Double? = nil) {
        self.id = id
        self.path = path
        self.cwd = cwd
        self.name = name
        self.status = status
        self.flags = flags
        self.ephemeral = ephemeral
        self.model = model
        self.originator = originator
        self.recencyAt = recencyAt
    }

    public static func parse(_ v: JSONValue) -> CodexThreadInfo? {
        guard let id = v["id"]?.string, !id.isEmpty else { return nil }
        return CodexThreadInfo(
            id: id,
            path: v["path"]?.string,
            cwd: v["cwd"]?.string,
            name: v["name"]?.string,
            status: v["status"]?["type"]?.string ?? "notLoaded",
            flags: v["status"]?["activeFlags"]?.array?.compactMap(\.string) ?? [],
            // Not saying is read as ephemeral: nothing is done to a thread that may be a helper.
            ephemeral: v["ephemeral"]?.bool ?? true,
            model: v["model"]?.string,
            originator: v["originator"]?.string,
            recencyAt: v["recencyAt"]?.double ?? v["updatedAt"]?.double)
    }
}

public struct CodexQueuedItem: Equatable, Sendable {
    public var id: String
    public var clientUserMessageId: String?

    public init(id: String, clientUserMessageId: String?) {
        self.id = id
        self.clientUserMessageId = clientUserMessageId
    }
}

public struct CodexModelInfo: Equatable, Sendable {
    public var id: String
    public var hidden: Bool

    public init(id: String, hidden: Bool = false) {
        self.id = id
        self.hidden = hidden
    }
}

/// What `config/read` says that matters here.
public struct CodexConfigFacts: Equatable, Sendable {
    /// `model_auto_compact_token_limit`.
    public var autoCompactLimit: Int?
    /// `model_post_turn_compact_threshold_percent`.
    public var postTurnCompactPercent: Int?
    /// The MCP servers configured, by name: the judge turns each one off.
    public var mcpServers: [String]

    public init(autoCompactLimit: Int? = nil, postTurnCompactPercent: Int? = nil, mcpServers: [String] = []) {
        self.autoCompactLimit = autoCompactLimit
        self.postTurnCompactPercent = postTurnCompactPercent
        self.mcpServers = mcpServers
    }

    public static func parse(_ result: JSONValue) -> CodexConfigFacts {
        let config = result["config"] ?? .null
        return CodexConfigFacts(
            autoCompactLimit: config["model_auto_compact_token_limit"]?.int.flatMap { $0 > 0 ? $0 : nil },
            postTurnCompactPercent: config["model_post_turn_compact_threshold_percent"]?.int.flatMap { (1...100).contains($0) ? $0 : nil },
            mcpServers: (config["mcp_servers"]?.object?.keys).map { Array($0).sorted() } ?? [])
    }
}

/// The ids Context Guard gives the messages it queues (`clientUserMessageId`). They all start the
/// same way, so its own items can be told from yours in a thread's queue.
public enum CodexClientID {
    public static let prefix = "c6c6c6c6-"

    /// The same nonce and kind always give the same id.
    public static func make(nonce: String, kind: String) -> String {
        let digest = Array(SHA256.hash(data: Data("context-guard \(kind) \(nonce)".utf8)))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        func part(_ from: Int, _ length: Int) -> Substring {
            let start = hex.index(hex.startIndex, offsetBy: from)
            return hex[start..<hex.index(start, offsetBy: length)]
        }
        return "\(prefix)\(part(0, 4))-8\(part(4, 3))-8\(part(7, 3))-\(part(10, 12))"
    }

    public static func isOurs(_ id: String?) -> Bool { id?.hasPrefix(prefix) == true }
}

extension CodexDaemon {
    /// The handshake. Returns the app server's user agent (`codex-tui/0.167.1 (…)`).
    public func initialize(version: String, timeout: TimeInterval) throws -> String? {
        let result = try call("initialize", [
            "clientInfo": ["name": "context_guard", "title": "Context Guard", "version": .string(version)],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ], timeout: timeout)
        try notify("initialized", nil)
        return result["userAgent"]?.string
    }

    /// Every page of a paged list.
    func pages(_ method: String, _ params: [String: JSONValue], timeout: TimeInterval) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var cursor: JSONValue = .null
        for _ in 0..<50 {
            var p = params
            if !cursor.isNull { p["cursor"] = cursor }
            let result = try call(method, .object(p), timeout: timeout)
            out += result["data"]?.array ?? []
            cursor = result["nextCursor"] ?? .null
            if cursor.isNull || cursor.string?.isEmpty == true { break }
        }
        return out
    }

    public func loadedThreadIds(timeout: TimeInterval) throws -> [String] {
        try pages("thread/loaded/list", [:], timeout: timeout).compactMap(\.string)
    }

    public func readThread(_ id: String, timeout: TimeInterval) throws -> CodexThreadInfo {
        let result = try call("thread/read", ["threadId": .string(id)], timeout: timeout)
        guard let info = CodexThreadInfo.parse(result["thread"] ?? .null) else {
            throw CodexLinkError.protocolError("thread/read gave no thread")
        }
        return info
    }

    public func queuedItems(threadId: String, timeout: TimeInterval) throws -> [CodexQueuedItem] {
        try pages("thread/queue/list", ["threadId": .string(threadId)], timeout: timeout).compactMap { item in
            item["id"]?.string.map { CodexQueuedItem(id: $0, clientUserMessageId: item["clientUserMessageId"]?.string) }
        }
    }

    /// Runs as your next prompt: right away between turns, or once the turn running ends.
    public func addToQueue(threadId: String, text: String, clientId: String, timeout: TimeInterval) throws {
        _ = try call("thread/queue/add", [
            "threadId": .string(threadId),
            "input": [["type": "text", "text": .string(text), "text_elements": []]],
            "clientUserMessageId": .string(clientId),
        ], timeout: timeout)
    }

    /// Starts a queued item now, as Codex does with the next one when a turn ends. Codex holds its
    /// queue after you stop a turn.
    public func startQueued(threadId: String, itemId: String, timeout: TimeInterval) throws {
        _ = try call("thread/queue/start", ["threadId": .string(threadId), "queuedSubmissionId": .string(itemId)], timeout: timeout)
    }

    public func removeFromQueue(threadId: String, itemId: String, timeout: TimeInterval) throws {
        _ = try call("thread/queue/delete", ["threadId": .string(threadId), "queuedSubmissionId": .string(itemId)], timeout: timeout)
    }

    public func compact(threadId: String, timeout: TimeInterval) throws {
        _ = try call("thread/compact/start", ["threadId": .string(threadId)], timeout: timeout)
    }

    public func models(timeout: TimeInterval) throws -> [CodexModelInfo] {
        try pages("model/list", [:], timeout: timeout).compactMap { m in
            (m["model"]?.string ?? m["id"]?.string).map { CodexModelInfo(id: $0, hidden: m["hidden"]?.bool ?? false) }
        }
    }

    public func configFacts(cwd: String?, timeout: TimeInterval) throws -> CodexConfigFacts {
        var params: [String: JSONValue] = [:]
        if let cwd { params["cwd"] = .string(cwd) }
        return CodexConfigFacts.parse(try call("config/read", .object(params), timeout: timeout))
    }
}
