import Foundation

/// Whether the installer set up Claude Code's side: Settings shows it.
public enum HookInstall {
    /// The installer adds this program to every Context Guard hook in Claude Code's user settings.
    /// A Windows path is written with doubled backslashes in that JSON file.
    static let markers = ["hooks/context-guard/context-guard", #"hooks\\context-guard\\context-guard"#]

    public static func isInstalled(_ paths: Paths) -> Bool {
        let settings = paths.claudeDir.appendingPathComponent("settings.json")
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return markers.contains { text.contains($0) }
    }
}

public enum ModInstall {
    /// The installer copies the mod here and turns the plugin on in Claude Code's user settings.
    public static let plugin = "context-guard@context-guard"

    public static func isInstalled(_ paths: Paths) -> Bool {
        let module = ["hooks", "context-guard", "mod", "hooks", "register.ts"].reduce(paths.claudeDir) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: module.path),
              let data = try? Data(contentsOf: paths.claudeDir.appendingPathComponent("settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let enabled = settings["enabledPlugins"] as? [String: Any] else { return false }
        return enabled[plugin] as? Bool == true
    }
}

/// Whether the installer set up the Codex link's background program: Settings shows it, and the
/// menu shows each tool's own lines once it is.
public enum CodexLinkInstall {
    /// install.sh's LaunchAgent, which keeps `context-guard codex` running on the Mac.
    public static let label = "com.spaceterran.ContextGuard.codex"

    /// The Mac: the LaunchAgent's file. `CONTEXT_GUARD_LAUNCH_AGENTS` moves the folder it's looked
    /// for in, so `live-test/ui-demo.sh` shows the same thing whatever this Mac has installed.
    public static func plist(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let moved = env["CONTEXT_GUARD_LAUNCH_AGENTS"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = moved.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    /// Windows: the link's program in the hook folder. install.ps1 keeps it there only while the
    /// link's scheduled task is installed (`-NoCodex` and `-Uninstall` remove both).
    public static func program(_ paths: Paths) -> URL {
        ["hooks", "context-guard", "context-guard-link.exe"].reduce(paths.claudeDir) { $0.appendingPathComponent($1) }
    }

    public static func isInstalled(_ paths: Paths, env: [String: String] = ProcessInfo.processInfo.environment,
                                   windows: Bool = PathRules.isWindows) -> Bool {
        FileManager.default.fileExists(atPath: (windows ? program(paths) : plist(env)).path)
    }
}
