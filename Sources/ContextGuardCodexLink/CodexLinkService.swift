import ContextGuardCore
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// The Codex link as a running program. `context-guard codex` runs it on both platforms (the Mac's
/// LaunchAgent, the live tests, a person at a terminal). On Windows the background task runs it as
/// `context-guard-link.exe`, the same code built with no console window.
public enum CodexLinkService {
    /// Runs the link for `paths` until it is told to stop, then ends the process. A second copy for
    /// the same Context Guard folder waits for the first to stop, so whatever restarts the link
    /// (launchd, the Windows task) has nothing to restart. `fail` says why it couldn't start and
    /// ends the process.
    public static func run(paths: Paths, env: [String: String], options: CodexLink.Options, verbose: Bool,
                           fail: (String) -> Never) -> Never {
        do { try paths.ensureDirectories() } catch { fail("Couldn't make \(PathRules.native(paths.root.path)): \(error.localizedDescription)") }
        let log = CodexLinkLog(url: paths.codexLinkLog, echo: verbose)
        var lock = FileLock.acquire(paths.codexLinkLock, timeout: 0)
        if lock == nil {
            log.write("another context-guard codex is running for \(PathRules.native(paths.root.path)); waiting for it to stop")
            lock = FileLock.wait(paths.codexLinkLock)
        }
        guard lock != nil else { fail("Couldn't open \(PathRules.native(paths.codexLinkLock.path)).") }

        let connector = CodexSocketConnector(socketPath: CodexSocketConnector.defaultSocketPath(env))
        let link = CodexLink(paths: paths, connector: connector, options: options, log: log)
        // Stopped, it says so in codex-link.json first; one that doesn't stop in time just exits.
        let stopping: @Sendable () -> Void = {
            link.stop()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
        }
        #if os(Windows)
        let stops = CodexLinkStop.Listener(root: paths.root, stopping)
        #else
        var stops: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: stopping)
            source.resume()
            stops.append(source)
        }
        #endif
        link.run()
        #if os(Windows)
        stops?.stopped()
        #endif
        withExtendedLifetime((lock, stops)) {}
        exit(0)
    }

    // MARK: The background link's arguments

    /// What `--env` may set: the folders Context Guard and Codex use. A scheduled task has no
    /// environment of its own, so the installer passes these as arguments (the Mac writes them into
    /// the LaunchAgent).
    public static let environmentNames: Set<String> = ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "CONTEXT_GUARD_HOME"]

    public enum ArgumentError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue
        case notAssignment(String)
        case notAllowed(String)

        public var description: String {
            switch self {
            case .unknown(let arg): return "unknown argument \(arg)"
            case .missingValue: return "--env needs NAME=value"
            case .notAssignment(let value): return "--env \(value): not NAME=value"
            case .notAllowed(let name): return "--env \(name): only \(CodexLinkService.environmentNames.sorted().joined(separator: ", "))"
            }
        }
    }

    /// The background link's environment: `base`, with each `--env NAME=value` on top (the last
    /// one for a name wins).
    public static func environment(_ arguments: [String], base: [String: String]) throws -> [String: String] {
        var env = base
        var i = 0
        while i < arguments.count {
            guard arguments[i] == "--env" else { throw ArgumentError.unknown(arguments[i]) }
            guard i + 1 < arguments.count else { throw ArgumentError.missingValue }
            let pair = arguments[i + 1]
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { throw ArgumentError.notAssignment(pair) }
            let name = String(pair[..<eq])
            guard environmentNames.contains(name) else { throw ArgumentError.notAllowed(name) }
            env[name] = String(pair[pair.index(after: eq)...])
            i += 2
        }
        return env
    }

    // MARK: Stopping it (Windows)

    #if os(Windows)
    public enum Stopped: Equatable, Sendable {
        case stopped
        case notRunning
        /// Asked, but it still holds its lock.
        case stillRunning
    }

    /// Asks the link for this Context Guard folder to stop, and waits until it has let go of its
    /// lock. The Mac's link is stopped through launchd instead.
    public static func stop(paths: Paths, timeout: TimeInterval = 6) -> Stopped {
        guard CodexLinkStop.request(for: paths.root) else { return .notRunning }
        guard let lock = FileLock.acquire(paths.codexLinkLock, timeout: timeout) else { return .stillRunning }
        lock.release()
        return .stopped
    }
    #endif
}
