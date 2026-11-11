import Foundation

// Fixtures both test targets use: temporary folders, transcript files, a clock tests move on, and
// Codex rollout lines.

public final class TempDir: @unchecked Sendable {
    public let url: URL

    public init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cg-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A JSONL file a test writes to, line by line.
public final class Transcript: @unchecked Sendable {
    public let url: URL

    public init(_ dir: TempDir, name: String = "t.jsonl") {
        url = dir.file(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    public var path: String { url.path }

    public func append(_ lines: String..., newline: Bool = true) {
        appendRaw(lines.joined(separator: "\n") + (newline ? "\n" : ""))
    }

    public func append(_ lines: [String]) {
        appendRaw(lines.joined(separator: "\n") + "\n")
    }

    public func appendRaw(_ s: String) {
        let h = try! FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data(s.utf8))
        try! h.close()
    }

    public var size: UInt64 { (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).uint64Value }
}

/// Real time, shifted by however far a test moved it on.
public final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    public init() {}

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return Date().addingTimeInterval(offset)
    }

    public func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        offset += seconds
    }
}

/// Lines shaped like a Codex 0.167 rollout (taken from real ones, with demo values).
public enum CodexLine {
    public static let thread = "01a1c7f0-4d8a-7870-aab2-07bc76ea7408"
    public static let turnId = "01a1c7f1-22f1-7d70-a4ee-1ed9b0f60470"

    public static func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func line(_ type: String, _ payload: [String: Any], at: String = "2026-11-11T00:10:31.944Z") -> String {
        json(["timestamp": at, "type": type, "payload": payload])
    }

    public static func event(_ payload: [String: Any], at: String = "2026-11-11T00:10:31.944Z") -> String { line("event_msg", payload, at: at) }

    public static func meta(id: String = thread, cwd: String = "/Users/demo/code", originator: String = "codex-tui",
                            source: Any = "vscode", threadSource: String = "user", history: String = "paginated",
                            instructions: Int = 48_000) -> String {
        line("session_meta", ["id": id, "session_id": id, "cwd": cwd, "originator": originator,
                              "cli_version": "0.167.1", "source": source, "thread_source": threadSource,
                              "model_provider": "openai", "history_mode": history,
                              "base_instructions": String(repeating: "You are Codex. ", count: instructions / 15)],
             at: "2026-11-11T00:09:36.928Z")
    }

    public static func taskStarted(at: String = "2026-11-11T00:10:31.574Z") -> String {
        event(["type": "task_started", "turn_id": turnId, "started_at": 1_794_355_831, "model_context_window": 258_400,
               "collaboration_mode_kind": "default"], at: at)
    }

    public static func turnContext(model: String = "gpt-6-luna") -> String {
        line("turn_context", ["turn_id": turnId, "cwd": "/Users/demo/code", "model": model, "approval_policy": "on-request"])
    }

    public static func injected(_ text: String = "# AGENTS.md instructions for /Users/demo/code") -> String {
        line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]])
    }

    public static func prompt(_ text: String, clientId: String = "6a3c1f9e-0000-4000-8000-000000000001") -> String {
        event(["type": "item_completed", "thread_id": thread, "turn_id": turnId,
               "item": ["type": "UserMessage", "id": "01a1c7f1-2487", "client_id": clientId,
                        "content": [["type": "text", "text": text, "text_elements": [Any]()]]]])
    }

    public static func reply(_ text: String, phase: String = "final_answer") -> String {
        event(["type": "item_completed", "thread_id": thread, "turn_id": turnId,
               "item": ["type": "AgentMessage", "id": "msg_03c7", "content": [["type": "Text", "text": text]], "phase": phase]])
    }

    public static func replyRecord(_ text: String) -> String {
        line("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
    }

    public static func reasoning() -> [String] {
        [event(["type": "item_completed", "item": ["type": "Reasoning", "id": "rs_1", "summary_text": [Any](), "raw_content": [Any]()]]),
         line("response_item", ["type": "reasoning", "id": "rs_1", "summary": [Any](), "encrypted_content": "gAAAA"])]
    }

    public static func toolCall(_ name: String = "exec", input: String = "await tools.exec_command({cmd: \"git push\"})") -> String {
        line("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "call_1", "name": name, "input": input])
    }

    public static func functionCall(_ name: String, _ args: [String: Any]) -> String {
        let raw = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return line("response_item", ["type": "function_call", "name": name, "arguments": raw, "call_id": "call_2"])
    }

    public static func toolOutput(_ text: String) -> String {
        line("response_item", ["type": "custom_tool_call_output", "call_id": "call_1",
                               "output": [["type": "input_text", "text": "Script completed\n"], ["type": "input_text", "text": text]]])
    }

    public static func tokens(_ total: Int, window: Int = 258_400) -> String {
        let usage: [String: Any] = ["input_tokens": total - 69, "cached_input_tokens": 0, "output_tokens": 69,
                                    "reasoning_output_tokens": 60, "total_tokens": total]
        return event(["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage,
                                                      "last_usage_includes_reasoning": true, "model_context_window": window],
                      "rate_limits": ["limit_id": "codex"]])
    }

    public static func usageRecord(_ total: Int) -> String {
        line("token_usage_record", ["thread_id": thread, "turn_id": turnId, "usage": ["total_tokens": total]])
    }

    public static func taskComplete() -> String {
        event(["type": "task_complete", "turn_id": turnId, "last_agent_message": "ok", "duration_ms": 2_644])
    }

    public static func turnAborted(_ reason: String = "interrupted") -> String {
        event(["type": "turn_aborted", "turn_id": turnId, "reason": reason])
    }

    public static func compacted() -> [String] {
        [line("compacted", ["message": "", "replacement_history": [["type": "message", "role": "user",
                                                                     "content": [["type": "input_text", "text": "Earlier: Codex pushed the branch."]]]]]),
         event(["type": "context_compacted"])]
    }

    /// A compaction on a turn of its own (`thread/compact/start` or `/compact`), line for line as
    /// Codex 0.167 writes it: no context_compacted event, a ContextCompaction item instead.
    public static func compactionTurn(after: Int) -> [String] {
        [event(["type": "task_started", "turn_id": turnId, "started_at": 1_794_355_875, "model_context_window": 258_400,
                "collaboration_mode_kind": "default"]),
         usageRecord(21_498),
         line("compacted", ["message": "", "replacement_history": [["type": "message", "role": "user",
                                                                     "content": [["type": "input_text", "text": "Earlier: Codex pushed the branch."]]]]]),
         line("world_state", ["full": true, "state": ["agents_md": ["directory": "/Users/demo/code", "text": "# AGENTS.md"]]]),
         turnContext(),
         event(["type": "thread_settings_applied", "thread_id": thread, "thread_settings": ["model": "gpt-6-luna"]]),
         tokens(after),
         event(["type": "item_completed", "thread_id": thread, "turn_id": turnId,
                "item": ["type": "ContextCompaction", "id": "01a1c7f1-cd30"]]),
         taskComplete()]
    }

    /// Esc during a compaction, as Codex 0.167 writes it: the turn ends with no compacted line.
    public static func compactionInterrupted(at: String = "2026-11-11T00:15:52.660Z") -> [String] {
        [taskStarted(at: at),
         line("response_item", ["type": "message", "role": "developer",
                                "content": [["type": "input_text", "text": "<turn_aborted>\nThe previous turn was interrupted on purpose."]]]),
         turnAborted()]
    }

    /// A whole turn: your prompt, a tool call, a reply, the size after it.
    public static func turn(_ prompt: String, reply: String, tokens: Int, clientId: String = UUID().uuidString.lowercased()) -> [String] {
        [taskStarted(), turnContext(), CodexLine.prompt(prompt, clientId: clientId)] + reasoning()
            + [toolCall(), toolOutput("main -> main"), CodexLine.reply(reply), replyRecord(reply), usageRecord(tokens),
               CodexLine.tokens(tokens), taskComplete()]
    }
}
