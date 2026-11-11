#if os(Windows)
import WinSDK
#endif
import Foundation

#if os(Windows)
/// An exclusive lock on a lock file (`flock` on the Mac, `LockFileEx` on Windows). Released on
/// `release()` or deinit.
public final class FileLock {
    private var handle: HANDLE?

    private init(handle: HANDLE) { self.handle = handle }

    /// Tries without blocking until `timeout` passes; nil if the lock stays busy.
    public static func acquire(_ url: URL, timeout: TimeInterval) -> FileLock? {
        guard let h = open(url) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if lock(h, wait: false) { return FileLock(handle: h) }
            if GetLastError() != DWORD(ERROR_LOCK_VIOLATION) || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        CloseHandle(h)
        return nil
    }

    /// Waits as long as it takes, asleep. nil only if the lock file can't be opened.
    public static func wait(_ url: URL) -> FileLock? {
        guard let h = open(url) else { return nil }
        guard lock(h, wait: true) else {
            CloseHandle(h)
            return nil
        }
        return FileLock(handle: h)
    }

    public func release() {
        guard let h = handle else { return }
        var overlapped = OVERLAPPED()
        UnlockFileEx(h, 0, 1, 0, &overlapped)
        CloseHandle(h)
        handle = nil
    }

    deinit { release() }

    /// Not inherited by child processes, like the Mac's `O_CLOEXEC`.
    private static func open(_ url: URL) -> HANDLE? {
        let h = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { return nil }
        return h
    }

    /// The first byte, exclusively.
    private static func lock(_ h: HANDLE, wait: Bool) -> Bool {
        var overlapped = OVERLAPPED()
        let flags = DWORD(LOCKFILE_EXCLUSIVE_LOCK) | (wait ? 0 : DWORD(LOCKFILE_FAIL_IMMEDIATELY))
        return LockFileEx(h, flags, 0, 1, 0, &overlapped)
    }
}
#else
/// An exclusive lock on a lock file (`flock` on the Mac, `LockFileEx` on Windows). Released on
/// `release()` or deinit.
public final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Tries without blocking until `timeout` passes; nil if the lock stays busy.
    public static func acquire(_ url: URL, timeout: TimeInterval) -> FileLock? {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return FileLock(fd: fd) }
            if errno != EWOULDBLOCK && errno != EINTR { break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        close(fd)
        return nil
    }

    /// Waits as long as it takes, asleep. nil only if the lock file can't be opened.
    public static func wait(_ url: URL) -> FileLock? {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(fd)
                return nil
            }
        }
        return FileLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
#endif
