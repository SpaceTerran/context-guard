import ContextGuardCore
import Darwin
import Foundation

/// A running `codex` terminal app.
public struct CodexTerminalProcess: Equatable, Sendable {
    public var pid: Int32
    /// Its working folder, symlinks resolved.
    public var cwd: String
    /// Its command line, program first.
    public var args: [String]

    public init(pid: Int32, cwd: String, args: [String]) {
        self.pid = pid
        self.cwd = cwd
        self.args = args
    }
}

public protocol CodexTerminalProbing: Sendable {
    func terminals() -> [CodexTerminalProcess]
}

/// Which sessions a terminal has open. The app server can't say (a session stays loaded for a
/// minute after its terminal closes), so it's worked out from the `codex` processes running in a
/// terminal: their folder, and the session a `codex resume <id>` names.
public enum CodexAttachment {
    /// Subcommands that aren't the interactive app.
    static let otherCommands: Set<String> = [
        "exec", "e", "app-server", "mcp", "mcp-server", "login", "logout", "completion", "delete", "apply", "a",
        "sandbox", "debug", "cloud", "features", "help", "update", "generate-ts", "responses-api-proxy",
        "stdio-to-uds", "proto", "doctor", "archive", "unarchive",
    ]
    /// Options that take a value, so the value isn't read as a subcommand or prompt.
    static let valueOptions: Set<String> = [
        "-m", "--model", "-c", "--config", "-p", "--profile", "-C", "--cd", "-s", "--sandbox",
        "-a", "--ask-for-approval", "-i", "--image", "--add-dir", "--local-provider", "--enable", "--disable",
    ]

    /// The command and its positional words, options left out.
    static func words(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--" {
                out += args[(i + 1)...]
                break
            }
            if a.hasPrefix("-") {
                if valueOptions.contains(a) { i += 1 }
            } else {
                out.append(a)
            }
            i += 1
        }
        return out
    }

    /// A `codex` command line that runs the interactive app.
    public static func isTerminalApp(_ args: [String]) -> Bool {
        guard let first = words(args).first else { return true }
        return !otherCommands.contains(first)
    }

    /// The folder its session runs in: `-C`/`--cd` when given, else its own.
    public static func sessionFolder(_ p: CodexTerminalProcess) -> String {
        var i = 1
        while i < p.args.count {
            let a = p.args[i]
            var value: String?
            if a == "-C" || a == "--cd", i + 1 < p.args.count {
                value = p.args[i + 1]
            } else if a.hasPrefix("--cd=") {
                value = String(a.dropFirst(5))
            } else if a.hasPrefix("-C"), a.count > 2 {
                value = String(a.dropFirst(2))
            }
            if let value {
                let expanded = (value as NSString).expandingTildeInPath
                let full = expanded.hasPrefix("/") ? expanded : (p.cwd as NSString).appendingPathComponent(expanded)
                return resolved(full)
            }
            i += 1
        }
        return resolved(p.cwd)
    }

    /// The session a `codex resume <id>` names, if it names one.
    static func namedSession(_ p: CodexTerminalProcess) -> String? {
        let w = words(p.args)
        guard w.first == "resume", w.count >= 2 else { return nil }
        return w[1]
    }

    public static let terminalOriginator = "codex-tui"

    public static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    /// For each thread: a terminal has it open. A terminal that names its session holds that one;
    /// the rest hold sessions in their folder, the most recently used first. nil when a thread's
    /// folder isn't known.
    public static func attached(threads: [CodexThreadInfo], terminals: [CodexTerminalProcess]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        let ids = Set(threads.map(\.id))
        var free: [CodexTerminalProcess] = []
        for t in terminals {
            if let named = namedSession(t), ids.contains(named) {
                out[named] = true
            } else {
                free.append(t)
            }
        }
        var terminalsIn: [String: Int] = [:]
        for t in free { terminalsIn[sessionFolder(t), default: 0] += 1 }
        var threadsIn: [String: [CodexThreadInfo]] = [:]
        for th in threads where out[th.id] == nil {
            // Only the terminal app's sessions compete for its terminals.
            guard th.originator == terminalOriginator else {
                out[th.id] = false
                continue
            }
            guard let cwd = th.cwd, !cwd.isEmpty else { continue }
            threadsIn[resolved(cwd), default: []].append(th)
        }
        for (folder, list) in threadsIn {
            let count = terminalsIn[folder] ?? 0
            let newest = list.sorted { ($0.recencyAt ?? 0) > ($1.recencyAt ?? 0) }
            for (i, th) in newest.enumerated() { out[th.id] = i < count }
        }
        return out
    }
}

/// The `codex` processes running in a terminal on this Mac.
public struct SystemCodexTerminals: CodexTerminalProbing {
    public init() {}

    public func terminals() -> [CodexTerminalProcess] {
        let probe = SystemProcessProbe()
        return Self.pids().compactMap { pid in
            guard let name = Self.name(pid), Self.isCodexProgram(name), probe.identity(of: pid)?.hasTTY == true,
                  let args = Self.arguments(pid), CodexAttachment.isTerminalApp(args),
                  let cwd = Self.cwd(pid) else { return nil }
            return CodexTerminalProcess(pid: pid, cwd: cwd, args: args)
        }
    }

    /// Homebrew's `codex`, or the native binary npm's launcher starts (`codex-aarch64-apple-darwin`).
    static func isCodexProgram(_ name: String) -> Bool {
        name == "codex" || name.hasPrefix("codex-aarch64") || name.hasPrefix("codex-x86_64")
    }

    static func pids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    static func name(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).prefix { $0 != 0 }, as: UTF8.self)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// From `KERN_PROCARGS2`: argc, the program's path, then the arguments.
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // The program's path, then padding.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < Int(argc), i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : args
    }
}
