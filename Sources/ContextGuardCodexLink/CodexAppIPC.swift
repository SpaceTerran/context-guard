import Foundation

/// The Codex app's own IPC (the ChatGPT desktop app in Codex mode). The app's main process runs a
/// router that every Codex client of yours joins: the app's windows, the IDE extension, and Context
/// Guard. On the Mac it's a Unix socket (`$CODEX_HOME/ipc/ipc.sock`); on Windows the named pipe
/// `\\.\pipe\codex-ipc`. Each message is JSON framed by its length (UInt32, little-endian).
///
/// The app's agent server is a private child of the app that nobody else can reach, but a chat's
/// owner (the app window that has it open) takes requests from followers over this router, the way
/// the app's other windows and the IDE extension drive it: start a turn, steer the running one,
/// compact. The app shows each as its own.
public enum CodexAppIPC {
    /// The largest frame the app reads or writes (256 MiB).
    public static let maxFrameBytes = 0x1000_0000

    /// One message as sent: its length, then its JSON.
    public static func frame(_ message: JSONValue) -> Data {
        let body = message.serialized()
        var out = Data(capacity: 4 + body.count)
        let n = UInt32(body.count)
        out.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)])
        out.append(body)
        return out
    }

    /// What Context Guard calls itself on the router (`initialize`'s `clientType`).
    public static let clientType = "context-guard"

    /// A request to one client (`target`), or to whichever client says it can handle it.
    public static func request(id: String, from clientId: String, _ method: CodexAppMethod, params: JSONValue,
                               to target: String? = nil, timeout: TimeInterval = 10) -> JSONValue {
        var message: [String: JSONValue] = [
            "type": "request", "requestId": .string(id), "sourceClientId": .string(clientId),
            "version": .number(Double(method.version)), "method": .string(method.name), "params": params,
            "timeoutMs": .number((timeout * 1000).rounded()),
        ]
        if let target { message["targetClientId"] = .string(target) }
        return .object(message)
    }

    /// A message to every client.
    public static func broadcast(from clientId: String, _ method: CodexAppMethod, params: JSONValue) -> JSONValue {
        ["type": "broadcast", "method": .string(method.name), "sourceClientId": .string(clientId),
         "version": .number(Double(method.version)), "params": params]
    }

    /// The answer to the router's "can you handle this request?": Context Guard never can, so every
    /// request someone else sends goes to the app.
    public static func cannotHandle(_ requestId: String) -> JSONValue {
        ["type": "client-discovery-response", "requestId": .string(requestId), "response": ["canHandle": false]]
    }
}

/// Reads frames from the bytes as they arrive.
public struct CodexAppFrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    /// The messages now complete. A frame that isn't JSON is skipped; one over the limit throws
    /// `.tooLarge`, since nothing after it can be read.
    public mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data)
        var out: [JSONValue] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= 4 {
            let n = Int(UInt32(buffer[at]) | UInt32(buffer[at + 1]) << 8 | UInt32(buffer[at + 2]) << 16
                | UInt32(buffer[at + 3]) << 24)
            guard n <= CodexAppIPC.maxFrameBytes else { throw CodexLinkError.tooLarge }
            guard buffer.endIndex - at - 4 >= n else { break }
            if let message = try? JSONValue.parse(buffer.subdata(in: (at + 4)..<(at + 4 + n))) {
                out.append(message)
            }
            at += 4 + n
        }
        if at > buffer.startIndex { buffer = buffer.subdata(in: at..<buffer.endIndex) }
        return out
    }
}

/// A method and the version of it this Context Guard speaks. Versions change with app releases; a
/// request in a version the app doesn't speak is refused (`request-version-mismatch`), never misread.
public struct CodexAppMethod: Sendable, Equatable, Hashable {
    public let name: String
    public let version: Int

    public init(_ name: String, _ version: Int) {
        self.name = name
        self.version = version
    }

    // Requests (Codex app 26.1111).
    public static let initialize = CodexAppMethod("initialize", 0)
    public static let ownerDiscovery = CodexAppMethod("thread-owner-discovery", 1)
    public static let startTurn = CodexAppMethod("thread-follower-start-turn", 2)
    public static let steerTurn = CodexAppMethod("thread-follower-steer-turn", 1)
    public static let compactThread = CodexAppMethod("thread-follower-compact-thread", 1)

    // Broadcasts.
    public static let streamStateChanged = CodexAppMethod("thread-stream-state-changed", 13)
    public static let followingChanged = CodexAppMethod("thread-stream-following-changed", 1)
    public static let threadArchived = CodexAppMethod("thread-archived", 2)
    public static let threadUnarchived = CodexAppMethod("thread-unarchived", 1)
    public static let clientStatusChanged = CodexAppMethod("client-status-changed", 0)

    /// The broadcasts Context Guard reads.
    public static let broadcasts: [CodexAppMethod] = [
        streamStateChanged, followingChanged, threadArchived, threadUnarchived, clientStatusChanged,
    ]

    /// The broadcast Context Guard knows by this name, nil for one it doesn't read.
    public static func broadcast(named name: String) -> CodexAppMethod? {
        broadcasts.first { $0.name == name }
    }
}

/// Why a request over the app's router didn't happen.
public enum CodexAppError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Nobody owns that chat: it isn't open in the app.
    case noOwner
    /// The app speaks another version of this request: it has been updated since this Context Guard.
    case versionMismatch
    /// The client it was sent to has gone.
    case clientGone
    /// The router gave up waiting for the owner. It may still happen.
    case timeout
    /// The app is quitting.
    case routerClosed
    /// The owner tried and failed, with its reason.
    case failed(String)

    /// The router's or the owner's error text.
    public init(_ text: String) {
        switch text {
        case "no-client-found": self = .noOwner
        case "request-version-mismatch": self = .versionMismatch
        case "client-not-found", "client-disconnected": self = .clientGone
        case "request-timeout": self = .timeout
        case "server-closed": self = .routerClosed
        default: self = .failed(text)
        }
    }

    public var description: String {
        switch self {
        case .noOwner: return "the chat isn't open in the Codex app"
        case .versionMismatch: return "this version of the Codex app isn't supported yet"
        case .clientGone: return "the Codex app window it was sent to has closed"
        case .timeout: return "the Codex app didn't answer in time"
        case .routerClosed: return "the Codex app is quitting"
        case .failed(let why): return why
        }
    }
}

/// One message from the router.
public enum CodexAppMessage: Equatable, Sendable {
    /// The reply to a request of Context Guard's.
    case response(requestId: String, result: Result<JSONValue, CodexAppError>)
    case broadcast(CodexAppBroadcast)
    /// The router asks whether Context Guard can handle someone's request.
    case discoveryRequest(requestId: String)
    case other

    public init(_ json: JSONValue) {
        switch json["type"]?.string {
        case "response":
            guard let id = json["requestId"]?.string else {
                self = .other
                return
            }
            if json["resultType"]?.string == "success" {
                self = .response(requestId: id, result: .success(json["result"] ?? .null))
            } else {
                self = .response(requestId: id, result: .failure(CodexAppError(json["error"]?.string ?? "an error")))
            }
        case "broadcast":
            guard let method = json["method"]?.string else {
                self = .other
                return
            }
            self = .broadcast(CodexAppBroadcast(
                method: method, source: json["sourceClientId"]?.string, version: json["version"]?.int,
                params: json["params"] ?? .null, targets: json["targetClientIds"]?.array?.compactMap(\.string)))
        case "client-discovery-request":
            guard let id = json["requestId"]?.string else {
                self = .other
                return
            }
            self = .discoveryRequest(requestId: id)
        default:
            self = .other
        }
    }
}

/// A message a client sent to every client, or to some (`targets`).
public struct CodexAppBroadcast: Equatable, Sendable {
    public var method: String
    public var source: String?
    public var version: Int?
    public var params: JSONValue
    /// nil: to every client.
    public var targets: [String]?

    public init(method: String, source: String?, version: Int?, params: JSONValue, targets: [String]?) {
        self.method = method
        self.source = source
        self.version = version
        self.params = params
        self.targets = targets
    }

    /// A broadcast Context Guard reads, sent in another version than the one it knows: the app has
    /// changed how it talks.
    public var isUnknownVersion: Bool {
        guard let known = CodexAppMethod.broadcast(named: method), let version else { return false }
        return version != known.version
    }

    /// The chat it's about, if any.
    public var conversationId: String? { params["conversationId"]?.string }
}

/// The params of the requests and broadcasts Context Guard sends.
public enum CodexAppRequests {
    /// The app's own host (the IPC carries remote hosts' chats too).
    public static let localHost: JSONValue = "local"

    /// Start or stop following a chat: its owner then streams its state to Context Guard.
    public static func following(_ conversationId: String, _ on: Bool) -> JSONValue {
        ["conversationId": .string(conversationId), "hostId": localHost, "following": .bool(on)]
    }

    public static func ownerDiscovery(_ conversationId: String) -> JSONValue {
        ["hostId": localHost, "conversationId": .string(conversationId)]
    }

    static func input(_ text: String) -> JSONValue {
        [["type": "text", "text": .string(text), "text_elements": []]]
    }

    /// Send `text` as your next prompt (the chat must be idle).
    public static func startTurn(_ conversationId: String, text: String) -> JSONValue {
        ["conversationId": .string(conversationId),
         "turnStart": ["request": ["threadId": .string(conversationId), "input": input(text)], "context": [:]]]
    }

    /// Send `text` into the running turn: Codex takes it at its next step. The owner finds the running
    /// turn itself. `messageId` names the message; `cwd` is the chat's folder (the owner reads it).
    public static func steerTurn(_ conversationId: String, messageId: String, text: String, cwd: String) -> JSONValue {
        ["conversationId": .string(conversationId), "clientUserMessageId": .string(messageId), "input": input(text),
         "restoreMessage": ["id": .string(messageId), "text": .string(text), "cwd": .string(cwd),
                            "context": ["workspaceRoots": [.string(cwd)]]]]
    }

    public static func compact(_ conversationId: String) -> JSONValue {
        ["conversationId": .string(conversationId)]
    }
}
