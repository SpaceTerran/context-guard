import ContextGuardCore
import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCodexLink

final class CodexAttachmentTests: XCTestCase {
    let dir = TempDir()

    func terminal(_ args: String..., in cwd: String = "/Users/demo/code", started: Double? = nil) -> CodexTerminalProcess {
        CodexTerminalProcess(pid: Int32.random(in: 100...9_999), cwd: cwd, args: ["codex"] + args, startedAt: started)
    }

    func thread(_ id: String, in cwd: String? = "/Users/demo/code", at recency: Double = 0, created: Double? = nil,
                originator: String? = "codex-tui") -> CodexThreadInfo {
        CodexThreadInfo(id: id, path: "/r/\(id).jsonl", cwd: cwd, status: "idle", originator: originator, recencyAt: recency,
                        createdAt: created)
    }

    func testTheCommandWordsWithoutItsOptions() {
        XCTAssertEqual(CodexAttachment.words(["codex", "-m", "gpt-6-luna", "resume", "t1"]), ["resume", "t1"])
        XCTAssertEqual(CodexAttachment.words(["codex", "-c", "model=x", "--full-auto", "fix the tests"]), ["fix the tests"])
        XCTAssertEqual(CodexAttachment.words(["codex", "--", "-not-an-option"]), ["-not-an-option"])
        XCTAssertEqual(CodexAttachment.words(["codex"]), [])
    }

    func testWhichCommandsAreTheTerminalApp() {
        XCTAssertTrue(CodexAttachment.isTerminalApp(["codex"]))
        XCTAssertTrue(CodexAttachment.isTerminalApp(["codex", "fix the tests"]), "with a first prompt")
        XCTAssertTrue(CodexAttachment.isTerminalApp(["codex", "resume", "--last"]))
        XCTAssertTrue(CodexAttachment.isTerminalApp(["codex", "-m", "exec"]), "a model named like a command")
        for other in ["exec", "e", "app-server", "mcp-server", "login", "apply", "cloud", "exec-server"] {
            XCTAssertFalse(CodexAttachment.isTerminalApp(["codex", other, "x"]), other)
        }
    }

    #if os(Windows)
    func testTheFolderItRunsIn() throws {
        let work = dir.file("Work")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("App"), withIntermediateDirectories: true)
        let real = CodexAttachment.resolved(work.path)
        XCTAssertTrue(real.contains(":\\"), "a full Windows path: \(real)")
        XCTAssertFalse(real.contains("/"), "Windows separators only: \(real)")
        XCTAssertEqual(CodexAttachment.resolved(real.lowercased() + "\\"), real, "its real case, no trailing separator")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal(in: real + "\\")), real)
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("-C", "app", in: real)), real + "\\App")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("--cd", work.path + "/App", in: "C:\\")), real + "\\App")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("--cd=App", in: real)), real + "\\App")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("-CApp", in: real)), real + "\\App")
        XCTAssertEqual(CodexAttachment.resolved("\\\\?\\" + real), real, "the long-path prefix comes off")
    }

    func testFoldersMatchWhateverTheirCase() {
        let threads = [thread("here", in: "C:\\Users\\Demo\\Code", at: 10)]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal(in: "c:/users/demo/code/")]), ["here": true])
    }
    #else
    func testTheFolderItRunsIn() throws {
        let work = dir.file("work")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("app"), withIntermediateDirectories: true)
        let real = CodexAttachment.resolved(work.path)
        XCTAssertTrue(real.hasPrefix("/private/"), "the temporary folder's real path")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal(in: work.path)), real)
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("-C", "app", in: work.path)), real + "/app")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("--cd", work.path + "/app", in: "/")), real + "/app")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("--cd=app", in: work.path)), real + "/app")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("-Capp", in: work.path)), real + "/app")
        XCTAssertEqual(CodexAttachment.sessionFolder(terminal("-C", "~", in: "/")), CodexAttachment.resolved(NSHomeDirectory()))
    }
    #endif

    func testTheSessionAResumeNames() {
        XCTAssertEqual(CodexAttachment.namedSession(terminal("resume", "t1")), "t1")
        XCTAssertEqual(CodexAttachment.namedSession(terminal("-m", "gpt-6-luna", "resume", "t1")), "t1")
        XCTAssertNil(CodexAttachment.namedSession(terminal("resume", "--last")))
        XCTAssertNil(CodexAttachment.namedSession(terminal("resume")))
        XCTAssertNil(CodexAttachment.namedSession(terminal("fix", "t1")))
    }

    func testEachTerminalHoldsTheNewestSessionInItsFolder() {
        let threads = [thread("old", at: 10), thread("new", at: 20), thread("newest", at: 30)]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal()]),
                       ["old": false, "new": false, "newest": true])
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal(), terminal()]),
                       ["old": false, "new": true, "newest": true])
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: []),
                       ["old": false, "new": false, "newest": false])
    }

    func testAResumeHoldsTheSessionItNames() {
        let threads = [thread("old", at: 10), thread("new", at: 20)]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal("resume", "old")]),
                       ["old": true, "new": false], "the named one, not the newest")
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal("resume", "old"), terminal()]),
                       ["old": true, "new": true])
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal("resume", "gone")]),
                       ["old": false, "new": true], "one naming a session not loaded holds its folder's newest")
    }

    func testANewSessionInAResumedTerminalTakesItsPlace() {
        // `codex resume old`, then `/new`: the command line still names old.
        let resumed = terminal("resume", "old", started: 1_000.4)
        let old = thread("old", at: 1_030, created: 500)
        XCTAssertEqual(CodexAttachment.attached(threads: [old], terminals: [resumed]), ["old": true])
        let new = thread("new", at: 1_060, created: 1_060)
        XCTAssertEqual(CodexAttachment.attached(threads: [old, new], terminals: [resumed]), ["old": false, "new": true])
        let newer = thread("newer", at: 1_090, created: 1_090)
        XCTAssertEqual(CodexAttachment.attached(threads: [old, new, newer], terminals: [resumed]),
                       ["old": false, "new": false, "newer": true], "a second /new")
    }

    func testATerminalStartedLaterKeepsTheSessionItStarted() {
        // A resumed terminal, then a plain one in the same folder: each keeps its own.
        let resumed = terminal("resume", "old", started: 1_000)
        let plain = terminal(started: 2_000.8)
        let threads = [thread("old", at: 2_500, created: 500), thread("mine", at: 2_001, created: 2_000),
                       thread("stale", at: 2_600, created: 300)]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [resumed, plain]),
                       ["old": true, "mine": true, "stale": false])
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [plain, resumed]),
                       ["old": true, "mine": true, "stale": false], "in either order")
    }

    func testTwoTerminalsOnOneSessionHoldOnlyThatOne() {
        let threads = [thread("old", at: 10, created: 5), thread("other", at: 20, created: 6)]
        let both = [terminal("resume", "old", started: 100), terminal("resume", "old", started: 200)]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: both), ["old": true, "other": false])
    }

    func testOnlyTheTerminalAppsOwnSessionsCount() {
        let threads = [thread("tui", at: 10), thread("desktop", at: 30, originator: "Codex Desktop"), thread("exec", at: 40, originator: nil)]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal()]),
                       ["tui": true, "desktop": false, "exec": false])
    }

    func testASessionNamedAfterTheLinkIsTheTerminalApps() {
        // The link was the app server's first client, so Codex named the terminal's session after it.
        let threads = [thread("tui", at: 10, originator: "context_guard"), thread("desktop", at: 30, originator: "Codex Desktop")]
        XCTAssertEqual(CodexAttachment.attached(threads: threads, terminals: [terminal()]), ["tui": true, "desktop": false])
    }

    func testFoldersAreKeptApart() {
        let threads = [thread("here", in: "/Users/demo/code", at: 10), thread("there", in: "/Users/demo/other", at: 30), thread("nowhere", in: nil)]
        let attached = CodexAttachment.attached(threads: threads, terminals: [terminal(in: "/Users/demo/code")])
        XCTAssertEqual(attached["here"], true)
        XCTAssertEqual(attached["there"], false)
        XCTAssertNil(attached["nowhere"], "a folder that isn't known can't be told")
    }

    #if os(Windows)
    func testTheProgramNames() {
        XCTAssertTrue(SystemCodexTerminals.isCodexProgram("codex.exe"))
        XCTAssertTrue(SystemCodexTerminals.isCodexProgram("Codex.EXE"))
        XCTAssertFalse(SystemCodexTerminals.isCodexProgram("codex"))
        XCTAssertFalse(SystemCodexTerminals.isCodexProgram("node.exe"))
    }

    func testThisProcessReadsLikeAnyOther() throws {
        // The probe's readers, on a process that's certainly there.
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(SystemCodexTerminals.name(me).map { $0.lowercased().hasSuffix(".exe") }, true)
        XCTAssertEqual(SystemCodexTerminals.cwd(me), PathRules.native(FileManager.default.currentDirectoryPath))
        let args = try XCTUnwrap(SystemCodexTerminals.arguments(me))
        XCTAssertEqual(args, CommandLine.arguments)
        XCTAssertTrue(SystemCodexTerminals.pids().contains(me))
        let read = try XCTUnwrap(SystemCodexTerminals.read(me))
        let started = try XCTUnwrap(read.startedAt)
        XCTAssertLessThan(started, Date().timeIntervalSince1970)
        XCTAssertGreaterThan(started, Date().timeIntervalSince1970 - 3600, "started within the hour, on the Unix clock")
    }

    func testTheDesktopAppsLongPathsLoseTheirPrefix() {
        XCTAssertEqual(WindowsPaths.withoutPrefix("\\\\?\\C:\\a\\codex.exe"), "C:\\a\\codex.exe")
        XCTAssertEqual(WindowsPaths.withoutPrefix("\\\\?\\UNC\\server\\share"), "\\\\server\\share")
        XCTAssertEqual(WindowsPaths.withoutPrefix("C:\\a"), "C:\\a")
        XCTAssertEqual(WindowsPaths.splitCommandLine(#""C:\Program Files\codex.exe" -m "gpt 6" resume"#),
                       ["C:\\Program Files\\codex.exe", "-m", "gpt 6", "resume"])
    }
    #else
    func testTheProgramNames() {
        XCTAssertTrue(SystemCodexTerminals.isCodexProgram("codex"))
        XCTAssertTrue(SystemCodexTerminals.isCodexProgram("codex-aarch64-apple-darwin"))
        XCTAssertTrue(SystemCodexTerminals.isCodexProgram("codex-x86_64-apple-darwin"))
        XCTAssertFalse(SystemCodexTerminals.isCodexProgram("codex-helper"))
        XCTAssertFalse(SystemCodexTerminals.isCodexProgram("node"))
    }

    func testThisProcessReadsLikeAnyOther() throws {
        // The probe's readers, on a process that's certainly there.
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(SystemCodexTerminals.name(me).map { !$0.isEmpty }, true)
        XCTAssertEqual(SystemCodexTerminals.cwd(me), FileManager.default.currentDirectoryPath)
        let args = try XCTUnwrap(SystemCodexTerminals.arguments(me))
        XCTAssertEqual(args, CommandLine.arguments)
        XCTAssertTrue(SystemCodexTerminals.pids().contains(me))
    }
    #endif
}
