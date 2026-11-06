import Foundation

public enum FileIO {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// nil when the file is missing or unreadable; callers fall back to defaults.
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(type, from: data)
    }

    /// Writes to a temporary file and renames it into place, so readers never see half a file.
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

/// An exclusive `flock` on a per-session lock file. Released on `release()` or deinit.
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
            usleep(5_000)
        }
        close(fd)
        return nil
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
