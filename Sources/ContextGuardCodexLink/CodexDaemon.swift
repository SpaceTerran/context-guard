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
    /// When the app server behind the socket started (it makes the socket as it starts), or nil
    /// when there's no socket. A socket left by a server that's gone keeps its old time, and
    /// connecting to it fails: Windows keeps one through a restart.
    func socketTime() -> Date?
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
        return CodexHome.path(env) + "\\app-server-control\\app-server-control.sock"
        #else
        return (CodexHome.path(env) as NSString).appendingPathComponent("app-server-control/app-server-control.sock")
        #endif
    }

    /// The socket's last-write time, if a socket is there. On the Mac, Codex 0.167.1 keeps the
    /// socket itself under `/private/tmp/codex-daemon-<uid>/` and links to it from
    /// `app-server-control/`, so the link is followed. On Windows the socket is the file itself: a
    /// reparse point tagged as a Unix socket. Its creation time can't be used there: a starting
    /// server replaces the file a gone one left, and Windows gives a file the creation time of one
    /// of the same name deleted just before it (seen on Windows 11 with Codex 0.167.2: created
    /// hours before, written 66 ms after the server's process started).
    public func socketTime() -> Date? {
        #if os(Windows)
        var data = WIN32_FIND_DATAW()
        let h = socketPath.withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &data) }
        guard let h, h != INVALID_HANDLE_VALUE else { return nil }
        FindClose(h)
        guard data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0, data.dwReserved0 == Self.unixSocketTag else { return nil }
        let written = ProcessStart(windowsFileTime: UInt64(data.ftLastWriteTime.dwHighDateTime) << 32 | UInt64(data.ftLastWriteTime.dwLowDateTime))
        return Date(timeIntervalSince1970: Double(written.seconds) + Double(written.microseconds) / 1_000_000)
        #else
        var st = stat()
        guard stat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
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

/// What an app server's JSON-RPC messages travel over: the WebSocket of the shared app server's
/// control socket, or the standard input and output of one Context Guard runs itself.
public protocol RPCChannel: AnyObject, Sendable {
    /// The next message's text; nil at the end. One thread reads.
    func receive() throws -> String?
    /// Any thread may send.
    func send(text: String) throws
    /// Ends the conversation: a `receive` in progress sees the end.
    func end()
    /// Lets go of what's left, once nothing reads any more.
    func release()
}

extension WebSocketClient: RPCChannel {
    public func end() { close() }
    public func release() { stream.close() }
}

/// JSON-RPC the way the app server speaks it (no `"jsonrpc"` field).
public final class RPCConnection: CodexDaemon, @unchecked Sendable {
    private final class Pending {
        let done = DispatchSemaphore(value: 0)
        var result: Result<JSONValue, CodexLinkError>?
    }

    private let channel: RPCChannel
    private let onEvent: @Sendable (CodexEvent) -> Void
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var closedReason: String?

    public init(channel: RPCChannel, onEvent: @escaping @Sendable (CodexEvent) -> Void) {
        self.channel = channel
        self.onEvent = onEvent
    }

    public convenience init(socket: WebSocketClient, onEvent: @escaping @Sendable (CodexEvent) -> Void) {
        self.init(channel: socket, onEvent: onEvent)
    }

    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "codex-link reader"
        thread.start()
    }

    private func readLoop() {
        var reason = "the app server closed the connection"
        do {
            while let text = try channel.receive() {
                // Something unreadable is skipped rather than ending the connection.
                guard let message = try? JSONValue.parse(text) else { continue }
                handle(message)
            }
        } catch {
            reason = (error as? CodexLinkError)?.description ?? "\(error)"
        }
        finish(reason)
        channel.release()
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
            try channel.send(text: message.text)
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
            try channel.send(text: JSONValue.object(message).text)
        } catch {
            throw CodexLinkError.closed((error as? CodexLinkError)?.description ?? "\(error)")
        }
    }

    public func close() {
        channel.end()
    }
}
