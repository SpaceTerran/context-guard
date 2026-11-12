import ContextGuardCodexLink
import ContextGuardCore
import Foundation
import WinSDK

/// `context-guard-link.exe`: the Codex link that the installer's scheduled task runs, with no
/// console window. It takes only `--env NAME=value` (a task has no environment of its own), and it
/// writes what it has to say to `codex-link.log`.
@main
struct LinkMain {
    static func main() {
        let base = ProcessInfo.processInfo.environment
        let env: [String: String]
        do {
            env = try CodexLinkService.environment(Array(CommandLine.arguments.dropFirst()), base: base)
        } catch {
            notStarted(Paths.fromEnvironment(base), "\(error)")
        }
        let paths = Paths.fromEnvironment(env)
        CodexLinkService.run(paths: paths, env: env, options: CodexLink.Options(), verbose: false) { why in
            notStarted(paths, why)
        }
    }

    /// Says why in the log and exits 1; the task starts it again within a minute.
    static func notStarted(_ paths: Paths, _ why: String) -> Never {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        CodexLinkLog(url: paths.codexLinkLog).write("not started: \(why)")
        exit(1)
    }
}
