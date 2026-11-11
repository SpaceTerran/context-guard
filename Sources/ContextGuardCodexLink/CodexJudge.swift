import Foundation

/// Asks a small OpenAI model, through your own Codex sign-in, whether a Codex session has finished
/// saving: the counterpart of Haiku for Claude Code sessions. Each question is a throwaway thread
/// in the app server with no tools, hooks, plugins, MCP servers or project instructions, and an
/// output schema for the answer.
public enum CodexJudge {
    /// The smallest models first. Whichever this sign-in offers first is used.
    public static let preferredModels = ["gpt-6-luna", "gpt-5.6-luna"]
    /// Under `Compactor.judgeAbandoned`, so a question is never asked twice at once.
    public static let timeout: TimeInterval = 60
    public static let instructions =
        "You are a strict judge. Read the user's message and reply with JSON only that matches the required schema. Never use tools."

    public static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "verdict": ["type": "string", "enum": ["ready", "working", "needs_user"]],
            "reason": ["type": "string", "maxLength": 200],
        ],
        "required": ["verdict", "reason"],
        "additionalProperties": false,
    ]

    /// Off for the judge's thread, so it can only read the question and answer.
    static let featuresOff = [
        "apps", "code_mode", "code_mode_only", "context_management", "current_time_reminder",
        "deferred_executor", "goals", "hooks", "image_generation", "memories", "multi_agent",
        "multi_agent_v2", "plugins", "request_permissions_tool", "shell_snapshot", "shell_tool",
        "standalone_web_search", "token_budget", "tool_suggest", "unified_exec", "view_image",
    ]

    /// The model to judge with, from `model/list`. nil: none of the small ones, so the session's own
    /// model judges.
    public static func pickModel(_ models: [CodexModelInfo]) -> String? {
        let offered = Set(models.filter { !$0.hidden }.map(\.id))
        return preferredModels.first(where: offered.contains)
    }

    public static func threadParams(model: String, cwd: String, mcpServers: [String]) -> JSONValue {
        var config: [String: JSONValue] = [:]
        for feature in featuresOff { config["features.\(feature)"] = false }
        config["cloud.skills.enabled"] = false
        config["skills.include_instructions"] = false
        config["tools.experimental_request_user_input.enabled"] = false
        config["tools.update_plan.enabled"] = false
        config["web_search"] = "disabled"
        config["include_permissions_instructions"] = false
        config["include_apps_instructions"] = false
        config["include_collaboration_mode_instructions"] = false
        if !mcpServers.isEmpty {
            config["mcp_servers"] = .object(Dictionary(uniqueKeysWithValues: mcpServers.map { ($0, ["enabled": false]) }))
        }
        return [
            "model": .string(model),
            "modelProvider": "openai",
            // An empty folder of Context Guard's, so no project instructions (AGENTS.md) are read.
            "cwd": .string(cwd),
            "sandbox": "read-only",
            "runtimeWorkspaceRoots": [],
            "ephemeral": true,
            "environments": [],
            "dynamicTools": [],
            "selectedCapabilityRoots": [],
            "config": .object(config),
            "baseInstructions": .string(instructions),
        ]
    }

    public static func turnParams(threadId: String, prompt: String) -> JSONValue {
        [
            "threadId": .string(threadId),
            "input": [["type": "text", "text": .string(prompt), "text_elements": []]],
            "outputSchema": schema,
            "effort": "low",
        ]
    }

    /// The final answer in a finished turn (`turn/completed`).
    public static func answer(in turn: JSONValue) -> String? {
        let messages = (turn["items"]?.array ?? []).filter { $0["type"]?.string == "agentMessage" }
        let final = messages.last(where: { $0["phase"]?.string == "final_answer" }) ?? messages.last
        return final?["text"]?.string
    }

    /// Asks once. The answer's text, or why there's none. `waiters` must get the connection's events.
    public static func ask(_ prompt: String, model: String, cwd: String, mcpServers: [String],
                           daemon: CodexDaemon, waiters: TurnWaiters, callTimeout: TimeInterval,
                           timeout: TimeInterval = CodexJudge.timeout) -> Result<String, CodexLinkError> {
        let thread: JSONValue
        do {
            thread = try daemon.call("thread/start", threadParams(model: model, cwd: cwd, mcpServers: mcpServers), timeout: callTimeout)
        } catch {
            return .failure(error as? CodexLinkError ?? .closed("\(error)"))
        }
        guard let threadId = thread["thread"]?["id"]?.string else {
            return .failure(.protocolError("thread/start gave no thread"))
        }
        // Waiting before the turn starts, so its end can't be missed.
        let waiter = waiters.register(threadId)
        defer {
            waiters.remove(threadId)
            // Ephemeral: once nobody follows it, the app server drops it.
            _ = try? daemon.call("thread/unsubscribe", ["threadId": .string(threadId)], timeout: callTimeout)
        }
        let turnId: String?
        do {
            turnId = try daemon.call("turn/start", turnParams(threadId: threadId, prompt: prompt), timeout: callTimeout)["turn"]?["id"]?.string
        } catch {
            return .failure(error as? CodexLinkError ?? .closed("\(error)"))
        }
        guard let outcome = waiter.wait(timeout: timeout) else {
            if let turnId {
                _ = try? daemon.call("turn/interrupt", ["threadId": .string(threadId), "turnId": .string(turnId)], timeout: callTimeout)
            }
            return .failure(.timeout("the judge"))
        }
        switch outcome {
        case .closed(let why):
            return .failure(.closed(why))
        case .finished(let turn, let lastMessage):
            let status = turn["status"]?.string ?? "completed"
            guard status == "completed" else {
                return .failure(.closed(turn["error"]?["message"]?.string ?? "its turn \(status)"))
            }
            guard let text = answer(in: turn) ?? lastMessage, !text.isEmpty else {
                return .failure(.protocolError("an empty answer"))
            }
            return .success(text)
        }
    }
}

/// Turns the link waits on (the judge's), fed from the connection's events.
public final class TurnWaiters: @unchecked Sendable {
    public enum Outcome: Sendable {
        /// `turn/completed`'s turn, and the last agent message seen on the way.
        case finished(turn: JSONValue, lastMessage: String?)
        case closed(String)
    }

    public final class Waiter: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: Outcome?
        fileprivate var lastMessage: String?

        fileprivate func finish(_ o: Outcome) {
            lock.lock()
            let first = outcome == nil
            if first { outcome = o }
            lock.unlock()
            if first { done.signal() }
        }

        fileprivate func note(_ text: String) {
            lock.lock()
            lastMessage = text
            lock.unlock()
        }

        fileprivate var noted: String? {
            lock.lock()
            defer { lock.unlock() }
            return lastMessage
        }

        public func wait(timeout: TimeInterval) -> Outcome? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    private let lock = NSLock()
    private var waiting: [String: Waiter] = [:]

    public init() {}

    public func register(_ threadId: String) -> Waiter {
        let w = Waiter()
        lock.lock()
        waiting[threadId] = w
        lock.unlock()
        return w
    }

    public func remove(_ threadId: String) {
        lock.lock()
        waiting.removeValue(forKey: threadId)
        lock.unlock()
    }

    private func waiter(_ threadId: String?) -> Waiter? {
        guard let threadId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return waiting[threadId]
    }

    /// Feeds one event in. Returns whether it was about a turn being waited on.
    @discardableResult
    public func handle(_ event: CodexEvent) -> Bool {
        switch event {
        case .notification(let method, let params):
            switch method {
            case "turn/completed":
                guard let w = waiter(params["threadId"]?.string) else { return false }
                w.finish(.finished(turn: params["turn"] ?? .null, lastMessage: w.noted))
                return true
            case "item/completed":
                guard let w = waiter(params["threadId"]?.string), params["item"]?["type"]?.string == "agentMessage",
                      let text = params["item"]?["text"]?.string else { return false }
                w.note(text)
                return true
            case "thread/closed":
                guard let w = waiter(params["threadId"]?.string) else { return false }
                w.finish(.closed("its thread closed"))
                return true
            default:
                return false
            }
        case .request:
            return false
        case .closed(let why):
            lock.lock()
            let all = Array(waiting.values)
            lock.unlock()
            for w in all { w.finish(.closed(why)) }
            return !all.isEmpty
        }
    }
}
