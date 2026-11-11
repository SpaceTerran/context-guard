import Foundation

/// A Codex session's conversation after a point in its rollout, as plain text the judge reads.
/// The same windowing and trimming as `ConversationReader`, with Codex's own line format.
public enum CodexConversation {
    /// The conversation after the prompt containing `marker`, reading from `from` (a line start at
    /// or before it). With `marker` nil, everything from `from`.
    public static func read(path: String, from: UInt64?, after marker: String?,
                            limit: Int = ConversationReader.defaultLimit) -> Conversation? {
        let markerBytes = marker.map { Data($0.utf8) }
        return ConversationReader.read(path: path, from: from, after: marker, limit: limit,
                                       parse: { parse($0, marker: markerBytes) })
    }

    private static let needles = [#""type":"event_msg""#, #""type":"response_item""#].map { Data($0.utf8) }

    /// One rollout line as conversation entries. nil for lines that aren't conversation: reasoning,
    /// sizes, settings, the context Codex adds to each turn (`response_item` messages), and the
    /// save message itself, which the judge is given on its own.
    static func parse(_ line: Data, marker: Data?) -> ConversationReader.Parsed? {
        guard needles.contains(where: { line.range(of: $0) != nil }),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String,
              let p = obj["payload"] as? [String: Any] else { return nil }
        let cut = ConversationReader.cut

        switch (type, p["type"] as? String) {
        case ("event_msg", "item_completed"):
            // Codex 0.167: each prompt and reply is an item.
            let item = p["item"] as? [String: Any] ?? [:]
            switch item["type"] as? String {
            case "UserMessage":
                if let marker, line.range(of: marker) != nil { return nil }
                return prompt(text(of: item["content"]))
            case "AgentMessage":
                return reply(text(of: item["content"]))
            default:
                return nil
            }

        case ("event_msg", "user_message"):
            // Codex before 0.167.
            if let marker, line.range(of: marker) != nil { return nil }
            return prompt(p["message"] as? String ?? "")

        case ("event_msg", "agent_message"):
            return reply(p["message"] as? String ?? "")

        case ("event_msg", "turn_aborted"):
            let reason = p["reason"] as? String
            return .init(entries: [reason == nil || reason == "interrupted" ? "The user interrupted the turn."
                                       : "The turn ended early (\(reason ?? ""))."], prompts: 0)

        case ("event_msg", "error"):
            let text = p["message"] as? String ?? "no details"
            return .init(entries: ["Codex error: \(cut(text, 500))"], prompts: 0)

        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            let name = p["name"] as? String ?? (p["type"] as? String == "local_shell_call" ? "the shell" : "a tool")
            return .init(entries: ["Codex used \(name): \(cut(toolSummary(p), 300))"], prompts: 0)

        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
            return .init(entries: ["Tool result: \(cut(output(p["output"]), 2_000))"], prompts: 0)

        case ("response_item", "web_search_call"):
            let query = (p["action"] as? [String: Any])?["query"] as? String
            return .init(entries: ["Codex searched the web" + (query.map { ": \(cut($0, 300))" } ?? "")], prompts: 0)

        default:
            return nil
        }
    }

    static func prompt(_ raw: String) -> ConversationReader.Parsed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.hasPrefix("/"), let first = text.split(separator: "\n").first, !first.contains(" ") {
            return .init(entries: ["User ran \(ConversationReader.cut(String(first), 100))"], prompts: 1)
        }
        return .init(entries: ["User: \(ConversationReader.cut(text, 4_000))"], prompts: 1)
    }

    static func reply(_ text: String) -> ConversationReader.Parsed? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return .init(entries: ["Codex: \(ConversationReader.cut(text, 4_000))"], prompts: 0)
    }

    /// The text items of an item's content.
    static func text(of content: Any?) -> String {
        (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// What a tool call did: its command, else its arguments.
    static func toolSummary(_ p: [String: Any]) -> String {
        if let input = p["input"] as? String { return input }
        var args = p["action"] as? [String: Any] ?? [:]
        if let raw = p["arguments"] as? String,
           let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            args = parsed
        } else if let raw = p["arguments"] as? String {
            return raw
        }
        for key in ["cmd", "command"] {
            if let s = args[key] as? String, !s.isEmpty { return s }
            // `["bash", "-lc", "…"]`: the script is what was run.
            if let parts = args[key] as? [String], let last = parts.last { return last }
        }
        return ConversationReader.toolSummary(args)
    }

    /// A tool's output: a string (sometimes JSON with an `output` field) or text items.
    static func output(_ value: Any?) -> String {
        if let s = value as? String {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
               let inner = obj["output"] as? String { return inner }
            return s
        }
        if let items = value as? [[String: Any]] {
            // Chunks of one output, in order: Codex ends each with its own newlines.
            return items.compactMap { $0["text"] as? String }.joined()
        }
        if let obj = value as? [String: Any], let inner = obj["content"] as? String { return inner }
        return ""
    }
}
