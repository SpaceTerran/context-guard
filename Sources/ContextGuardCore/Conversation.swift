import Foundation

/// The conversation after a point in the transcript, as plain text Haiku can judge.
public struct Conversation: Equatable, Sendable {
    /// Oldest first, long tool output cut short, the oldest entries dropped to fit.
    public var text: String
    /// End offset of the last line that added to it. Unchanged means nothing new was said or done
    /// (Claude Code also writes bookkeeping lines while idle; those don't count).
    public var mark: UInt64
    /// Prompts and commands you sent in it.
    public var userPrompts: Int
    /// The marker it was read after (the save message's tag), if it was found.
    public var after: String?

    public init(text: String, mark: UInt64, userPrompts: Int, after: String?) {
        self.text = text
        self.mark = mark
        self.userPrompts = userPrompts
        self.after = after
    }
}

public enum ConversationReader {
    /// With no starting point, or one that's gone: how far back from the end to look for the marker.
    static let fallbackWindow: UInt64 = 8 * 1024 * 1024
    /// Never read more than this (the newest part wins).
    static let maxRead: UInt64 = 32 * 1024 * 1024
    public static let defaultLimit = 40_000

    /// The conversation after the line containing `marker`, reading from `from` (a line start at or
    /// before it). With `marker` nil, everything from `from`. If the marker never shows up, it's
    /// everything read, with `after` nil.
    public static func read(path: String, from: UInt64?, after marker: String?, limit: Int = defaultLimit) -> Conversation? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return nil }
        let size = UInt64(max(0, st.st_size))

        var start: UInt64
        var atLineStart: Bool
        if let from, from <= size {
            start = from
            atLineStart = true
        } else {
            start = size > fallbackWindow ? size - fallbackWindow : 0
            atLineStart = start == 0
        }
        if size - start > maxRead {
            start = size - maxRead
            atLineStart = false
        }
        guard let data = TranscriptReader.readRange(handle, from: start, to: size) else { return nil }
        let complete = TranscriptReader.completeLines(data, startsAtLineBoundary: atLineStart)
        let base = start - UInt64(data.startIndex)
        let markerBytes = marker.map { Data($0.utf8) }

        var entries: [String] = []
        var mark: UInt64 = 0
        var prompts = 0
        var found = markerBytes == nil
        for line in complete.lines {
            let lineEnd = base + UInt64(line.endIndex) + 1
            if !found, let markerBytes, line.range(of: markerBytes) != nil {
                // What came before the marker only counts if the marker never turns up.
                found = true
                entries = []
                mark = 0
                prompts = 0
                continue
            }
            guard let parsed = parse(line) else { continue }
            entries.append(contentsOf: parsed.entries)
            prompts += parsed.prompts
            if !parsed.entries.isEmpty { mark = lineEnd }
        }
        return Conversation(text: fit(entries, limit: limit), mark: mark, userPrompts: prompts, after: found ? marker : nil)
    }

    // MARK: - Lines

    private static let assistantNeedle = Data(#""type":"assistant""#.utf8)
    private static let userNeedle = Data(#""type":"user""#.utf8)

    struct Parsed {
        var entries: [String]
        var prompts: Int
    }

    /// One transcript line as conversation entries. nil for lines that aren't conversation.
    static func parse(_ line: Data) -> Parsed? {
        guard line.range(of: assistantNeedle) != nil || line.range(of: userNeedle) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String,
              obj["isSidechain"] as? Bool != true else { return nil }
        let message = obj["message"] as? [String: Any] ?? [:]
        switch type {
        case "assistant":
            if message["model"] as? String == "<synthetic>" && obj["isApiErrorMessage"] as? Bool != true { return nil }
            let prefix = obj["isApiErrorMessage"] as? Bool == true ? "Claude Code (API error)" : "Claude"
            var out: [String] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append("\(prefix): \(cut(t, 4_000))")
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "a tool"
                    out.append("Claude used \(name): \(cut(toolSummary(block["input"]), 300))")
                default:
                    break
                }
            }
            return Parsed(entries: out, prompts: 0)

        case "user":
            if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return nil }
            let origin = (obj["origin"] as? [String: Any])?["kind"] as? String
            let content = message["content"]
            if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }.map { b -> String in
                    let label = b["is_error"] as? Bool == true ? "Tool error" : "Tool result"
                    return "\(label): \(cut(text(of: b["content"]), 2_000))"
                }
                return Parsed(entries: results, prompts: 0)
            }
            let body = text(of: content)
            if body.isEmpty { return nil }
            if origin == "human" {
                return Parsed(entries: ["User: \(cut(body, 4_000))"], prompts: 1)
            }
            if let command = tag("command-name", in: body) {
                return Parsed(entries: ["User ran \(command)"], prompts: 1)
            }
            if origin == nil, body.hasPrefix("/"), let first = body.split(separator: "\n").first, !first.contains(" ") || first.count < 80 {
                // A slash command as typed, before Claude Code rewrites it in the <command-name> form.
                return Parsed(entries: ["User ran \(cut(String(first), 100))"], prompts: 1)
            }
            if let shell = tag("bash-input", in: body) {
                return Parsed(entries: ["User ran a shell command: \(cut(shell, 300))"], prompts: 1)
            }
            if body.hasPrefix("<local-command-stdout>") || body.hasPrefix("<local-command-stderr>")
                || body.hasPrefix("<bash-stdout>") || body.hasPrefix("<bash-stderr>") { return nil }
            if origin == "task-notification" || body.hasPrefix("<task-notification>") {
                let summary = tag("summary", in: body) ?? tag("status", in: body) ?? body
                return Parsed(entries: ["Background task event: \(cut(summary, 500))"], prompts: 0)
            }
            if origin == "plugin" {
                return Parsed(entries: ["Prompt from a plugin: \(cut(body, 1_000))"], prompts: 0)
            }
            return Parsed(entries: ["Message: \(cut(body, 1_000))"], prompts: 0)

        default:
            return nil
        }
    }

    /// The text inside `<name>…</name>`, trimmed.
    static func tag(_ name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)>"), let close = s.range(of: "</\(name)>", range: open.upperBound..<s.endIndex) else { return nil }
        let inner = s[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Text of a message or tool result: a string, or text blocks.
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { b -> String? in
            switch b["type"] as? String {
            case "text": return b["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    static func toolSummary(_ input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty { return v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func cut(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > n else { return t }
        return String(t.prefix(n)) + " […cut]"
    }

    /// Joins the entries, dropping the oldest until it fits.
    static func fit(_ entries: [String], limit: Int) -> String {
        var kept: [String] = []
        var total = 0
        for e in entries.reversed() {
            if total + e.count + 2 > limit, !kept.isEmpty { break }
            kept.append(e)
            total += e.count + 2
        }
        let dropped = entries.count - kept.count
        var text = kept.reversed().joined(separator: "\n\n")
        if dropped > 0 { text = "[\(dropped) earlier entries left out]\n\n" + text }
        return text
    }
}

public enum JudgePrompt {
    /// What Haiku is asked. The session's own words decide it; Haiku never acts on it.
    public static func make(message: String, conversation: String, idleFor: TimeInterval) -> String {
        let idle = idleFor >= 120 ? " It has been idle for \(Int(idleFor / 60)) minutes." : ""
        return """
        You are checking on a Claude Code session for its user. The user sent the session this message:

        <message>
        \(message)
        </message>

        This is everything the session did after that message, oldest first. Long tool output is cut short.

        <session>
        \(conversation)
        </session>

        The session has finished its turn and is waiting.\(idle) Is it ready for its conversation to be compacted now?

        - ready: it acted on the message and has finished saving what it needed to (committing, pushing, writing notes, checking in), and its last message reports that or says it's ready. It isn't waiting on anything it started.
        - working: it is partway through saving, or says it is waiting for something it started (a push, a build, CI, a background task) before it's ready.
        - needs_user: its last message asks the user a question, asks for a decision or approval, or says it is blocked on them. Also when it declined or ignored the message, for example because it doubted the message came from the user: only the user can settle that.

        If the user asked for more work after the message, it is ready only once that work is done too.

        Answer with only this JSON and nothing else:
        {"verdict": "ready" | "working" | "needs_user", "reason": "why, in under 10 words"}
        """
    }
}

public struct JudgeReply: Equatable, Sendable {
    public var verdict: FollowUp.Verdict
    public var reason: String?

    /// Reads Haiku's answer: the first JSON object in it. nil if there's no usable verdict.
    public static func parse(_ text: String) -> JudgeReply? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [String: Any],
              let raw = obj["verdict"] as? String else { return nil }
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        let verdict: FollowUp.Verdict
        switch key {
        case "ready": verdict = .ready
        case "working": verdict = .working
        case "needs_user", "needsuser": verdict = .needsUser
        default: return nil
        }
        var reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if let r = reason, r.isEmpty { reason = nil }
        if let r = reason, r.count > 120 { reason = String(r.prefix(120)) + "…" }
        return JudgeReply(verdict: verdict, reason: reason)
    }
}
