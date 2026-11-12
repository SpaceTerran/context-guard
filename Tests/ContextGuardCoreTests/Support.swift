import Foundation
import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

/// Lines shaped like Claude Code's transcript JSONL (compact JSON, one record per line).
enum Line {
    static func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    static func response(input: Int = 2, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0,
                         sidechain: Bool = false, model: String = "claude-opus-5-5", error: Bool = false,
                         iterations: [[String: Any]]? = nil, text: String = "ok") -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "cache_creation_input_tokens": cacheWrite,
            "cache_read_input_tokens": cacheRead, "output_tokens": output,
        ]
        if let iterations { usage["iterations"] = iterations }
        var obj: [String: Any] = [
            "type": "assistant", "isSidechain": sidechain, "uuid": UUID().uuidString,
            "message": ["model": model, "role": "assistant", "content": [["type": "text", "text": text]], "usage": usage],
        ]
        if error { obj["isApiErrorMessage"] = true }
        return json(obj)
    }

    /// A response whose whole context is `tokens` (all in cache reads).
    static func context(_ tokens: Int) -> String { response(input: 0, cacheRead: tokens) }

    /// A reply in a big session.
    static func reply(_ text: String, tokens: Int = 311_000) -> String { response(input: 0, cacheRead: tokens, text: text) }

    static func compaction(pre: Int, post: Int, trigger: String = "manual") -> String {
        json(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["trigger": trigger, "preTokens": pre, "postTokens": post]])
    }

    static func title(_ t: String) -> String { json(["type": "ai-title", "aiTitle": t]) }

    static func user(_ text: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func attachment(_ text: String) -> String {
        json(["type": "attachment", "attachment": ["type": "hook_additional_context", "content": [text]]])
    }

    /// A prompt you typed.
    static func prompt(_ text: String) -> String {
        json(["type": "user", "origin": ["kind": "human"], "message": ["role": "user", "content": text]])
    }

    /// A prompt a plugin submitted as the user (the mod's continue message).
    static func pluginPrompt(_ text: String) -> String {
        json(["type": "user", "origin": ["kind": "plugin", "name": "context-guard", "asUser": true], "message": ["role": "user", "content": text]])
    }

    /// The idle Stop hook's wake, as Claude Code records it.
    static func wake(_ text: String) -> String {
        json(["type": "user", "origin": ["kind": "task-notification", "producer": "session-task"],
              "message": ["role": "user", "content": "<task-notification>\n<summary>Context Guard: save before compacting</summary>\n</task-notification>\n<system-reminder>\nStop hook message: \(text)\n</system-reminder>"]])
    }

    static func command(_ name: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": "<command-name>\(name)</command-name>\n<command-message>x</command-message>"]])
    }

    static func toolUse(_ name: String, _ input: [String: Any], text: String? = nil) -> String {
        var content: [[String: Any]] = []
        if let text { content.append(["type": "text", "text": text]) }
        content.append(["type": "tool_use", "id": "toolu_1", "name": name, "input": input])
        return json(["type": "assistant", "isSidechain": false,
                     "message": ["model": "claude-opus-5-5", "role": "assistant", "content": content,
                                 "usage": ["input_tokens": 1, "cache_read_input_tokens": 310_000, "output_tokens": 5]]])
    }

    static func toolResult(_ text: String, error: Bool = false) -> String {
        json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": text, "is_error": error]]]])
    }

    /// Bookkeeping Claude Code writes around turns, even while idle.
    static func bookkeeping() -> String {
        json(["type": "last-prompt", "lastPrompt": "x"]) + "\n" + json(["type": "permission-mode", "permissionMode": "default"])
    }

    static func compactSummary() -> String {
        json(["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": "This session is being continued…"]])
    }
}

/// A process table the tests control.
final class FakeProbe: ProcessProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: ProcessIdentity] = [:]

    func set(_ pid: Int32, _ id: ProcessIdentity?) {
        lock.lock(); defer { lock.unlock() }
        table[pid] = id
    }

    func identity(of pid: Int32) -> ProcessIdentity? {
        lock.lock(); defer { lock.unlock() }
        return table[pid]
    }
}

final class FakeRegistry: RegistryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int32: RegistryEntry] = [:]
    var available = true

    func set(_ entry: RegistryEntry) {
        lock.lock(); defer { lock.unlock() }
        entries[entry.pid] = entry
    }

    func remove(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        entries[pid] = nil
    }

    func entry(pid: Int32) -> RegistryEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[pid]
    }

    func all() -> [RegistryEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.values)
    }

    var isAvailable: Bool { available }
}

extension SessionState {
    /// A guarded session at `tokens`, for rule tests.
    static func guarded(_ tokens: Int, phase: Phase = .watching, cycle: Int = 0) -> SessionState {
        var s = SessionState(sessionId: "s1", now: Date())
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.cycle = cycle
        return s
    }
}

extension TranscriptReading {
    /// A read with one response.
    static func tokens(_ t: Int) -> TranscriptReading {
        var r = TranscriptReading()
        r.latest = .response(tokens: t)
        r.firstTokens = t
        return r
    }
}

/// One guarded session with its transcript, process and registry entry, for tests that run the
/// hooks and the mod against real files.
class HookTestCase: XCTestCase {
    let dir = TempDir()
    let sid = "11111111-2222-3333-4444-555555555555"
    let claude: Int32 = 4242
    let start = ProcessStart(seconds: 1_790_000_000, microseconds: 7)
    let clock = TestClock()
    var probe: FakeProbe!
    var registry: FakeRegistry!
    var paths: Paths!
    var transcript: Transcript!

    override func setUp() {
        probe = FakeProbe()
        registry = FakeRegistry()
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        transcript = Transcript(dir)
        probe.set(claude, ProcessIdentity(start: start, hasTTY: true))
        probe.set(ProcessInfo.processInfo.processIdentifier, ProcessIdentity(start: ProcessStart(seconds: 1, microseconds: 1), hasTTY: false))
        registry.set(RegistryEntry(pid: claude, sessionId: sid, kind: "interactive", entrypoint: "cli", name: "code-a6", status: "idle", cwd: "/Users/x/code"))
    }

    func setStatus(_ status: String?) {
        registry.set(RegistryEntry(pid: claude, sessionId: sid, kind: "interactive", entrypoint: "cli", name: "code-a6", status: status, cwd: "/Users/x/code"))
    }

    var runner: HookRunner {
        let clock = self.clock
        return HookRunner(paths: paths, claudePid: claude, environment: [:], probe: probe, registry: registry, clock: { clock.now })
    }

    var mod: ModRunner {
        let clock = self.clock
        return ModRunner(paths: paths, probe: probe, registry: registry, clock: { clock.now })
    }

    func event(_ name: String, agent: String? = nil, source: String? = nil, contextTokens: Int? = nil) -> HookInput {
        HookInput(event: name, sessionId: sid, transcriptPath: transcript.path, cwd: "/Users/x/code", agentId: agent, source: source, contextTokens: contextTokens)
    }

    var state: SessionState? { SessionState.load(sid, paths) }

    func answer(_ action: Answer.Action, from source: Answer.Source = .popup) throws {
        try Answer(cycle: state?.cycle ?? 0, action: action, source: source, at: Date()).save(for: sid, paths)
    }

    /// Saves settings, with `enabledAt` stamped well before now unless the change sets it.
    func configure(_ change: (inout Config) -> Void = { _ in }) throws {
        var c = Config()
        c.enabledAt = clock.now.addingTimeInterval(-3_600)
        change(&c)
        try c.save(paths)
    }

    func watch(_ on: Bool) throws {
        try Mute.set(!on, for: XCTUnwrap(state), paths)
    }

    /// Makes the transcript look untouched for `seconds` (the mod waits for a quiet transcript).
    func settle(_ seconds: TimeInterval = 5) throws {
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-seconds)], ofItemAtPath: transcript.path)
    }

    /// Runs the waiter on a background thread so the test can answer while it waits.
    func startWaiter(token: String, maxDuration: TimeInterval = 10) -> XCTestExpectation_Result {
        let result = XCTestExpectation_Result()
        let r = runner
        let id = sid
        Thread.detachNewThread {
            let out = r.runWaiter(sessionId: id, token: token, maxDuration: maxDuration, poll: 0.05)
            result.finish(out)
        }
        return result
    }
}
