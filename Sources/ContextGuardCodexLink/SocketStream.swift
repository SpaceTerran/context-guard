import Darwin
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
        case .connect(let e): return "couldn't connect (\(String(cString: strerror(e))))"
        case .io(let e): return "the connection failed (\(String(cString: strerror(e))))"
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

    /// The app server refused it outright, so it didn't happen.
    public var isRefusal: Bool {
        if case .rpc = self { return true }
        return false
    }
}

/// A connected stream socket. Reads block until data, end of stream or `shutdown()`.
public final class SocketStream: @unchecked Sendable {
    public let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    /// A Unix socket address holds 104 bytes, the last one the terminating NUL.
    public static let maxPathBytes = 103

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func connect(unixPath path: String) throws -> SocketStream {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes else { throw CodexLinkError.socketPathTooLong(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexLinkError.connect(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            throw CodexLinkError.connect(e)
        }
        return SocketStream(fd: fd)
    }

    /// A connected pair, for tests.
    public static func pair() throws -> (SocketStream, SocketStream) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw CodexLinkError.connect(errno) }
        return (SocketStream(fd: fds[0]), SocketStream(fd: fds[1]))
    }

    /// Reads and writes give up after `seconds` (0: never).
    public func setTimeouts(read: TimeInterval, write: TimeInterval) {
        func tv(_ s: TimeInterval) -> timeval {
            timeval(tv_sec: Int(s), tv_usec: Int32((s - s.rounded(.down)) * 1_000_000))
        }
        var r = tv(read), w = tv(write)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &w, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Up to `max` bytes; empty at end of stream.
    public func read(max: Int = 64 << 10) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
            if n >= 0 { return Data(buffer[0..<n]) }
            if errno == EINTR { continue }
            throw CodexLinkError.io(errno)
        }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    throw CodexLinkError.io(n < 0 ? errno : EPIPE)
                }
            }
        }
    }

    /// Ends a blocked read (it sees end of stream) and any further writes. The descriptor stays
    /// open until `close()`, so a read in progress never lands on a reused descriptor.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    deinit { close() }
}
