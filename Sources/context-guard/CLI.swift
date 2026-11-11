import ContextGuardCodexLink
import ContextGuardCore
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation

@main
struct CLI {
    static let usage = """
    context-guard: Claude Code hook, Codex link and control for Context Guard

      context-guard hook                         run as a Claude Code hook (reads the event on stdin)
      context-guard codex [--only-cwd <folder>] [--verbose]
                                                 keep Codex sessions guarded (runs until stopped; one at a time)
      context-guard status [--json]              list sessions and where each one stands
      context-guard answer <session> yes|later|skip
                                                 answer a session's question (id or id prefix)
      context-guard watch <session> on|off       watch a session's tab, or stop watching it
      context-guard on | off                     turn Context Guard on or off
      context-guard mod tick | report | turn     for the Context Guard mod (JSON on stdin and stdout)
    """

    static func main() {
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
        let args = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        let paths = Paths.fromEnvironment(env)
        switch args.first {
        case "hook":
            runHook(paths: paths, env: env)
        case "codex":
            runCodexLink(paths: paths, env: env, args: Array(args.dropFirst()))
        case "status":
            status(paths: paths, json: args.contains("--json"))
        case "answer":
            answer(paths: paths, args: Array(args.dropFirst()))
        case "watch":
            watch(paths: paths, args: Array(args.dropFirst()))
        case "mod":
            runMod(paths: paths, args: Array(args.dropFirst()))
        case "on", "off":
            var config = Config.load(paths)
            config.setEnabled(args.first == "on", now: Date())
            do { try config.save(paths) } catch { fail("Couldn't save \(paths.configFile.path): \(error.localizedDescription)") }
            print("Context Guard is \(config.enabled ? "on" : "off").")
        case "-h", "--help", "help", nil:
            print(usage)
        default:
            fail(usage)
        }
    }

    // MARK: hook

    /// Never noisy: every failure exits 0 with nothing printed. Exit 2 only to wake a session.
    static func runHook(paths: Paths, env: [String: String]) -> Never {
        // A hook that hangs shows up as an error in every session; the configured timeout is 5 s.
        Watchdog.start(seconds: 4)
        // Always read all of stdin, or Claude Code reports a broken pipe.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = HookInput.parse(data) else { exit(0) }
        // Stop can fire a moment before the final response line is written.
        if input.event == HookEvent.stop.rawValue { Thread.sleep(forTimeInterval: 0.4) }

        let runner = HookRunner(paths: paths, claudePid: env["CG_CLAUDE_PID"].flatMap { Int32($0) }, environment: env)
        switch runner.handle(input) {
        case .silent:
            exit(0)
        case .addContext(let event, let text):
            let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]]
            if let json = try? JSONSerialization.data(withJSONObject: out) {
                FileHandle.standardOutput.write(json)
            }
            exit(0)
        case .wake(let text):
            FileHandle.standardError.write(Data(text.utf8))
            exit(2)
        case .wait(let token):
            Watchdog.cancel()
            let maxDuration = env["CONTEXT_GUARD_WAITER_MAX"].flatMap(TimeInterval.init) ?? (12 * 3600 - 300)
            let poll = env["CONTEXT_GUARD_WAITER_POLL"].flatMap(TimeInterval.init) ?? 2
            let result = runner.runWaiter(sessionId: input.sessionId, token: token, maxDuration: maxDuration, poll: poll)
            if let text = result.text { FileHandle.standardError.write(Data(text.utf8)) }
            exit(result.exitCode)
        }
    }

    // MARK: codex

    /// The link to the Codex app server. Runs until SIGTERM or SIGINT. A second copy (for the same
    /// Context Guard folder) waits for the first to stop, so launchd has nothing to restart.
    static func runCodexLink(paths: Paths, env: [String: String], args: [String]) -> Never {
        var options = CodexLink.Options()
        var verbose = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--only-cwd":
                guard i + 1 < args.count, !args[i + 1].isEmpty else { fail(usage) }
                options.onlyCwd = args[i + 1]
                i += 1
            case "--verbose":
                verbose = true
            default:
                fail(usage)
            }
            i += 1
        }
        do { try paths.ensureDirectories() } catch { fail("Couldn't make \(paths.root.path): \(error.localizedDescription)") }
        let log = CodexLinkLog(url: paths.codexLinkLog, echo: verbose)
        var lock = FileLock.acquire(paths.codexLinkLock, timeout: 0)
        if lock == nil {
            log.write("another context-guard codex is running for \(paths.root.path); waiting for it to stop")
            lock = FileLock.wait(paths.codexLinkLock)
        }
        guard lock != nil else { fail("Couldn't open \(paths.codexLinkLock.path).") }

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

    // MARK: mod

    /// The mod's calls. Reads one JSON object on stdin, prints one on stdout; never fails loudly.
    static func runMod(paths: Paths, args: [String]) -> Never {
        Watchdog.start(seconds: 10)
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let decoder = JSONDecoder()
        let runner = ModRunner(paths: paths)
        var out: [String: Any]
        switch args.first {
        case "tick":
            guard let facts = try? decoder.decode(ModFacts.self, from: data) else { emit(["action": "none"]) }
            out = runner.tick(facts).json
        case "report":
            guard let report = try? decoder.decode(ModReport.self, from: data) else { emit(["again": false]) }
            out = ["again": runner.report(report)]
        case "turn":
            guard let turn = try? decoder.decode(ModTurn.self, from: data) else { emit([:]) }
            runner.turn(turn)
            out = [:]
        default:
            fail(usage)
        }
        emit(out)
    }

    static func emit(_ obj: [String: Any]) -> Never {
        if let json = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }

    // MARK: watch

    static func watch(paths: Paths, args: [String]) {
        guard args.count == 2, args[1] == "on" || args[1] == "off" else { fail(usage) }
        let target = session(paths: paths, prefix: args[0])
        do {
            try Mute.set(args[1] == "off", for: target.state, paths)
        } catch {
            fail("Couldn't \(args[1] == "off" ? "stop watching" : "watch") \(target.title): \(error.localizedDescription)")
        }
        print(args[1] == "on" ? "Watching \(target.title) again." : "Not watching \(target.title) until its tab closes.")
    }

    static func session(paths: Paths, prefix: String) -> SessionInfo {
        let sessions = SessionCatalog.load(paths, registry: FileRegistry(dir: paths.registryDir))
        let matches = sessions.filter { $0.id.hasPrefix(prefix) }
        guard matches.count == 1, let target = matches.first else {
            fail(matches.isEmpty ? "No session matches \(prefix)." : "\(prefix) matches \(matches.count) sessions; use more of the id.")
        }
        return target
    }

    // MARK: status

    static func status(paths: Paths, json: Bool) {
        let config = Config.load(paths)
        let sessions = SessionCatalog.load(paths, registry: FileRegistry(dir: paths.registryDir))
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let rows = sessions.map { StatusRow($0, config: config.resolved(for: $0.state)) }
            if let data = try? encoder.encode(rows) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        for line in StatusText.lines(config: config, sessions: sessions, link: CodexLinkStatus.load(paths)) { print(line) }
    }

    struct StatusRow: Encodable {
        var sessionId: String
        /// `claude` or `codex`.
        var tool: String
        var title: String
        var tokens: Int
        /// The session's own window (Codex).
        var window: Int?
        /// Its thresholds: Codex's are shares of its window.
        var askAt: Int
        var laterAt: Int
        var reachableNow: Bool
        /// A terminal shows it (Codex), as far as the link can tell.
        var attached: Bool?
        var phase: String
        var effectivePhase: String
        var guarded: Bool
        var live: Bool
        var waiterAlive: Bool
        var cycle: Int
        var sentVia: String?
        var confirmedAt: Date?
        var lastCompaction: Compaction?
        var muted: Bool
        var askTimedOut: Bool?
        var followUp: FollowUp?

        init(_ s: SessionInfo, config: Config) {
            sessionId = s.id
            tool = s.host.rawValue
            title = s.title
            tokens = s.state.tokens
            window = s.state.codex?.window
            askAt = config.askAt
            laterAt = config.laterAt
            reachableNow = s.reachableNow
            attached = s.state.codex?.attached
            phase = s.state.phase.rawValue
            effectivePhase = s.effectivePhase.rawValue
            guarded = s.state.guarded
            live = s.isLive
            waiterAlive = s.waiterAlive
            cycle = s.state.cycle
            sentVia = s.state.sentVia?.rawValue
            confirmedAt = s.state.confirmedAt
            lastCompaction = s.state.lastCompaction
            muted = s.muted
            askTimedOut = s.state.askTimedOut
            followUp = s.state.followUp
        }
    }

    // MARK: answer

    static func answer(paths: Paths, args: [String]) {
        guard args.count == 2, let action = Answer.Action(rawValue: args[1]) else { fail(usage) }
        let target = session(paths: paths, prefix: args[0])
        do {
            try Answer(cycle: target.state.cycle, action: action, source: .cli, at: Date()).save(for: target.id, paths)
        } catch {
            fail("Couldn't save the answer: \(error.localizedDescription)")
        }
        print("Answered \(action.rawValue) for \(target.title).")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

/// Ends the program after `seconds` unless cancelled first. On the Mac `SIGALRM`; on Windows, which
/// has no alarm, a thread that sleeps that long.
enum Watchdog {
    #if os(Windows)
    private final class Armed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isOn: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func off() {
            lock.lock()
            value = false
            lock.unlock()
        }
    }

    nonisolated(unsafe) private static var armed: Armed?

    static func start(seconds: UInt32) {
        let a = Armed()
        armed = a
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: TimeInterval(seconds))
            if a.isOn { _exit(0) }
        }
    }

    static func cancel() { armed?.off() }
    #else
    static func start(seconds: UInt32) {
        signal(SIGALRM) { _ in _exit(0) }
        alarm(seconds)
    }

    static func cancel() { alarm(0) }
    #endif
}
