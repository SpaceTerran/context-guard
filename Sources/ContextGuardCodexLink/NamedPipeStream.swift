#if os(Windows)
import ContextGuardCore
import Foundation
import WinSDK

/// The client end of a named pipe: the Codex app's router on Windows. Opened for overlapped I/O,
/// since on a handle opened for plain I/O Windows lets one call through at a time, and a read
/// waiting for the router would hold up every write.
public final class NamedPipeStream: @unchecked Sendable {
    /// Connecting asks for no more than identification: the program serving the pipe may learn who
    /// connected, but can't act as you.
    static let identifyOnly = DWORD(0x0010_0000) /* SECURITY_SQOS_PRESENT */ | DWORD(0x0001_0000) /* SECURITY_IDENTIFICATION */
    static let readSize = 64 << 10

    private let handle: HANDLE
    /// One read and one write at a time, each with its own `OVERLAPPED` and buffer: Windows writes
    /// to them after the call returns, so they can't live in Swift variables.
    private let readOverlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
    private let writeOverlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
    private let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: NamedPipeStream.readSize, alignment: 8)
    private let readReady: HANDLE
    private let writeReady: HANDLE
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let lock = NSCondition()
    private var isEnded = false
    private var isClosed = false
    private var inFlight = 0

    /// Opens `\\.\pipe\<name>`. Waits up to `wait` while every instance of the pipe is taken (the
    /// server makes another as it accepts one); throws when nobody serves it.
    public static func connect(_ path: String, wait: TimeInterval = 2) throws -> NamedPipeStream {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let h = path.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING),
                            DWORD(FILE_FLAG_OVERLAPPED) | identifyOnly, nil)
            }
            if let h, h != INVALID_HANDLE_VALUE {
                // Each direction waits on its own event.
                guard let readReady = CreateEventW(nil, true, false, nil) else {
                    let error = GetLastError()
                    CloseHandle(h)
                    throw CodexLinkError.connect(Int32(bitPattern: error))
                }
                guard let writeReady = CreateEventW(nil, true, false, nil) else {
                    let error = GetLastError()
                    CloseHandle(readReady)
                    CloseHandle(h)
                    throw CodexLinkError.connect(Int32(bitPattern: error))
                }
                return NamedPipeStream(h, readReady: readReady, writeReady: writeReady)
            }
            let error = GetLastError()
            let left = deadline.timeIntervalSinceNow
            guard error == DWORD(ERROR_PIPE_BUSY), left > 0 else { throw CodexLinkError.connect(Int32(bitPattern: error)) }
            _ = path.withCString(encodedAs: UTF16.self) { WaitNamedPipeW($0, DWORD(max(1, Int(left * 1000)))) }
        }
    }

    private init(_ handle: HANDLE, readReady: HANDLE, writeReady: HANDLE) {
        self.handle = handle
        self.readReady = readReady
        self.writeReady = writeReady
    }

    /// The process serving the pipe.
    public var serverProcessId: UInt32? {
        var pid: ULONG = 0
        return GetNamedPipeServerProcessId(handle, &pid) && pid != 0 ? UInt32(pid) : nil
    }

    /// Starts one read or write unless the stream has ended. Under the lock, so `shutdown()`'s
    /// cancel can't fall between the check and the call.
    private func begin(_ call: () -> Bool) -> (started: Bool, error: DWORD)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnded else { return nil }
        let ok = call()
        let error = ok ? 0 : GetLastError()
        guard ok || error == DWORD(ERROR_IO_PENDING) else { return (false, error) }
        inFlight += 1
        return (true, 0)
    }

    private func finish(_ overlapped: UnsafeMutablePointer<OVERLAPPED>) -> (bytes: Int, error: DWORD) {
        var bytes: DWORD = 0
        let ok = GetOverlappedResult(handle, overlapped, &bytes, true)
        let error = ok ? 0 : GetLastError()
        lock.lock()
        inFlight -= 1
        lock.broadcast()
        lock.unlock()
        return (Int(bytes), error)
    }

    private var ended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEnded
    }

    /// Some bytes, or none once the server closed the pipe or `shutdown()`/`close()` ended it.
    public func read() throws -> Data {
        readLock.lock()
        defer { readLock.unlock() }
        while true {
            readOverlapped.initialize(to: OVERLAPPED())
            readOverlapped.pointee.hEvent = readReady
            guard let started = begin({ ReadFile(handle, readBuffer, DWORD(Self.readSize), nil, readOverlapped) }) else { return Data() }
            guard started.started else {
                if Self.isEnd(started.error) { return Data() }
                throw CodexLinkError.io(Int32(bitPattern: started.error))
            }
            let (bytes, error) = finish(readOverlapped)
            if error == 0 {
                // A zero-length message isn't the end: that's ERROR_BROKEN_PIPE.
                if bytes > 0 { return Data(bytes: readBuffer, count: bytes) }
                continue
            }
            if Self.isEnd(error) || (error == DWORD(ERROR_OPERATION_ABORTED) && ended) { return Data() }
            throw CodexLinkError.io(Int32(bitPattern: error))
        }
    }

    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = DWORD(min(raw.count - offset, Int(Int32.max)))
                writeOverlapped.initialize(to: OVERLAPPED())
                writeOverlapped.pointee.hEvent = writeReady
                guard let started = begin({ WriteFile(handle, base + offset, count, nil, writeOverlapped) }) else {
                    throw CodexLinkError.closed("the connection was closed")
                }
                guard started.started else { throw CodexLinkError.io(Int32(bitPattern: started.error)) }
                let (bytes, error) = finish(writeOverlapped)
                guard error == 0, bytes > 0 else {
                    throw CodexLinkError.io(Int32(bitPattern: error == 0 ? DWORD(ERROR_BROKEN_PIPE) : error))
                }
                offset += bytes
            }
        }
    }

    /// Ends a read in progress (it sees the end of the stream) and any further reads and writes.
    /// The handle stays open until `close()`, so nothing in flight lands on a reused one.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnded else { return }
        isEnded = true
        _ = CancelIoEx(handle, nil)
    }

    /// Ends the stream, waits for what was in flight to come back, and closes the pipe.
    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        isEnded = true
        _ = CancelIoEx(handle, nil)
        // Cancelled I/O comes back at once; the buffers go only after it has.
        let deadline = Date().addingTimeInterval(5)
        while inFlight > 0, lock.wait(until: deadline) {}
        let settled = inFlight == 0
        lock.unlock()
        CloseHandle(handle)
        CloseHandle(readReady)
        CloseHandle(writeReady)
        guard settled else { return }
        readOverlapped.deallocate()
        writeOverlapped.deallocate()
        readBuffer.deallocate()
    }

    deinit { close() }

    /// The server closed its end.
    static func isEnd(_ error: DWORD) -> Bool {
        error == DWORD(ERROR_BROKEN_PIPE) || error == DWORD(ERROR_PIPE_NOT_CONNECTED) || error == DWORD(ERROR_NO_DATA)
    }
}

extension NamedPipeStream: CodexAppTransport {
    public func readSome() throws -> Data { try read() }
}
#endif
