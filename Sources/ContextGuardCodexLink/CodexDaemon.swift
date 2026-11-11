import ContextGuardCore
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// What the app server sends that isn't a reply to a request.
public enum CodexEvent: Sendable, Equatable {
    case notification(method: String, params: JSONValue)
    /// A request to the client (an approval and the like). The link never answers one: it only
    /// gets them for its own judge threads, which have no tools.
    case request(method: String, params: JSONValue)
    /// The connection ended. Nothing more arrives.
    case closed(String)
}

/// A connection to the Codex app server.
public protocol CodexDaemon: AnyObject, Sendable {
    /// One request. Throws `CodexLinkError`: `.rpc` when the app server refused it, `.timeout` or
    /// `.closed` when it may or may not have happened.
    func call(_ method: String, _ params: JSONValue, timeout: TimeInterval) throws -> JSONValue
    func notify(_ method: String, _ params: JSONValue?) throws
    func close()
}

/// Makes connections. The app server is never started for you: no socket, no connection.
public protocol CodexConnecting: Sendable {
    func available() -> Bool
    /// Events arrive on `onEvent` until `.closed`.
    func connect(onEvent: @escaping @Sendable (CodexEvent) -> Void) throws -> CodexDaemon
}

/// The app server's control socket: `$CODEX_HOME/app-server-control/app-server-control.sock`.
public struct CodexSocketConnector: CodexConnecting {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public static func defaultSocketPath(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        #if os(Windows)
        // `%USERPROFILE%\.codex` unless CODEX_HOME says otherwise; Windows separators throughout.
        let home = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "\\.codex"
        return PathRules.native(home) + "\\app-server-control\\app-server-control.sock"
        #else
        let home: String
        if let codexHome = env["CODEX_HOME"], !codexHome.isEmpty {
            home = (codexHome as NSString).expandingTildeInPath
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        }
        return (home as NSString).appendingPathComponent("app-server-control/app-server-control.sock")
        #endif
    }

    /// A socket is there. On the Mac, Codex 0.167.1 keeps the socket itself under
    /// `/private/tmp/codex-daemon-<uid>/` and links to it from `app-server-control/`, so the link is
    /// followed. On Windows the socket is the file itself: a reparse point tagged as a Unix socket.
    public func available() -> Bool {
        #if os(Windows)
        var data = WIN32_FIND_DATAW()
        let h = socketPath.withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &data) }
        guard let h, h != INVALID_HANDLE_VALUE else { return false }
        FindClose(h)
        return data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 && data.dwReserved0 == Self.unixSocketTag
        #else
        var st = stat()
        return stat(socketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
        #endif
    }

    /// `IO_REPARSE_TAG_AF_UNIX`.
    static let unixSocketTag: UInt32 = 0x8000_0023

    public func connect(onEvent: @escaping @Sendable (CodexEvent) -> Void) throws -> CodexDaemon {
        let stream = try SocketStream.connect(unixPath: socketPath)
        do {
            let socket = try WebSocketClient.open(stream)
            let rpc = RPCConnection(socket: socket, onEvent: onEvent)
            rpc.start()
            return rpc
        } catch {
            stream.close()
            throw error
        }
    }
}

/// JSON-RPC over the WebSocket, the way the app server speaks it (no `"jsonrpc"` field).
public final class RPCConnection: CodexDaemon, @unchecked Sendable {
    private final class Pending {
        let done = DispatchSemaphore(value: 0)
        var result: Result<JSONValue, CodexLinkError>?
    }

    private let socket: WebSocketClient
    private let onEvent: @Sendable (CodexEvent) -> Void
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var closedReason: String?

    public init(socket: WebSocketClient, onEvent: @escaping @Sendable (CodexEvent) -> Void) {
        self.socket = socket
        self.onEvent = onEvent
    }

    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "codex-link reader"
        thread.start()
    }

    private func readLoop() {
        var reason = "the app server closed the connection"
        do {
            while let text = try socket.receive() {
                // Something unreadable is skipped rather than ending the connection.
                guard let message = try? JSONValue.parse(text) else { continue }
                handle(message)
            }
        } catch {
            reason = (error as? CodexLinkError)?.description ?? "\(error)"
        }
        finish(reason)
        socket.stream.close()
    }

    private func handle(_ message: JSONValue) {
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"], !id.isNull {
                onEvent(.request(method: method, params: params))
            } else {
                onEvent(.notification(method: method, params: params))
            }
            return
        }
        guard let id = message["id"]?.int else { return }
        lock.lock()
        let waiter = pending.removeValue(forKey: id)
        if let waiter {
            if let error = message["error"], !error.isNull {
                waiter.result = .failure(.rpc(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "an error"))
            } else {
                waiter.result = .success(message["result"] ?? .null)
            }
        }
        lock.unlock()
        waiter?.done.signal()
    }

    private func finish(_ reason: String) {
        lock.lock()
        closedReason = reason
        let waiting = pending
        pending = [:]
        for w in waiting.values { w.result = .failure(.closed(reason)) }
        lock.unlock()
        for w in waiting.values { w.done.signal() }
        onEvent(.closed(reason))
    }

    public func call(_ method: String, _ params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        let waiter = Pending()
        lock.lock()
        if let reason = closedReason {
            lock.unlock()
            throw CodexLinkError.closed(reason)
        }
        let id = nextId
        nextId += 1
        pending[id] = waiter
        lock.unlock()

        let message: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": params]
        do {
            try socket.send(text: message.text)
        } catch {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            throw CodexLinkError.closed((error as? CodexLinkError)?.description ?? "\(error)")
        }
        if waiter.done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            let stillWaiting = pending.removeValue(forKey: id) != nil
            let result = waiter.result
            lock.unlock()
            // The reply can land just as the wait gives up.
            if !stillWaiting, let result { return try result.get() }
            throw CodexLinkError.timeout(method)
        }
        lock.lock()
        let result = waiter.result
        lock.unlock()
        return try (result ?? .failure(.closed("no reply"))).get()
    }

    public func notify(_ method: String, _ params: JSONValue?) throws {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        do {
            try socket.send(text: JSONValue.object(message).text)
        } catch {
            throw CodexLinkError.closed((error as? CodexLinkError)?.description ?? "\(error)")
        }
    }

    public func close() {
        socket.close()
    }
}
