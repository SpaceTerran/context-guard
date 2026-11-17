import Foundation
import SQLite3

/// One of Cursor's SQLite files, opened to read only. Cursor keeps writing them, so Context Guard
/// never locks, changes or creates anything: it opens them read-only, and a file Cursor has closed
/// (in WAL mode a read-only connection can't make the shared-memory file a closed one lacks) is read
/// as it stands on disk, which then holds everything.
final class ReadOnlyDatabase {
    let file: URL
    private var db: OpaquePointer?
    private(set) var immutable = false

    /// nil when there's no such file.
    init?(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        self.file = file
    }

    deinit { sqlite3_close_v2(db) }

    /// The first row `sql` returns with `args` bound to ?1, ?2…; nil if there's none or it can't be read.
    func row(_ sql: String, _ args: [String] = []) -> [Column]? {
        switch run(sql, args) {
        case .row(let columns): return columns
        case .none, .failed: return nil
        case .cantOpen:
            // A closed WAL file (no `-shm`): read it as it is.
            guard !immutable else { return nil }
            sqlite3_close_v2(db)
            db = nil
            immutable = true
            if case .row(let columns) = run(sql, args) { return columns }
            return nil
        }
    }

    enum Column: Equatable {
        case int(Int64), double(Double), text(String), blob(Data), null

        var int: Int? {
            switch self {
            case .int(let n): return Int(exactly: n)
            case .double(let d): return d.isFinite && abs(d) < 1e15 ? Int(d) : nil
            case .text(let s): return Int(s)
            case .blob, .null: return nil
            }
        }

        var text: String? {
            switch self {
            case .text(let s): return s
            case .blob(let d): return String(data: d, encoding: .utf8)
            case .int, .double, .null: return nil
            }
        }

        var data: Data? {
            switch self {
            case .blob(let d): return d
            case .text(let s): return Data(s.utf8)
            case .int, .double, .null: return nil
            }
        }
    }

    private enum Outcome { case row([Column]), none, failed, cantOpen }

    private func run(_ sql: String, _ args: [String]) -> Outcome {
        if db == nil {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            let rc = sqlite3_open_v2(uri(immutable ? "immutable=1" : "mode=ro"), &handle, flags, nil)
            guard rc == SQLITE_OK, let handle else {
                sqlite3_close_v2(handle)
                return rc == SQLITE_CANTOPEN ? .cantOpen : .failed
            }
            // Cursor writes in short transactions; a reader waits for one at most this long.
            sqlite3_busy_timeout(handle, 250)
            db = handle
        }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard rc == SQLITE_OK, let stmt else { return Self.outcome(rc) }
        for (i, arg) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, Self.transient)
        }
        rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { return rc == SQLITE_DONE ? .none : Self.outcome(rc) }
        return .row((0..<sqlite3_column_count(stmt)).map { Self.column(stmt, $0) })
    }

    private static func outcome(_ rc: Int32) -> Outcome { (rc & 0xff) == SQLITE_CANTOPEN ? .cantOpen : .failed }

    private static func column(_ stmt: OpaquePointer, _ i: Int32) -> Column {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: return .text(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: p, count: n))
        default: return .null
        }
    }

    /// `file:` URI with the path's reserved characters escaped (Cursor's lives in "Application Support").
    private func uri(_ query: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let path = file.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? file.path
        return "file:\(path)?\(query)"
    }

    /// SQLite copies the bound text (`SQLITE_TRANSIENT`).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
