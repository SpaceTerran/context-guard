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
        try replace(url, with: try encoder().encode(value))
    }

    /// How long a save keeps trying while another program holds the file (Windows).
    static let busyFor: TimeInterval = 0.5

    /// `data` renamed into place. On Windows the rename fails while another program has the file
    /// open without sharing delete (antivirus, the search indexer), so it tries again for a moment.
    /// Context Guard's own readers never hold it that way.
    static func replace(_ url: URL, with data: Data) throws {
        #if os(Windows)
        let deadline = Date().addingTimeInterval(busyFor)
        var pause: TimeInterval = 0.002
        while true {
            do {
                try data.write(to: url, options: [.atomic])
                return
            } catch let error as CocoaError where error.code == .fileWriteNoPermission && Date() < deadline {
                Thread.sleep(forTimeInterval: pause)
                pause = min(pause * 2, 0.064)
            }
        }
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
