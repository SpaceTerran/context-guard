import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// The lines `context-guard ui` writes and reads, kept in `contract/ui/` at the top of the repo. The
/// Windows app's tests read the same files, so a change one side makes and the other doesn't know
/// about fails a test.
///
/// - `boards/`, `messages/`: what it writes, one message per file, as `jq .` prints it with keys in
///   byte order. After a deliberate change, `CONTEXT_GUARD_UPDATE_CONTRACT=1 swift test --filter
///   UIContractTests` rewrites them; read the diff before committing it.
/// - `intents/`: what the app sends, written by hand and read here into the intents they mean.
///
/// The files hold the Windows app's words. On the Mac its own two (`install.sh`, the menu bar) are
/// swapped for them before comparing.
final class UIContractTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("contract").appendingPathComponent("ui")
    static let updating = ProcessInfo.processInfo.environment["CONTEXT_GUARD_UPDATE_CONTRACT"] == "1"

    // MARK: Boards

    /// Each board: the fixture's state, then the board's line at a time.
    var boards: [(name: String, make: (FeedFixture) throws -> String)] { [
        ("empty", { fx in
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            return Feed.line(.board(feed.board(now: fx.t0)))
        }),
        ("asking", { fx in
            try fx.session(1, title: "Refactor the billing API", cwd: #"C:\code\billing"#, tokens: 302_517, waiter: true) { $0.name = "billing-3f" }
            try fx.session(2, title: "Write the release notes", cwd: #"C:\code\docs"#, tokens: 120_000, phase: .watching)
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            return Feed.line(.board(feed.board(now: fx.at(15))))
        }),
        ("asking-no-countdown", { fx in
            try fx.config { $0.autoYesSeconds = 0 }
            try fx.session(1, title: "Refactor the billing API", cwd: #"C:\code\billing"#, tokens: 512_000)
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            return Feed.line(.board(feed.board(now: fx.at(15))))
        }),
        ("codex", { fx in
            fx.linkInstalled = true
            try fx.link()
            try fx.codexSession(1, title: "Add retries to the sync job", cwd: #"C:\code\sync"#)
            try fx.session(2, title: "Tidy the test helpers", cwd: #"C:\code\tests"#, tokens: 88_000, phase: .watching)
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            return Feed.line(.board(feed.board(now: fx.at(15))))
        }),
        ("answered", { fx in
            let busy = try fx.session(1, title: "Refactor the billing API", tokens: 302_300, status: "busy")
            let later = try fx.session(2, title: "Write the release notes", tokens: 302_200, waiter: true)
            let sent = try fx.session(3, title: "Tidy the test helpers", tokens: 302_100)
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            _ = feed.handle(#"{"do":"answer","session":"\#(busy)","action":"yes","source":"popup"}"#, now: fx.at(1))
            _ = feed.handle(#"{"do":"answer","session":"\#(later)","action":"later","source":"popup"}"#, now: fx.at(1))
            _ = feed.handle(#"{"do":"answer","session":"\#(sent)","action":"yes","source":"popup"}"#, now: fx.at(1))
            let answer = Answer.load(sent, fx.paths)?.id
            try fx.edit(sent) { s in
                s.phase = .sent
                s.appliedAnswerId = answer
                s.sentNonce = "cg-3"
                s.confirmedAt = fx.at(2)
            }
            _ = feed.refresh(now: fx.at(2))
            return Feed.line(.board(feed.board(now: fx.at(2))))
        }),
        ("notices", { fx in
            let manual = try fx.session(1, title: "Refactor the billing API", tokens: 302_000, phase: .watching)
            let later = try fx.session(2, title: "Write the release notes", tokens: 512_000, phase: .later)
            let compacted = try fx.session(3, title: "Tidy the test helpers", tokens: 188_400, phase: .watching)
            let muted = try fx.session(4, title: "Read the logs", tokens: 40_000, phase: .watching)
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            _ = feed.handle(#"{"do":"watch","session":"\#(muted)","on":false}"#, now: fx.at(1))
            try fx.edit(manual) { s in
                s.phase = .sent
                s.sentNonce = "cg-1"
                s.sendReason = .manual
            }
            try fx.edit(later) { s in
                s.phase = .sent
                s.sentNonce = "cg-2"
                s.sendReason = .later
                s.sentTokens = 512_000
                s.confirmedAt = fx.at(3)
                var f = FollowUp(nonce: "cg-2", now: fx.at(4))
                f.stage = .needsYou
                f.note = "asked which branch to push to."
                s.followUp = f
            }
            try fx.edit(compacted) { s in
                s.lastCompaction = Compaction(at: fx.at(5), trigger: "auto", preTokens: 188_400, postTokens: 21_000, interruptedPhase: .queued)
            }
            _ = feed.refresh(now: fx.at(6))
            return Feed.line(.board(feed.board(now: fx.at(6))))
        }),
        ("off", { fx in
            try fx.session(1, title: "Refactor the billing API", cwd: #"C:\code\billing"#, tokens: 302_000, phase: .watching)
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            _ = feed.handle(#"{"do":"turnOff"}"#, now: fx.at(1))
            return Feed.line(.board(feed.board(now: fx.at(1))))
        }),
        ("settings", { fx in
            try fx.installClaudeSide()
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            _ = feed.handle(#"{"do":"settingsOpen"}"#, now: fx.t0)
            return Feed.line(.board(feed.board(now: fx.t0)))
        }),
        ("settings-edited", { fx in
            try fx.installClaudeSide()
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            for intent in [#"{"do":"settingsOpen"}"#, #"{"do":"set","field":"laterK","value":"250"}"#,
                           #"{"do":"set","field":"autoYes","value":"30"}"#, #"{"do":"set","field":"message","value":""}"#,
                           #"{"do":"set","field":"continueMessage","value":"carry on"}"#] {
                _ = feed.handle(intent, now: fx.at(1))
            }
            return Feed.line(.board(feed.board(now: fx.at(1))))
        }),
        ("settings-codex", { fx in
            fx.linkInstalled = true
            try fx.link(judge: nil, onlyWatching: "this Codex can't start a turn from outside")
            let feed = fx.feed()
            _ = feed.start(now: fx.t0)
            for intent in [#"{"do":"settingsOpen"}"#, #"{"do":"set","field":"codexAsk","value":"65"}"#,
                           #"{"do":"set","field":"askK","value":""}"#] {
                _ = feed.handle(intent, now: fx.at(1))
            }
            return Feed.line(.board(feed.board(now: fx.at(1))))
        }),
    ] }

    func testBoards() throws {
        for (name, make) in boards {
            let fx = FeedFixture()
            try check("boards/\(name).json", make(fx))
        }
        try checkFolder("boards", boards.map(\.name))
    }

    // MARK: Messages

    static let messages: [(name: String, message: FeedMessage)] = [
        ("chime", .chime),
        ("result", .result(id: "7", problem: nil)),
        ("result-problem", .result(id: "8", problem: "Settings isn't open.")),
        ("result-start", .result(id: nil, problem: "couldn't write the settings file.")),
        ("error", .error("not an intent: nonsense")),
    ]

    func testMessages() throws {
        for (name, message) in Self.messages {
            try check("messages/\(name).json", Feed.line(message))
        }
        try checkFolder("messages", Self.messages.map(\.name))
    }

    // MARK: Intents

    static let session = "00000000-0000-4000-8000-000000000001"

    /// Each file and what it means.
    static let intents: [(name: String, id: String?, intent: FeedIntent)] = [
        ("answer", "1", .answer(session: session, action: .later, source: .popup)),
        ("compact-now", "2", .answer(session: session, action: .yes, source: .menu)),
        ("turn-off", "3", .turnOff),
        ("enable", "4", .enable(false)),
        ("watch", "5", .watch(session: session, on: false)),
        ("hide", "6", .hide(session: session)),
        ("show", "7", .show(session: session)),
        ("close", "8", .close(key: "notice:off:1")),
        ("settings-open", "9", .settingsOpen),
        ("settings-close", "10", .settingsClose),
        ("set", "11", .set(.askK, "200")),
        ("set-message", "12", .set(.message, "Save your work first.")),
        ("step", "13", .step(.autoYes, up: true)),
        ("restore", "14", .restore(.message)),
        ("no-id", nil, .settingsOpen),
    ]

    func testIntents() throws {
        for (name, id, intent) in Self.intents {
            let url = Self.folder.appendingPathComponent("intents/\(name).json")
            let data = try Data(contentsOf: url)
            let request = try JSONDecoder().decode(FeedRequest.self, from: data)
            XCTAssertEqual(request.id, id, name)
            XCTAssertEqual(request.intent, intent, name)
            // Written as the boards are, so they read the same way.
            XCTAssertEqual(try Self.canonical(data), Self.lf(String(decoding: data, as: UTF8.self)), "\(name): not as jq prints it")
        }
        try checkFolder("intents", Self.intents.map(\.name))
    }

    // MARK: Checking

    /// The JSON as `jq .` prints it, keys in byte order at every level.
    static func canonical(_ data: Data) throws -> String {
        func sorted(_ j: OrderedJSON) -> OrderedJSON {
            switch j {
            case .array(let items): return .array(items.map(sorted))
            case .object(let members):
                return .object(members.map { OrderedJSON.Member($0.key, sorted($0.value)) }
                    .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) })
            default: return j
            }
        }
        return sorted(try OrderedJSON.parse(data)).jqText
    }

    static func lf(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n") }

    /// The Windows app's words in place of the Mac's.
    static func windowsWords(_ text: String) -> String {
        guard !PathRules.isWindows else { return text }
        return text.replacingOccurrences(of: Words.installer(windows: false), with: Words.installer(windows: true))
            .replacingOccurrences(of: Words.Notice.turnBackOn(windows: false), with: Words.Notice.turnBackOn(windows: true))
    }

    func check(_ file: String, _ message: String, line: UInt = #line) throws {
        XCTAssertFalse(message.contains("\n"), "\(file): a message is one line", line: line)
        let text = Self.windowsWords(try Self.canonical(Data(message.utf8)))
        let url = Self.folder.appendingPathComponent(file)
        if Self.updating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(file) is missing: run with CONTEXT_GUARD_UPDATE_CONTRACT=1", line: line)
            return
        }
        XCTAssertEqual(text, Self.lf(expected), "\(file) differs: run with CONTEXT_GUARD_UPDATE_CONTRACT=1 and read the diff", line: line)
    }

    /// The folder holds these files and no others.
    func checkFolder(_ folder: String, _ names: [String]) throws {
        let dir = Self.folder.appendingPathComponent(folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), Set(names.map { "\($0).json" }), "\(folder): a file without a test, or a test without a file")
    }
}
