import Foundation

public struct ProcessIdentity: Equatable, Sendable {
    public var start: ProcessStart
    /// Has a controlling terminal (interactive sessions do; SDK and headless ones don't). nil where
    /// processes have none (Windows), so something else has to tell.
    public var hasTTY: Bool?

    public init(start: ProcessStart, hasTTY: Bool?) {
        self.start = start
        self.hasTTY = hasTTY
    }
}

public protocol ProcessProbing: Sendable {
    func identity(of pid: Int32) -> ProcessIdentity?
}

extension ProcessProbing {
    /// The same process is still running: same pid and same start time.
    public func isRunning(_ pid: Int32, startedAt start: ProcessStart?) -> Bool {
        guard let id = identity(of: pid) else { return false }
        guard let start else { return true }
        return id.start == start
    }
}

/// One entry of Claude Code's registry of running sessions (`~/.claude/sessions/<pid>.json`).
/// Internal to Claude Code, so every field is optional and unknown shapes are ignored.
public struct RegistryEntry: Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String?
    public var kind: String?
    public var entrypoint: String?
    public var name: String?
    public var status: String?
    public var cwd: String?

    public init(pid: Int32, sessionId: String? = nil, kind: String? = nil, entrypoint: String? = nil, name: String? = nil, status: String? = nil, cwd: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.status = status
        self.cwd = cwd
    }

    /// A terminal session started from the CLI (not an SDK, background or automated one).
    public var isInteractiveCLI: Bool { entrypoint == "cli" && kind == "interactive" }
}

public protocol RegistryReading: Sendable {
    /// nil when there's no readable entry for that pid.
    func entry(pid: Int32) -> RegistryEntry?
    func all() -> [RegistryEntry]
    /// Whether the registry folder exists at all (if not, Claude Code changed and we fall back).
    var isAvailable: Bool { get }
}

public struct FileRegistry: RegistryReading {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public var isAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func entry(pid: Int32) -> RegistryEntry? {
        parse(dir.appendingPathComponent("\(pid).json"))
    }

    public func all() -> [RegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(parse)
    }

    private func parse(_ url: URL) -> RegistryEntry? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = TranscriptReader.int(obj["pid"]) else { return nil }
        return RegistryEntry(
            pid: Int32(truncatingIfNeeded: pid),
            sessionId: obj["sessionId"] as? String,
            kind: obj["kind"] as? String,
            entrypoint: obj["entrypoint"] as? String,
            name: obj["name"] as? String,
            status: obj["status"] as? String,
            cwd: obj["cwd"] as? String)
    }
}
