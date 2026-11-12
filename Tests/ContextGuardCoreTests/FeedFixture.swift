import ContextGuardTestSupport
import Foundation
@testable import ContextGuardCore

/// A Context Guard folder, Claude Code's registry and processes, and a `Feed` over them: for the
/// `ui` feed's tests and its contract files. Sessions are in Windows folders, which read the same
/// on both platforms, and a save's time reads "3:41 PM" whatever the computer's clock and locale.
final class FeedFixture {
    let dir = TempDir()
    let t0 = Date(timeIntervalSince1970: 1_790_000_100)
    let start = ProcessStart(seconds: 1_790_000_000, microseconds: 7)
    let paths: Paths
    let probe = FakeProbe()
    let registry = FakeRegistry()
    /// The Codex link's background program is installed.
    var linkInstalled = false

    /// Settings as they are, turned on an hour before `t0`.
    init() {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        try? paths.ensureDirectories()
        var c = Config()
        c.enabledAt = t0.addingTimeInterval(-3_600)
        try? c.save(paths)
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A feed over this folder, made at `t0`. Call `start` first.
    func feed() -> Feed {
        Feed(paths: paths, registry: registry, probe: probe, codexLinkInstalled: { [weak self] in self?.linkInstalled ?? false },
             now: t0, time: { _ in "3:41 PM" })
    }

    func config(_ change: (inout Config) -> Void) throws {
        var c = Config.load(paths)
        change(&c)
        try c.save(paths)
    }

    /// A Claude Code session whose process runs, idle unless `status` says otherwise, asked at `t0`
    /// when it's asking. With `waiter`, its background Stop hook waits, so it can be reached at once.
    @discardableResult
    func session(_ n: Int, title: String? = nil, cwd: String? = nil, tokens: Int = 302_000, phase: Phase = .asking,
                 status: String = "idle", waiter: Bool = false, change: (inout SessionState) -> Void = { _ in }) throws -> String {
        let id = "00000000-0000-4000-8000-00000000000\(n)"
        let pid = Int32(4_000 + n)
        var s = SessionState(sessionId: id, now: t0)
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.cycle = 1
        s.title = title ?? "Session \(n)"
        s.cwd = cwd ?? #"C:\code\s\#(n)"#
        s.claudePid = pid
        s.claudeStart = start
        if phase == .asking { s.askedAt = t0 }
        if waiter {
            s.waiterToken = "waiter-\(n)"
            s.waiterPid = pid + 1_000
            s.waiterStart = start
            probe.set(pid + 1_000, ProcessIdentity(start: start, hasTTY: false))
        }
        change(&s)
        try s.save(paths)
        probe.set(pid, ProcessIdentity(start: start, hasTTY: true))
        registry.set(RegistryEntry(pid: pid, sessionId: id, kind: "interactive", entrypoint: "cli", status: status))
        return id
    }

    /// A Codex session in a 258k window, idle and shown in a terminal. It counts as running only
    /// while the link is up (`link`).
    @discardableResult
    func codexSession(_ n: Int, title: String? = nil, cwd: String? = nil, tokens: Int = 160_000, phase: Phase = .asking,
                      change: (inout SessionState) -> Void = { _ in }) throws -> String {
        let id = "01a1c7f0-4d8a-7870-aab2-07bc76ea740\(n)"
        var s = SessionState(sessionId: id, host: .codex, now: t0)
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.cycle = 1
        s.title = title ?? "Codex session \(n)"
        s.cwd = cwd ?? #"C:\code\c\#(n)"#
        s.codex = CodexFacts(window: 258_400, status: "idle", loaded: true)
        s.codex?.attached = true
        if phase == .asking { s.askedAt = t0 }
        change(&s)
        try s.save(paths)
        return id
    }

    /// The Codex link runs and is connected. Its time is the real clock's, since sessions are read
    /// against that.
    func link(judge: String? = "gpt-6-luna", onlyWatching: String? = nil) throws {
        try CodexLinkStatus(at: Date(), connected: true, judgeModel: judge, observeOnly: onlyWatching).save(paths)
    }

    func edit(_ id: String, _ change: (inout SessionState) -> Void) throws {
        guard var s = SessionState.load(id, paths) else { throw CocoaError(.fileNoSuchFile) }
        change(&s)
        try s.save(paths)
    }

    /// What the installer sets up for Claude Code: the hooks in its settings, and the mod turned on.
    func installClaudeSide() throws {
        let register = ["hooks", "context-guard", "mod", "hooks", "register.ts"].reduce(paths.claudeDir) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: register.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: register)
        let settings = #"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/context-guard/context-guard hook"}]}]},
         "enabledPlugins": {"context-guard@context-guard": true}}
        """#
        try Data(settings.utf8).write(to: paths.claudeDir.appendingPathComponent("settings.json"))
    }

    // MARK: Lines

    static func json(_ line: String) throws -> OrderedJSON { try OrderedJSON.parse(Data(line.utf8)) }

    static func string(_ value: OrderedJSON?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    /// Each line's `type`.
    static func types(_ lines: [String]) -> [String] {
        lines.map { string((try? json($0))?["type"]) ?? "?" }
    }
}

extension Board.Settings {
    var cards: [Board.Card] { tabs.flatMap(\.blocks).compactMap(\.card) }

    func card(_ title: String) -> Board.Card? { cards.first { $0.title == title } }

    func field(_ id: SettingsForm.Field) -> Board.Field? {
        cards.flatMap(\.rows).compactMap(\.field).first { $0.id == id }
    }

    func text(_ id: SettingsForm.Field) -> Board.TextRow? {
        cards.flatMap(\.rows).compactMap(\.text).first { $0.id == id }
    }

    func statusRows(_ card: String) -> [Board.StatusRow] {
        self.card(card)?.rows.compactMap(\.status) ?? []
    }
}
