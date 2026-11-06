import Foundation

/// What one read of a session transcript found.
public struct TranscriptReading: Equatable, Sendable {
    public enum Latest: Equatable, Sendable {
        /// The newest main-thread response: its full context size.
        case response(tokens: Int)
        /// A compaction newer than any response.
        case compaction(trigger: String?, preTokens: Int?, postTokens: Int?)
    }

    public var latest: Latest?
    /// The newest compaction seen in this read, whether or not a response came after it.
    public var compaction: Latest?
    public var title: String?
    public var markersSeen: Set<String> = []
    public var cursor: TranscriptCursor?
    /// Byte offset of the first line this read looked at.
    public var from: UInt64?

    /// Context size after this read, or nil if nothing token-bearing was found.
    public var tokens: Int? {
        switch latest {
        case .response(let t): return t
        case .compaction(_, _, let post): return post
        case nil: return nil
        }
    }
}

/// Reads Claude Code's transcript JSONL cheaply: only new bytes after the first read.
public enum TranscriptReader {
    static let firstWindow = 256 * 1024
    static let maxBackwardScan = 8 * 1024 * 1024
    /// More new bytes than this since the last read: rescan from the end instead.
    static let maxIncrement = 16 * 1024 * 1024

    /// - Parameters:
    ///   - markers: strings to look for in user/attachment lines (the delivery tag of a pending send).
    public static func read(path: String, cursor: TranscriptCursor?, markers: [String] = []) -> TranscriptReading {
        var reading = TranscriptReading()
        guard let handle = FileHandle(forReadingAtPath: path) else { return reading }
        defer { try? handle.close() }

        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return reading }
        let inode = UInt64(st.st_ino)
        let size = UInt64(max(0, st.st_size))
        let markerBytes = markers.filter { !$0.isEmpty }.map { Data($0.utf8) }

        if let cursor, cursor.inode == inode, cursor.offset <= size, size - cursor.offset <= UInt64(maxIncrement) {
            // Incremental: the lines appended since last time.
            guard let data = readRange(handle, from: cursor.offset, to: size) else {
                reading.cursor = cursor
                return reading
            }
            let complete = completeLines(data, startsAtLineBoundary: true)
            scan(complete.lines, into: &reading, markers: markerBytes)
            reading.from = cursor.offset
            reading.cursor = TranscriptCursor(inode: inode, offset: cursor.offset + UInt64(complete.consumed))
            return reading
        }

        // First contact (or the file was replaced): look backward from the end until a
        // response or compaction turns up. The window grows; a giant tool result can sit last.
        var window = UInt64(firstWindow)
        while true {
            let start = size > window ? size - window : 0
            guard let data = readRange(handle, from: start, to: size) else { return reading }
            let complete = completeLines(data, startsAtLineBoundary: start == 0)
            var attempt = TranscriptReading()
            scan(complete.lines, into: &attempt, markers: markerBytes)
            let end = start + UInt64(complete.leadingSkipped + complete.consumed)
            attempt.cursor = TranscriptCursor(inode: inode, offset: end)
            attempt.from = start + UInt64(complete.leadingSkipped)
            if attempt.latest != nil || start == 0 || window >= UInt64(maxBackwardScan) {
                return attempt
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

    // MARK: - Records

    private static let assistantNeedle = Data(#""type":"assistant""#.utf8)
    private static let compactNeedle = Data(#""compact_boundary""#.utf8)
    private static let titleNeedle = Data(#""ai-title""#.utf8)

    static func scan(_ lines: [Data], into reading: inout TranscriptReading, markers: [Data]) {
        for line in lines {
            let maybeAssistant = line.range(of: assistantNeedle) != nil
            let maybeCompact = line.range(of: compactNeedle) != nil
            let maybeTitle = line.range(of: titleNeedle) != nil
            let markerHits = markers.filter { line.range(of: $0) != nil }
            guard maybeAssistant || maybeCompact || maybeTitle || !markerHits.isEmpty else { continue }
            // The needles can also appear inside quoted tool output; only the top-level type counts.
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "assistant":
                if let tokens = responseTokens(obj) { reading.latest = .response(tokens: tokens) }
            case "system":
                guard obj["subtype"] as? String == "compact_boundary" else { break }
                let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
                let c = TranscriptReading.Latest.compaction(
                    trigger: meta["trigger"] as? String,
                    preTokens: int(meta["preTokens"]),
                    postTokens: int(meta["postTokens"]))
                reading.latest = c
                reading.compaction = c
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.isEmpty { reading.title = t }
            case "user", "attachment":
                for hit in markerHits {
                    if let s = String(data: hit, encoding: .utf8) { reading.markersSeen.insert(s) }
                }
            default:
                break
            }
        }
    }

    /// Context size of one response, as Claude Code counts it: input + cache reads + cache writes + output.
    /// nil for subagent, synthetic, error and empty records.
    static func responseTokens(_ obj: [String: Any]) -> Int? {
        if obj["isSidechain"] as? Bool == true { return nil }
        if obj["isApiErrorMessage"] as? Bool == true { return nil }
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if message["model"] as? String == "<synthetic>" { return nil }
        guard var usage = message["usage"] as? [String: Any] else { return nil }
        // A server-side tool loop reports each iteration; the last one is the live window.
        if let iterations = usage["iterations"] as? [[String: Any]], iterations.count > 1,
           let last = iterations.last(where: { $0["type"] as? String == "message" }) ?? iterations.last {
            usage = last
        }
        let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            .reduce(0) { $0 + (int(usage[$1]) ?? 0) }
        return total > 0 ? total : nil
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return nil
        }
    }
}
