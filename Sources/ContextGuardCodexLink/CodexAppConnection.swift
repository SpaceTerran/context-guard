import Foundation

/// A byte stream to the Codex app's router: a Unix socket on the Mac, a named pipe on Windows.
public protocol CodexAppTransport: AnyObject, Sendable {
    /// Some bytes, or none at the end of the stream. Blocks until there are.
    func readSome() throws -> Data
    func write(_ data: Data) throws
    /// Ends a read in progress (it sees the end of the stream) and any further writes. Called from
    /// another thread than the reader's.
    func shutdown()
    func close()
}

extension SocketStream: CodexAppTransport {
    public func readSome() throws -> Data { try read() }
}

/// What the router sends that isn't a reply to a request.
public enum CodexAppEvent: Sendable, Equatable {
    case broadcast(CodexAppBroadcast)
    /// The connection ended (the app quit, or crashed). Nothing more arrives.
    case closed(String)
}

/// Context Guard's connection to the Codex app's router, as one client among the app's own. It
/// answers every "can you handle this?" with no, so the router never sends it anyone's requests.
public final class CodexAppConnection: @unchecked Sendable {
    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<JSONValue, Error>?
    }

    /// The id a client uses until the router gives it one.
    static let unnamed = "initializing-client"

    private let transport: CodexAppTransport
    private let onEvent: @Sendable (CodexAppEvent) -> Void
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var pending: [String: Pending] = [:]
    private var closedReason: String?
    private var id = CodexAppConnection.unnamed
    /// How much longer than the router's own timeout a request is waited for, so the router's
    /// `request-timeout` arrives first.
    static let slack: TimeInterval = 2

    /// `onEvent` runs on the connection's reader thread: keep it short.
    public init(transport: CodexAppTransport, onEvent: @escaping @Sendable (CodexAppEvent) -> Void) {
        self.transport = transport
        self.onEvent = onEvent
    }

    /// The id the router gave this connection (`initialize`).
    public var clientId: String {
        lock.lock()
        defer { lock.unlock() }
        return id
    }

    /// Starts reading and joins the router. Returns the client id it gave.
    @discardableResult
    public func start(timeout: TimeInterval) throws -> String {
        let thread = Thread { [self] in readLoop() }
        thread.name = "codex-app reader"
        thread.start()
        let result = try request(.initialize, params: ["clientType": .string(CodexAppIPC.clientType)], timeout: timeout)
        guard let given = result["clientId"]?.string, !given.isEmpty else {
            close()
            throw CodexLinkError.protocolError("initialize gave no client id")
        }
        lock.lock()
        id = given
        lock.unlock()
        return given
    }

    /// One request, to `target` (a client id) or to whichever client can handle it. Throws
    /// `CodexAppError` when the router or the owner answered that it didn't happen, and
    /// `CodexLinkError` (`.closed`, `.timeout`) when it may or may not have.
    public func request(_ method: CodexAppMethod, params: JSONValue, to target: String? = nil,
                        timeout: TimeInterval) throws -> JSONValue {
        let requestId = UUID().uuidString.lowercased()
        let waiter = Pending()
        lock.lock()
        if let reason = closedReason {
            lock.unlock()
            throw CodexLinkError.closed(reason)
        }
        pending[requestId] = waiter
        let source = id
        lock.unlock()

        do {
            try send(CodexAppIPC.request(id: requestId, from: source, method, params: params, to: target, timeout: timeout))
        } catch {
            lock.lock()
            pending.removeValue(forKey: requestId)
            lock.unlock()
            throw error
        }
        if waiter.done.wait(timeout: .now() + timeout + Self.slack) == .timedOut {
            lock.lock()
            let stillWaiting = pending.removeValue(forKey: requestId) != nil
            let result = waiter.result
            lock.unlock()
            // The reply can land just as the wait gives up.
            if !stillWaiting, let result { return try result.get() }
            throw CodexLinkError.timeout(method.name)
        }
        lock.lock()
        let result = waiter.result
        lock.unlock()
        return try (result ?? .failure(CodexLinkError.closed("no reply"))).get()
    }

    /// A message to every client.
    public func broadcast(_ method: CodexAppMethod, params: JSONValue) throws {
        try send(CodexAppIPC.broadcast(from: clientId, method, params: params))
    }

    /// Ends the connection. The reader sees the end and reports `.closed`.
    public func close() {
        transport.shutdown()
    }

    func send(_ message: JSONValue) throws {
        let frame = CodexAppIPC.frame(message)
        guard frame.count - 4 <= CodexAppIPC.maxFrameBytes else { throw CodexLinkError.tooLarge }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try transport.write(frame)
        } catch {
            throw CodexLinkError.closed((error as? CodexLinkError)?.description ?? "\(error)")
        }
    }

    private func readLoop() {
        var reason = "the Codex app closed the connection"
        var reader = CodexAppFrameReader()
        do {
            while true {
                let data = try transport.readSome()
                if data.isEmpty { break }
                for message in try reader.append(data) { handle(message) }
            }
        } catch {
            reason = (error as? CodexLinkError)?.description ?? "\(error)"
        }
        finish(reason)
        transport.close()
    }

    private func handle(_ json: JSONValue) {
        switch CodexAppMessage(json) {
        case .response(let requestId, let result):
            lock.lock()
            let waiter = pending.removeValue(forKey: requestId)
            waiter?.result = result.mapError { $0 as Error }
            lock.unlock()
            waiter?.done.signal()
        case .broadcast(let b):
            onEvent(.broadcast(b))
        case .discoveryRequest(let requestId):
            // Answered at once: the router waits for every client before it gives up on a request.
            try? send(CodexAppIPC.cannotHandle(requestId))
        case .other:
            break
        }
    }

    private func finish(_ reason: String) {
        lock.lock()
        closedReason = reason
        let waiting = pending
        pending = [:]
        for w in waiting.values { w.result = .failure(CodexLinkError.closed(reason)) }
        lock.unlock()
        for w in waiting.values { w.done.signal() }
        onEvent(.closed(reason))
    }
}
