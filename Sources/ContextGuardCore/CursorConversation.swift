import Foundation

/// A Cursor chat's conversation after a point in its transcript (`agent-transcripts/<id>/<id>.jsonl`),
/// as plain text the judge reads. The same windowing and trimming as `ConversationReader`, with
/// Cursor's own line format: `{"role": "user"|"assistant", "message": {"content": [...]}}`, and
/// `{"type": "turn_ended", "status": ...}` at the end of a turn. Tool results aren't in it.
public enum CursorConversation {
    /// The conversation after the prompt containing `marker`, reading from `from` (where the
    /// transcript ended when the save message was handed over). A save message that went in
    /// mid-turn isn't in the transcript, so with no line holding the marker, everything from `from`
    /// is what came after it.
    public static func read(path: String, from: UInt64?, after marker: String,
                            limit: Int = ConversationReader.defaultLimit) -> Conversation? {
        let markerBytes = Data(marker.utf8)
        guard var c = ConversationReader.read(path: path, from: from, after: marker, limit: limit,
                                              parse: { parse($0, marker: markerBytes) }) else { return nil }
        if c.after == nil, from != nil { c.after = marker }
        return c
    }

    /// Everything from `from`: what was said after the compaction began.
    public static func read(path: String, from: UInt64) -> Conversation? {
        ConversationReader.read(path: path, from: from, after: nil, limit: ConversationReader.defaultLimit,
                                parse: { parse($0, marker: nil) })
    }

    /// Whether a prompt holding `marker` went into the chat after `from`. The Cursor CLI sends a
    /// hook's follow-up as a new turn without `beforeSubmitPrompt`, so this is how one is seen there.
    public static func prompted(path: String, from: UInt64?, marker: String) -> Bool {
        let markerBytes = Data(marker.utf8)
        var seen = false
        _ = ConversationReader.read(path: path, from: from, after: nil, limit: 0) { line in
            guard !seen, line.range(of: markerBytes) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  obj["role"] as? String == "user" else { return nil }
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            seen = query(in: text(of: content))?.contains(marker) ?? false
            return nil
        }
        return seen
    }

    private static let needles = [#""role""#, #""turn_ended""#].map { Data($0.utf8) }

    /// One transcript line as conversation entries. nil for lines that aren't conversation: what
    /// Cursor adds to a chat on its own (the list of subagents, rules), and the save message itself,
    /// which the judge is given on its own.
    static func parse(_ line: Data, marker: Data?) -> ConversationReader.Parsed? {
        guard needles.contains(where: { line.range(of: $0) != nil }),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let cut = ConversationReader.cut

        if obj["type"] as? String == "turn_ended" {
            let status = obj["status"] as? String ?? "success"
            guard status != "success" else { return nil }
            return .init(entries: [status == "aborted" || status == "cancelled" ? "The user stopped the turn."
                                       : "The turn ended early (\(status))."], prompts: 0)
        }
        let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch obj["role"] as? String {
        case "user":
            if let marker, line.range(of: marker) != nil { return nil }
            guard let prompt = query(in: text(of: content)) else { return nil }
            if prompt.hasPrefix("/"), let first = prompt.split(separator: "\n").first, !first.contains(" ") {
                return .init(entries: ["User ran \(cut(String(first), 100))"], prompts: 1)
            }
            return .init(entries: ["User: \(cut(prompt, 4_000))"], prompts: 1)

        case "assistant":
            var out: [String] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append("Cursor: \(cut(t, 4_000))")
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "a tool"
                    out.append("Cursor used \(name): \(cut(ConversationReader.toolSummary(block["input"]), 300))")
                default:
                    break
                }
            }
            return out.isEmpty ? nil : .init(entries: out, prompts: 0)

        default:
            return nil
        }
    }

    /// What you typed: the text inside `<user_query>`. Cursor wraps each prompt in it, after a
    /// `<timestamp>`; a user line without it is context Cursor added by itself.
    static func query(in text: String) -> String? {
        ConversationReader.tag("user_query", in: text)
    }

    static func text(of content: [[String: Any]]) -> String {
        content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
}
