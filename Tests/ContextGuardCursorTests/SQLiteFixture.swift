import Foundation
import SQLite3

/// A SQLite file a test writes, the way Cursor does: in WAL mode, kept open while Cursor runs.
final class SQLiteFixture {
    let url: URL
    private var db: OpaquePointer?

    init(_ url: URL, wal: Bool = true) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        if wal { exec("PRAGMA journal_mode = WAL") }
    }

    deinit { close() }

    /// Closing the last writer folds the WAL into the file and removes `-wal` and `-shm`, as when
    /// Cursor quits or a CLI chat ends.
    func close() {
        guard let db else { return }
        // The Mac's SQLite keeps both files by default; Cursor's own removes them.
        var keep: Int32 = 0
        sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &keep)
        sqlite3_close(db)
        self.db = nil
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        precondition(rc == SQLITE_OK, err.map { String(cString: $0) } ?? "sqlite \(rc)")
    }

    /// Runs `sql` with each value bound in order: String as text, Data as a blob.
    func run(_ sql: String, _ values: Any...) {
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, transient)
            case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), transient) }
            default: preconditionFailure("unsupported value \(v)")
            }
        }
        precondition(sqlite3_step(stmt) == SQLITE_DONE)
    }

    func exists(_ suffix: String) -> Bool { FileManager.default.fileExists(atPath: url.path + suffix) }
}

func json(_ obj: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
}
