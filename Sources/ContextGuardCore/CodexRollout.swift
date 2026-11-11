import Foundation

/// The first line of a Codex rollout: which thread it is and who started it.
public struct CodexMeta: Equatable, Sendable {
    public var threadId: String
    /// The client that started it: `codex-tui` for a terminal session.
    public var originator: String?
    /// How it was started (`cli`, `vscode`, `exec`, …). nil when Codex records an object instead,
    /// which it does for a subagent's thread.
    public var source: String?
    public var historyMode: String?
    public var cwd: String?
    public var cliVersion: String?

    /// Who the thread is for: `user`, or `subagent` for one a session started.
    public var threadSource: String?

    /// Rollout formats Context Guard reads: Codex 0.167 writes `paginated`, earlier ones `legacy`.
    static let readableHistory: Set<String> = ["legacy", "paginated"]

    /// A session you drive in a terminal, in a format Context Guard knows how to read.
    public var isTerminalSession: Bool {
        originator == "codex-tui" && source != nil && (threadSource ?? "user") == "user"
            && Self.readableHistory.contains(historyMode ?? "legacy")
    }
}

/// A Codex session's turns as its rollout shows them.
public struct CodexTurn: Codable, Equatable, Sendable {
    /// The newest turn started (`task_started`).
    public var startedAt: Date?
    /// It hasn't finished yet.
    public var open = false
    /// The open turn had a prompt, a reply or a tool call in it before any compaction. A compaction
    /// on a turn of its own (`/compact`, or Context Guard's) has none.
    public var hasContent = false
    /// The newest finished turn was interrupted (`turn_aborted`).
    public var aborted = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try? c.decode(Date.self, forKey: .startedAt)
        open = (try? c.decode(Bool.self, forKey: .open)) ?? false
        hasContent = (try? c.decode(Bool.self, forKey: .hasContent)) ?? false
        aborted = (try? c.decode(Bool.self, forKey: .aborted)) ?? false
    }
}

/// What one read of a Codex rollout found.
public struct CodexReading: Equatable, Sendable {
    /// What `Engine.observe` folds in: the size, a compaction, delivery markers, the cursor.
    public var transcript = TranscriptReading()
    public var window: Int?
    public var model: String?
    /// The turns, carried over from the read before.
    public var turn = CodexTurn()
    /// A compaction was the last size-changing line: the size after it isn't written yet.
    public var sizeAfterCompactionUnknown = false
}

/// Reads Codex rollouts (`~/.codex/sessions/Y/M/D/rollout-…-<thread>.jsonl`) cheaply, like
/// `TranscriptReader` reads Claude Code transcripts.
public enum CodexRollout {
    /// The first line carries Codex's whole system prompt, about 48 KB.
    static let maxMetaLine = 1 << 20

    public static func meta(path: String) -> CodexMeta? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: maxMetaLine),
              let end = head.firstIndex(of: UInt8(ascii: "\n")),
              let obj = (try? JSONSerialization.jsonObject(with: head[head.startIndex..<end])) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let p = obj["payload"] as? [String: Any],
              let id = p["id"] as? String, !id.isEmpty else { return nil }
        return CodexMeta(threadId: id, originator: p["originator"] as? String, source: p["source"] as? String,
                         historyMode: p["history_mode"] as? String, cwd: p["cwd"] as? String,
                         cliVersion: p["cli_version"] as? String, threadSource: p["thread_source"] as? String)
    }

    /// - Parameters:
    ///   - markers: strings to look for in your prompts (the save message's tag).
    ///   - turn: the turns as the read before left them.
    public static func read(path: String, cursor: TranscriptCursor?, markers: [String] = [], turn: CodexTurn = CodexTurn()) -> CodexReading {
        let markerBytes = markers.filter { !$0.isEmpty }.map { Data($0.utf8) }
        var start = CodexReading()
        start.turn = turn
        let tail = JSONLTail.read(path: path, cursor: cursor, empty: start,
                                  scan: { scan($0, into: &$1, markers: markerBytes) },
                                  found: { $0.transcript.latest != nil })
        var reading = tail.result
        reading.transcript.cursor = tail.cursor
        reading.transcript.from = tail.from
        return reading
    }

    // MARK: - Records

    private static let needles = ["token_count", "task_started", "task_complete", "turn_aborted", "user_message", "item_completed",
                                  #""type":"compacted""#, "turn_context", #""type":"response_item""#].map { Data($0.utf8) }

    static func scan(_ lines: [Data], into r: inout CodexReading, markers: [Data]) {
        var lastTokens: Int?
        for line in lines {
            let markerHits = markers.filter { line.range(of: $0) != nil }
            guard markerHits.count > 0 || needles.contains(where: { line.range(of: $0) != nil }),
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let p = obj["payload"] as? [String: Any] ?? [:]

            switch type {
            case "event_msg":
                switch p["type"] as? String {
                case "token_count":
                    guard let info = p["info"] as? [String: Any] else { break }
                    if let w = JSONLTail.int(info["model_context_window"]), w > 0 { r.window = w }
                    // The size of the context as last sent: as given, never a sum of its parts.
                    guard let last = info["last_token_usage"] as? [String: Any],
                          let total = JSONLTail.int(last["total_tokens"]), total > 0 else { break }
                    if r.sizeAfterCompactionUnknown, case .compaction(let trigger, let pre, _)? = r.transcript.compaction {
                        r.transcript.compaction = .compaction(trigger: trigger, preTokens: pre, postTokens: total)
                        r.sizeAfterCompactionUnknown = false
                    }
                    r.transcript.latest = .response(tokens: total)
                    lastTokens = total
                case "task_started":
                    r.turn.startedAt = date(obj["timestamp"]) ?? r.turn.startedAt
                    r.turn.open = true
                    r.turn.hasContent = false
                    if let w = JSONLTail.int(p["model_context_window"]), w > 0 { r.window = w }
                case "task_complete":
                    r.turn.open = false
                    r.turn.aborted = false
                case "turn_aborted":
                    r.turn.open = false
                    r.turn.aborted = true
                case "user_message":
                    // Codex before 0.167.
                    r.turn.hasContent = true
                    seen(markerHits, in: &r)
                case "item_completed":
                    r.turn.hasContent = true
                    if (p["item"] as? [String: Any])?["type"] as? String == "UserMessage" { seen(markerHits, in: &r) }
                default:
                    break
                }
            case "response_item":
                r.turn.hasContent = true
            case "turn_context":
                if let m = p["model"] as? String, !m.isEmpty { r.model = m }
            case "compacted":
                // Codex doesn't say why. One in a turn of its own was asked for; one partway through
                // a turn is Codex making room by itself.
                let c = TranscriptReading.Latest.compaction(trigger: r.turn.hasContent ? "auto" : "manual",
                                                           preTokens: lastTokens, postTokens: nil)
                r.transcript.compaction = c
                r.transcript.latest = c
                r.sizeAfterCompactionUnknown = true
                lastTokens = nil
            default:
                break
            }
        }
    }

    /// Markers count only in your prompts, not in replies that quote them.
    static func seen(_ hits: [Data], in r: inout CodexReading) {
        for hit in hits {
            if let s = String(data: hit, encoding: .utf8) { r.transcript.markersSeen.insert(s) }
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
}
