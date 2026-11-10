import Foundation

/// Reads the end of an append-only JSONL log cheaply. After the first read, only the lines added
/// since; on first contact, or when the file was replaced, backward from the end until the lines
/// read hold what the caller needs. Claude Code transcripts and Codex rollouts both read through it.
public enum JSONLTail {
    static let firstWindow = 256 * 1024
    static let maxBackwardScan = 8 * 1024 * 1024
    /// More new bytes than this since the last read: rescan from the end instead.
    static let maxIncrement = 16 * 1024 * 1024

    public struct Read<Result> {
        public var result: Result
        /// Where the next read starts. nil when the file couldn't be read.
        public var cursor: TranscriptCursor?
        /// Byte offset of the first line this read looked at.
        public var from: UInt64?
    }

    /// - Parameters:
    ///   - empty: the result before any line is scanned.
    ///   - scan: folds complete lines, oldest first, into the result.
    ///   - found: whether a backward read has looked far enough back.
    static func read<Result>(path: String, cursor: TranscriptCursor?, empty: Result,
                             scan: ([Data], inout Result) -> Void, found: (Result) -> Bool) -> Read<Result> {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Read(result: empty) }
        defer { try? handle.close() }

        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return Read(result: empty) }
        let inode = UInt64(st.st_ino)
        let size = UInt64(max(0, st.st_size))

        if let cursor, cursor.inode == inode, cursor.offset <= size, size - cursor.offset <= UInt64(maxIncrement) {
            // Incremental: the lines appended since last time.
            guard let data = readRange(handle, from: cursor.offset, to: size) else {
                return Read(result: empty, cursor: cursor)
            }
            let complete = completeLines(data, startsAtLineBoundary: true)
            var result = empty
            scan(complete.lines, &result)
            return Read(result: result, cursor: TranscriptCursor(inode: inode, offset: cursor.offset + UInt64(complete.consumed)),
                        from: cursor.offset)
        }

        // Look backward from the end until `found`. The window grows: a giant tool result can sit last.
        var window = UInt64(firstWindow)
        while true {
            let start = size > window ? size - window : 0
            guard let data = readRange(handle, from: start, to: size) else { return Read(result: empty) }
            let complete = completeLines(data, startsAtLineBoundary: start == 0)
            var result = empty
            scan(complete.lines, &result)
            let end = start + UInt64(complete.leadingSkipped + complete.consumed)
            if found(result) || start == 0 || window >= UInt64(maxBackwardScan) {
                return Read(result: result, cursor: TranscriptCursor(inode: inode, offset: end),
                            from: start + UInt64(complete.leadingSkipped))
            }
            window = min(window * 4, UInt64(maxBackwardScan))
        }
    }

    // MARK: - Lines

    static func readRange(_ handle: FileHandle, from: UInt64, to: UInt64) -> Data? {
        guard to > from else { return Data() }
        do {
            try handle.seek(toOffset: from)
            return try handle.read(upToCount: Int(to - from)) ?? Data()
        } catch {
            return nil
        }
    }

    struct CompleteLines {
        var lines: [Data]
        /// Bytes dropped at the front (a partial line when reading from mid-file).
        var leadingSkipped: Int
        /// Bytes of complete lines after `leadingSkipped`, through the last newline.
        var consumed: Int
    }

    /// Splits on newlines. A trailing segment without a newline is still being written, so it's left
    /// for next time. When the read began mid-file, the first segment is a fragment and is dropped.
    static func completeLines(_ data: Data, startsAtLineBoundary: Bool) -> CompleteLines {
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var leadingSkipped = 0
        var lineStart = data.startIndex
        var sawFirst = startsAtLineBoundary
        var lastEnd = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == newline {
                if sawFirst {
                    if i > lineStart { lines.append(data[lineStart..<i]) }
                } else {
                    leadingSkipped = i + 1 - data.startIndex
                    sawFirst = true
                }
                lineStart = i + 1
                lastEnd = i + 1
            }
            i += 1
        }
        let consumed = sawFirst ? (lastEnd - data.startIndex) - leadingSkipped : 0
        return CompleteLines(lines: lines, leadingSkipped: leadingSkipped, consumed: max(0, consumed))
    }

    /// A JSON number as an Int.
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return nil
        }
    }
}
