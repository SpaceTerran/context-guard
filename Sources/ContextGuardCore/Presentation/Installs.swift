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
