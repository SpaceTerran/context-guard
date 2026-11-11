#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// Why talking to the Codex app server failed.
public enum CodexLinkError: Error, Equatable, CustomStringConvertible {
    /// Longer than a Unix socket address holds.
    case socketPathTooLong(String)
    case connect(Int32)
    case io(Int32)
    /// Only `/` is ever opened: the app server's `/daemon/shutdown` stops it.
    case forbiddenPath(String)
    case handshake(String)
    case protocolError(String)
    case tooLarge
    /// The connection ended.
    case closed(String)
    /// No reply in time. The request may still have been carried out.
    case timeout(String)
    /// The app server answered with an error: the request wasn't carried out.
    case rpc(code: Int, message: String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let p): return "the socket path is too long (\(p.utf8.count) bytes)"
        case .connect(let e): return "couldn't connect (\(SocketStream.message(for: e)))"
        case .io(let e): return "the connection failed (\(SocketStream.message(for: e)))"
        case .forbiddenPath(let p): return "refused to open \(p)"
        case .handshake(let why): return "the app server didn't accept the connection (\(why))"
        case .protocolError(let why): return "the app server sent something unreadable (\(why))"
        case .tooLarge: return "a message from the app server was too large"
        case .closed(let why): return why
        case .timeout(let method): return "\(method) got no answer"
        case .rpc(let code, let message): return "\(message) (\(code))"
        }
    }

    /// The app server doesn't have this method (an older or newer Codex).
    public var isMissingMethod: Bool {
        guard case .rpc(let code, let message) = self else { return false }
        if code == -32601 { return true }
        let m = message.lowercased()
        return m.contains("unknown variant") || m.contains("method not found") || m.contains("unknown method")
    }

    /// A read or write gave up after its timeout.
    public var isTimeout: Bool {
        guard case .io(let code) = self else { return false }
        return SocketStream.isTimeout(code)
    }

    /// The app server refused it outright, so it didn't happen.
    public var isRefusal: Bool {
        if case .rpc = self { return true }
        return false
    }
}

/// A connected stream socket. Reads block until data, end of stream or `shutdown()`.
public final class SocketStream: @unchecked Sendable {
    #if os(Windows)
    public typealias Native = SOCKET
    #else
    public typealias Native = Int32
    #endif

    let native: Native
    private let lock = NSLock()
    private var isClosed = false
    /// `shutdown()` or `close()` was called.
    private var isEnded = false
    #if os(Windows)
    /// Reads in `recv` now.
    private var readers = 0
    #endif

    /// A Unix socket address holds the path and its terminating NUL (104 bytes on the Mac, 108 on Windows).
    public static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    init(native: Native) {
        self.native = native
        #if !os(Windows)
        var on: Int32 = 1
        setsockopt(native, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public static func connect(unixPath path: String) throws -> SocketStream {
        let s = try open(path)
        let rc = withAddress(path) { address, length in
            #if os(Windows)
            WinSDK.connect(s, address, length)
            #else
            Darwin.connect(s, address, length)
            #endif
        }
        if rc != 0 {
            let e = lastError()
            closeNative(s)
            throw CodexLinkError.connect(e)
        }
        return SocketStream(native: s)
    }

    /// A connected pair, for tests: one connection to a listening socket in a new temporary folder.
    public static func pair() throws -> (SocketStream, SocketStream) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let listener = try SocketListener(path: dir.appendingPathComponent("s").path)
        defer { listener.close() }
        let client = try connect(unixPath: listener.path)
        return (client, try listener.accept())
    }

    /// Reads and writes give up after `seconds` (0: never).
    public func setTimeouts(read: TimeInterval, write: TimeInterval) {
        #if os(Windows)
        func set(_ option: Int32, _ seconds: TimeInterval) {
            var ms = DWORD(max(0, seconds) * 1000)
            _ = withUnsafeBytes(of: &ms) { raw in
                setsockopt(native, SOL_SOCKET, option, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
            }
        }
        set(SO_RCVTIMEO, read)
        set(SO_SNDTIMEO, write)
        #else
        func tv(_ s: TimeInterval) -> timeval {
            timeval(tv_sec: Int(s), tv_usec: Int32((s - s.rounded(.down)) * 1_000_000))
        }
        var r = tv(read), w = tv(write)
        setsockopt(native, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(native, SOL_SOCKET, SO_SNDTIMEO, &w, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    /// Up to `max` bytes; empty at end of stream.
    public func read(max: Int = 64 << 10) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            #if os(Windows)
            guard let got = receive(into: &buffer) else { return Data() }
            let (n, e) = got
            #else
            let n = buffer.withUnsafeMutableBytes { Darwin.read(native, $0.baseAddress, max) }
            let e = n < 0 ? errno : 0
            #endif
            if n >= 0 { return Data(buffer[0..<n]) }
            if Self.isInterrupted(e) { continue }
            throw CodexLinkError.io(e)
        }
    }

    #if os(Windows)
    /// One `recv`, or nil once `shutdown()` or `close()` has ended the stream (a `recv` they
    /// cancelled included), which reads as the end of the stream, as on the Mac.
    private func receive(into buffer: inout [UInt8]) -> (count: Int, error: Int32)? {
        lock.lock()
        guard !isEnded else {
            lock.unlock()
            return nil
        }
        readers += 1
        lock.unlock()
        let n = buffer.withUnsafeMutableBytes { Int(recv(native, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)) }
        let e = n < 0 ? WSAGetLastError() : 0
        lock.lock()
        readers -= 1
        let ended = isEnded
        lock.unlock()
        return n < 0 && ended ? nil : (n, e)
    }

    /// Windows doesn't wake a `recv` that's already waiting when its socket is shut down, so it's
    /// cancelled, again until it has returned: one may have been about to start.
    private func cancelReads() {
        let deadline = Date().addingTimeInterval(1)
        while true {
            lock.lock()
            let waiting = readers
            lock.unlock()
            guard waiting > 0, Date() < deadline else { return }
            _ = CancelIoEx(HANDLE(bitPattern: UInt(native)), nil)
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    #endif

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                #if os(Windows)
                let n = Int(WinSDK.send(native, (base + offset).assumingMemoryBound(to: CChar.self), Int32(raw.count - offset), 0))
                #else
                let n = Darwin.write(native, base + offset, raw.count - offset)
                #endif
                if n > 0 {
                    offset += n
                } else if n < 0, Self.isInterrupted(Self.lastError()) {
                    continue
                } else {
                    throw CodexLinkError.io(n < 0 ? Self.lastError() : Self.brokenPipe)
                }
            }
        }
    }

    /// Ends a blocked read (it sees end of stream) and any further writes. The socket stays open
    /// until `close()`, so a read in progress never lands on a reused one.
    public func shutdown() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isEnded = true
        Self.shutdownNative(native)
        lock.unlock()
        #if os(Windows)
        cancelReads()
        #endif
    }

    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        isEnded = true
        Self.shutdownNative(native)
        lock.unlock()
        #if os(Windows)
        cancelReads()
        #endif
        Self.closeNative(native)
    }

    deinit { close() }

    // MARK: - Platform

    #if os(Windows)
    /// Winsock, started once for the process.
    private static let winsock: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    static let brokenPipe = WSAECONNRESET

    static func lastError() -> Int32 { WSAGetLastError() }
    static func isInterrupted(_ code: Int32) -> Bool { code == WSAEINTR }
    static func isTimeout(_ code: Int32) -> Bool { code == WSAETIMEDOUT || code == WSAEWOULDBLOCK }
    /// Sending only: shutting down receiving with data still unread resets the connection, so the
    /// other end would never see a clean end. Reads end through `isEnded` and `cancelReads()`.
    static func shutdownNative(_ s: Native) { _ = WinSDK.shutdown(s, SD_SEND) }
    static func closeNative(_ s: Native) { _ = closesocket(s) }

    /// What Windows calls the error, without the trailing period.
    public static func message(for code: Int32) -> String {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let n = FormatMessageW(DWORD(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS), nil, DWORD(bitPattern: code),
                               0, &buffer, DWORD(buffer.count), nil)
        guard n > 0 else { return "error \(code)" }
        let text = String(decoding: buffer.prefix(Int(n)), as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    static func open(_ path: String) throws -> Native {
        guard !path.utf8.isEmpty, path.utf8.count <= maxPathBytes else { throw CodexLinkError.socketPathTooLong(path) }
        guard winsock else { throw CodexLinkError.connect(lastError()) }
        let s = WinSDK.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s != INVALID_SOCKET else { throw CodexLinkError.connect(lastError()) }
        return s
    }

    static func withAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, Int32) -> R) -> R {
        var addr = sockaddr_un()
        addr.sun_family = ADDRESS_FAMILY(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, Int32(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    #else
    static let brokenPipe = EPIPE

    static func lastError() -> Int32 { errno }
    static func isInterrupted(_ code: Int32) -> Bool { code == EINTR }
    static func isTimeout(_ code: Int32) -> Bool { code == EAGAIN || code == EWOULDBLOCK }
    static func shutdownNative(_ s: Native) { _ = Darwin.shutdown(s, SHUT_RDWR) }
    static func closeNative(_ s: Native) { _ = Darwin.close(s) }

    public static func message(for code: Int32) -> String { String(cString: strerror(code)) }

    static func open(_ path: String) throws -> Native {
        guard !path.utf8.isEmpty, path.utf8.count <= maxPathBytes else { throw CodexLinkError.socketPathTooLong(path) }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw CodexLinkError.connect(errno) }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        return s
    }

    static func withAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    #endif
}

/// A listening Unix socket: `SocketStream.pair()` and the tests' app servers.
final class SocketListener: @unchecked Sendable {
    let path: String
    private let native: SocketStream.Native
    private let lock = NSLock()
    private var isClosed = false

    init(path: String) throws {
        let s = try SocketStream.open(path)
        let bound = SocketStream.withAddress(path) { address, length in
            #if os(Windows)
            WinSDK.bind(s, address, length)
            #else
            Darwin.bind(s, address, length)
            #endif
        }
        #if os(Windows)
        let listening = bound == 0 && WinSDK.listen(s, 4) == 0
        #else
        let listening = bound == 0 && Darwin.listen(s, 4) == 0
        #endif
        guard listening else {
            let e = SocketStream.lastError()
            SocketStream.closeNative(s)
            throw CodexLinkError.connect(e)
        }
        self.path = path
        native = s
    }

    func accept() throws -> SocketStream {
        #if os(Windows)
        let s = WinSDK.accept(native, nil, nil)
        guard s != INVALID_SOCKET else { throw CodexLinkError.connect(SocketStream.lastError()) }
        #else
        let s = Darwin.accept(native, nil, nil)
        guard s >= 0 else { throw CodexLinkError.connect(errno) }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        #endif
        return SocketStream(native: s)
    }

    /// Stops listening and removes the socket file.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        SocketStream.closeNative(native)
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit { close() }
}
