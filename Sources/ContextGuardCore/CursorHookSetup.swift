import Foundation

/// Context Guard's hooks in Cursor's user hooks file (`~/.cursor/hooks.json`), which both the Cursor
/// app and the Cursor CLI run. `context-guard cursor install` adds them and `context-guard cursor
/// uninstall` removes them. Every other hook (yours, other tools') stays as it was, in its order,
/// and the file is written as `jq .` prints it, after a backup, like Claude Code's settings
/// (`HookSetup`).
public enum CursorHookSetup {
    /// One line for every event, run by `/bin/sh` whether Cursor hands it to a shell or splits it
    /// into words: it only reads the event when the program is missing (uninstalled, or mid-update).
    public static let command =
        #"/bin/sh -c 'f="$HOME/.claude/hooks/context-guard/context-guard"; if [ -x "$f" ]; then exec "$f" cursor hook; else cat >/dev/null; echo "{}"; fi'"#

    /// Cursor's user hooks file, in the home folder. `CONTEXT_GUARD_CURSOR_HOOKS` names another one
    /// (`live-test/ui-demo.sh`).
    public static func hooksFile(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let file = env["CONTEXT_GUARD_CURSOR_HOOKS"], !file.isEmpty { return URL(fileURLWithPath: file) }
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// The events Context Guard hooks, in the order they're added.
    static let events = CursorEvent.allCases.map(\.rawValue)

    /// `stop` stays in the background between turns (`CursorRunner.hold`, under 12 hours); the others
    /// answer at once.
    static func hook(event: String) -> OrderedJSON {
        .object([.init("command", .string(command)),
                 .init("timeout", .number(event == CursorEvent.stop.rawValue ? "43800" : "5"))])
    }

    static func isOurs(_ hook: OrderedJSON) -> Bool {
        guard case .string(let command)? = hook["command"] else { return false }
        return HookInstall.markers.contains { command.contains($0) }
    }

    /// Whether any hook in the file runs Context Guard's program.
    public static func hasOurs(_ file: OrderedJSON) -> Bool {
        guard case .object(let events)? = file["hooks"] else { return false }
        return events.contains { event in
            guard case .array(let hooks) = event.value else { return false }
            return hooks.contains(where: isOurs)
        }
    }

    /// Without Context Guard's hooks. An event left with none goes, if they were all Context Guard's.
    public static func stripped(_ file: OrderedJSON) throws -> OrderedJSON {
        guard let hooks = file["hooks"], hooks != .null else { return file }
        guard case .object(let events) = hooks else { throw HookSetup.Shape.hooksNotObject }
        var kept: [OrderedJSON.Member] = []
        for event in events {
            guard case .array(let list) = event.value else { throw HookSetup.Shape.eventNotArray(event.key) }
            let others = list.filter { !isOurs($0) }
            if others.isEmpty, others.count < list.count { continue }
            kept.append(.init(event.key, .array(others)))
        }
        var f = file
        f.set("hooks", .object(kept))
        return f
    }

    /// With Context Guard's hook added to the end of each event it uses.
    public static func added(_ file: OrderedJSON) throws -> OrderedJSON {
        var hooks = file["hooks"] ?? .null
        if hooks == .null { hooks = .object([]) }
        guard case .object = hooks else { throw HookSetup.Shape.hooksNotObject }
        for event in events {
            var list: [OrderedJSON]
            switch hooks[event] {
            case nil, .null?: list = []
            case .array(let a)?: list = a
            default: throw HookSetup.Shape.eventNotArray(event)
            }
            list.append(hook(event: event))
            hooks.set(event, .array(list))
        }
        var f = file
        // A new file says which format it is, as Cursor's own do.
        if f["version"] == nil { f.set("version", .number("1")) }
        f.set("hooks", hooks)
        return f
    }

    /// Removes Context Guard's hooks, then adds them, so running it again leaves one of each.
    @discardableResult
    public static func install(hooks url: URL, now: Date = Date()) throws -> HookSetup.Outcome {
        try HookSetup.change(url, now: now, whenMissing: .object([])) { try added(stripped($0)) }
    }

    /// Removes Context Guard's hooks. The file is written only when it has some, and a file that
    /// doesn't even mention the program is left alone unread, broken or not.
    @discardableResult
    public static func uninstall(hooks url: URL, now: Date = Date()) throws -> HookSetup.Outcome {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              HookInstall.markers.contains(where: { text.contains($0) }) else { return .unchanged }
        return try HookSetup.change(url, now: now, whenMissing: nil) { hasOurs($0) ? try stripped($0) : nil }
    }

    /// Whether Cursor runs Context Guard's hooks.
    public static func isInstalled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let data = try? Data(contentsOf: hooksFile(env)), let file = try? OrderedJSON.parse(data) else { return false }
        return hasOurs(file)
    }
}
