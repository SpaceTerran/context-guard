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
    /// On first contact it looks back from the end until a response or compaction turns up.
    /// - Parameters:
    ///   - markers: strings to look for in user/attachment lines (the delivery tag of a pending send).
    public static func read(path: String, cursor: TranscriptCursor?, markers: [String] = []) -> TranscriptReading {
        let markerBytes = markers.filter { !$0.isEmpty }.map { Data($0.utf8) }
        let tail = JSONLTail.read(path: path, cursor: cursor, empty: TranscriptReading(),
                                  scan: { scan($0, into: &$1, markers: markerBytes) },
                                  found: { $0.latest != nil })
        var reading = tail.result
        reading.cursor = tail.cursor
        reading.from = tail.from
        return reading
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

    static func int(_ value: Any?) -> Int? { JSONLTail.int(value) }
}
