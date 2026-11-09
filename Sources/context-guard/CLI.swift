import ContextGuardCore
import Darwin
import Foundation

@main
struct CLI {
    static let usage = """
    context-guard: Claude Code hook and control for Context Guard

      context-guard hook                         run as a Claude Code hook (reads the event on stdin)
      context-guard status [--json]              list sessions and where each one stands
      context-guard answer <session> yes|later|skip
                                                 answer a session's question (id or id prefix)
      context-guard watch <session> on|off       watch a session's tab, or stop watching it
      context-guard on | off                     turn Context Guard on or off
      context-guard mod tick | report | turn     for the Context Guard mod (JSON on stdin and stdout)
    """

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        let paths = Paths.fromEnvironment(env)
        switch args.first {
        case "hook":
            runHook(paths: paths, env: env)
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
        signal(SIGALRM) { _ in _exit(0) }
        alarm(4)
        // Always read all of stdin, or Claude Code reports a broken pipe.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = HookInput.parse(data) else { exit(0) }
        // Stop can fire a moment before the final response line is written.
        if input.event == HookEvent.stop.rawValue { usleep(400_000) }

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
            alarm(0)
            let maxDuration = env["CONTEXT_GUARD_WAITER_MAX"].flatMap(TimeInterval.init) ?? (12 * 3600 - 300)
            let poll = env["CONTEXT_GUARD_WAITER_POLL"].flatMap(TimeInterval.init) ?? 2
            let result = runner.runWaiter(sessionId: input.sessionId, token: token, maxDuration: maxDuration, poll: poll)
            if let text = result.text { FileHandle.standardError.write(Data(text.utf8)) }
            exit(result.exitCode)
        }
    }

    // MARK: mod

    /// The mod's calls. Reads one JSON object on stdin, prints one on stdout; never fails loudly.
    static func runMod(paths: Paths, args: [String]) -> Never {
        signal(SIGALRM) { _ in _exit(0) }
        alarm(10)
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
            let rows = sessions.map(StatusRow.init)
            if let data = try? encoder.encode(rows) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        print("Context Guard is \(config.enabled ? "on" : "off") · asks at \(Format.tokens(config.askAt)) · compacts at \(Format.tokens(config.laterAt)) when told to wait")
        let live = sessions.filter(\.isLive)
        if live.isEmpty { print("No running sessions seen yet."); return }
        for s in live {
            let guarded = s.state.guarded ? "" : " (not guarded)"
            let muted = s.muted ? " (not watching)" : ""
            let waiter = s.waiterAlive ? " · waiting in background" : ""
            let follow = s.state.followUp.map { " · compacting: \($0.stage.rawValue)\($0.note.map { " (\($0))" } ?? "")" } ?? ""
            print("\(s.id.prefix(8))  \(Format.tokens(s.state.tokens).padding(toLength: 6, withPad: " ", startingAt: 0)) \(s.effectivePhase.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(s.title)\(guarded)\(muted)\(waiter)\(follow)")
        }
    }

    struct StatusRow: Encodable {
        var sessionId: String
        var title: String
        var tokens: Int
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

        init(_ s: SessionInfo) {
            sessionId = s.id
            title = s.title
            tokens = s.state.tokens
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
