#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Context Guard's hooks in Claude Code's user settings (`~/.claude/settings.json`). Both installers
/// run `context-guard setup` to add them and `context-guard setup --uninstall` to remove them, so
/// they're defined here once. Everything else in the file stays as it was, in its order, and the
/// file is printed as `jq .` prints it.
public enum HookSetup {
    /// How a hook runs the program.
    public struct Program: Equatable, Sendable {
        /// A shell line; with `args`, the program itself (exec form: no shell).
        public var command: String
        public var args: [String]?
    }

    /// The Mac's: a shell line that only reads the event when the program is missing (uninstalled,
    /// or mid-update). `$PPID` is the Claude Code process that ran it.
    public static let shellProgram = Program(
        command: #"f="$HOME/.claude/hooks/context-guard/context-guard"; if [ -x "$f" ]; then CG_CLAUDE_PID=$PPID exec "$f" hook; else cat >/dev/null; fi"#,
        args: nil)

    /// Windows': the installed program itself, since a shell there is Git Bash or PowerShell. Claude
    /// Code puts its own process id in `CLAUDE_PID`.
    public static func windowsProgram(home: String) -> Program {
        Program(command: PathRules.native(home, windows: true) + #"\.claude\hooks\context-guard\context-guard.exe"#, args: ["hook"])
    }

    /// This platform's.
    public static func program(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Program {
        #if os(Windows)
        windowsProgram(home: env["USERPROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory())
        #else
        shellProgram
        #endif
    }

    /// Claude Code's user settings, in the home folder (as the installers have always used).
    public static func settingsFile(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if os(Windows)
        let home = env["USERPROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        #else
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        #endif
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// The events Context Guard hooks, in the order they're added.
    static let events = ["PostToolBatch", "SessionStart", "SessionEnd", "StopFailure", "Stop"]

    /// Every Context Guard hook runs the installed program, so its command names this.
    static let programPaths = ["hooks/context-guard/context-guard", #"hooks\context-guard\context-guard"#]

    static func hook(_ program: Program, event: String) -> OrderedJSON {
        var members: [OrderedJSON.Member] = [.init("type", .string("command")), .init("command", .string(program.command))]
        if let args = program.args { members.append(.init("args", .array(args.map { .string($0) }))) }
        if event == "Stop" {
            // Runs in the background after each turn; exiting 2 wakes the idle session with the save
            // message. 43500 s is about 12 hours, the longest one waits.
            members += [.init("timeout", .number("43500")), .init("asyncRewake", .bool(true)),
                        .init("rewakeSummary", .string("Context Guard: save before compacting")),
                        .init("rewakeMessage", .string("Stop hook message:"))]
        } else {
            members.append(.init("timeout", .number("5")))
        }
        return .object(members)
    }

    static func isOurs(_ hook: OrderedJSON) -> Bool {
        guard case .string(let command)? = hook["command"] else { return false }
        return programPaths.contains { command.contains($0) }
    }

    /// Why the settings can't be changed. Nothing was written.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case invalidJSON(String)
        case unexpected(String, what: String)
        case couldNotRead(String, reason: String)
        case couldNotWrite(String, reason: String)

        public var description: String {
            switch self {
            case .invalidJSON(let file): return "\(file) isn't valid JSON; fix it and run this again"
            case .unexpected(let file, let what): return "\(file): \(what); fix it and run this again"
            case .couldNotRead(let file, let reason): return "couldn't read \(file): \(reason)"
            case .couldNotWrite(let file, let reason): return "couldn't write \(file): \(reason)"
            }
        }
    }

    // MARK: Changing the settings

    /// Whether any hook in the settings runs Context Guard's program.
    public static func hasOurs(_ settings: OrderedJSON) -> Bool {
        guard case .object(let events)? = settings["hooks"] else { return false }
        return events.contains { event in
            guard case .array(let groups) = event.value else { return false }
            return groups.contains { group in
                guard case .array(let hooks)? = group["hooks"] else { return false }
                return hooks.contains(where: isOurs)
            }
        }
    }

    /// Without Context Guard's hooks: they leave their groups, a group left empty goes, and so does
    /// any event left with no groups.
    public static func stripped(_ settings: OrderedJSON) throws -> OrderedJSON {
        guard let hooks = settings["hooks"], hooks != .null, hooks != .bool(false) else { return settings }
        guard case .object(let events) = hooks else { throw Shape.hooksNotObject }
        var kept: [OrderedJSON.Member] = []
        for event in events {
            guard case .array(let groups) = event.value else { throw Shape.eventNotArray(event.key) }
            let left: [OrderedJSON] = groups.compactMap { group in
                guard case .array(let inner)? = group["hooks"], inner.contains(where: isOurs) else { return group }
                let others = inner.filter { !isOurs($0) }
                guard !others.isEmpty else { return nil }
                var g = group
                g.set("hooks", .array(others))
                return g
            }
            if !left.isEmpty { kept.append(.init(event.key, .array(left))) }
        }
        var s = settings
        s.set("hooks", .object(kept))
        return s
    }

    /// With one group of Context Guard's hook added to the end of each event it uses.
    public static func added(_ settings: OrderedJSON, _ program: Program) throws -> OrderedJSON {
        var hooks = settings["hooks"] ?? .null
        if hooks == .null || hooks == .bool(false) { hooks = .object([]) }
        guard case .object = hooks else { throw Shape.hooksNotObject }
        for event in events {
            var groups: [OrderedJSON]
            switch hooks[event] {
            case nil, .null?: groups = []
            case .array(let a)?: groups = a
            default: throw Shape.eventNotArray(event)
            }
            groups.append(.object([.init("hooks", .array([hook(program, event: event)]))]))
            hooks.set(event, .array(groups))
        }
        var s = settings
        s.set("hooks", hooks)
        return s
    }

    enum Shape: Error {
        case hooksNotObject
        case eventNotArray(String)

        var what: String {
            switch self {
            case .hooksNotObject: return "\"hooks\" isn't an object"
            case .eventNotArray(let event): return "\"hooks\".\"\(event)\" isn't a list"
            }
        }
    }

    // MARK: The file

    public enum Outcome: Equatable, Sendable {
        /// Written, after copying the old file here (nil when there was none).
        case updated(backup: URL?)
        /// Already as it should be: nothing written.
        case unchanged
    }

    /// Removes Context Guard's hooks, then adds them, so running it again leaves one of each.
    @discardableResult
    public static func install(_ program: Program, settings url: URL, now: Date = Date()) throws -> Outcome {
        try change(url, now: now, whenMissing: .object([])) { try added(stripped($0), program) }
    }

    /// Removes Context Guard's hooks. The file is written only when it has some, and a file that
    /// doesn't even mention the program is left alone unread, broken or not.
    @discardableResult
    public static func uninstall(settings url: URL, now: Date = Date()) throws -> Outcome {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              HookInstall.markers.contains(where: { text.contains($0) }) else { return .unchanged }
        return try change(url, now: now, whenMissing: nil) { hasOurs($0) ? try stripped($0) : nil }
    }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// `edit` returns the new settings, or nil when there's nothing to change.
    private static func change(_ url: URL, now: Date, whenMissing: OrderedJSON?,
                               _ edit: (OrderedJSON) throws -> OrderedJSON?) throws -> Outcome {
        let file = PathRules.native(url.path)
        let old: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            do { old = try Data(contentsOf: url) } catch { throw Problem.couldNotRead(file, reason: error.localizedDescription) }
        } else {
            old = nil
        }
        let settings: OrderedJSON
        if let old {
            guard let parsed = try? OrderedJSON.parse(old) else { throw Problem.invalidJSON(file) }
            guard case .object = parsed else { throw Problem.unexpected(file, what: "it isn't a JSON object") }
            settings = parsed
        } else if let whenMissing {
            settings = whenMissing
        } else {
            return .unchanged
        }
        let edited: OrderedJSON?
        do { edited = try edit(settings) } catch let shape as Shape { throw Problem.unexpected(file, what: shape.what) }
        guard let changed = edited else { return .unchanged }
        // Kept as the file had it.
        let keepsBOM = old.map { Array($0.prefix(3)) == bom } ?? false
        let text = Data((keepsBOM ? bom : []) + Array(changed.jqText.utf8))
        if text == old { return .unchanged }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = try old.map { _ in try copyAside(url, now: now) }
            try replace(url, with: text)
            return .updated(backup: backup)
        } catch let p as Problem {
            throw p
        } catch {
            throw Problem.couldNotWrite(file, reason: error.localizedDescription)
        }
    }

    /// `settings.json.context-guard-backup-<local time>`, next to it, with its permissions.
    static func copyAside(_ url: URL, now: Date) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".context-guard-backup-" + f.string(from: now))
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    /// The new text renamed into place, so a running Claude Code never reads half a file. On the
    /// Mac it keeps the file's permissions (and is never readable by others on the way); on
    /// Windows it waits a moment while another program has the file open.
    static func replace(_ url: URL, with data: Data) throws {
        #if os(Windows)
        try FileIO.replace(url, with: data)
        #else
        let dir = url.deletingLastPathComponent()
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))").path
        // Private until it has the old file's permissions; a new file gets the usual ones (umask).
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, mode == nil ? 0o666 : 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = data.withUnsafeBytes { buf -> Bool in
            var done = 0
            while done < buf.count {
                let n = write(fd, buf.baseAddress! + done, buf.count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        if ok, let mode { ok = fchmod(fd, mode_t(mode)) == 0 }
        let err = errno
        close(fd)
        guard ok, rename(tmp, url.path) == 0 else {
            let e = ok ? errno : err
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        #endif
    }
}
