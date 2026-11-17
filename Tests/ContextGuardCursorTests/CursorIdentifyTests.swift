import ContextGuardCore
import ContextGuardTestSupport
@testable import ContextGuardCursor
import XCTest

/// A process table the tests control: who started whom, under what name, from which program.
final class FakeProcesses: ProcessLineage, ProcessProbing, @unchecked Sendable {
    struct Proc { var parent: Int32; var name: String; var exe: String }
    private let lock = NSLock()
    private var table: [Int32: Proc] = [:]

    func add(_ pid: Int32, parent: Int32, name: String, exe: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        table[pid] = Proc(parent: parent, name: name, exe: exe ?? "/usr/bin/\(name)")
    }

    func parent(of pid: Int32) -> Int32? { lock.lock(); defer { lock.unlock() }; return table[pid]?.parent }
    func name(of pid: Int32) -> String? { lock.lock(); defer { lock.unlock() }; return table[pid]?.name }
    func executable(of pid: Int32) -> String? { lock.lock(); defer { lock.unlock() }; return table[pid]?.exe }
    func identity(of pid: Int32) -> ProcessIdentity? {
        lock.lock(); defer { lock.unlock() }
        return table[pid] == nil ? nil : ProcessIdentity(start: ProcessStart(seconds: Int(pid) * 10, microseconds: 0), hasTTY: false)
    }
}

final class CursorIdentifyTests: XCTestCase {
    static let cursorApp: Int32 = 96482
    static let cursorAgent: Int32 = 7102
    static let app = ["VSCODE_PID": "96482", "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "CURSOR_PROJECT_DIR": "/p"]
    static let tmux = ["TMUX": "/private/tmp/tmux-501/default,7101,0", "TMUX_PANE": "%3", "TERM_PROGRAM": "tmux"]
    static let herdr = ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p2", "HERDR_SOCKET_PATH": "/Users/me/.config/herdr/herdr.sock",
                        "HERDR_SESSION": "default"]

    var dir: TempDir!
    var procs: FakeProcesses!
    var identify: CursorIdentify!

    override func setUp() {
        dir = TempDir()
        procs = FakeProcesses()
        let app = CursorAppStore(file: CursorAppStoreTests.makeStore(dir).url)
        let cli = CursorCLIStoreTests.store(dir)
        CursorCLIStoreTests.makeChat(cli.root)
        identify = CursorIdentify(appStore: app, cliStore: cli, lineage: procs, probe: procs)
        identify.accessibility = { true }
        // The app: Cursor → its extension host → the hook's shell → the hook.
        procs.add(Self.cursorApp, parent: 1, name: "Cursor", exe: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        procs.add(14560, parent: Self.cursorApp, name: "Cursor Helper (Plugin)",
                  exe: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        procs.add(21599, parent: 14560, name: "zsh")
        procs.add(21600, parent: 21599, name: "context-guard")
        // The CLI: a terminal → tmux → cursor-agent (Node, started as "cursor-agent") → shell → hook.
        procs.add(7101, parent: 1, name: "tmux")
        procs.add(Self.cursorAgent, parent: 7101, name: "cursor-agent", exe: "/Users/me/.local/share/cursor-agent/versions/1/node")
        procs.add(12935, parent: Self.cursorAgent, name: "zsh")
        procs.add(13048, parent: 12935, name: "context-guard")
    }

    func input(_ id: String) -> CursorHookInput { CursorHookInput(event: "stop", conversationId: id) }

    func testAnAppChat() {
        let look = identify.look(input(CursorAppStoreTests.chat), environment: Self.app, hookPid: 21600)
        XCTAssertEqual(look, CursorChatLook(surface: .app, tokens: 115_251, window: 256_000, name: "Fix the parser",
                                            pid: Self.cursorApp, start: ProcessStart(seconds: 964_820, microseconds: 0),
                                            canType: true))
        // Without Cursor's Accessibility permission, Settings says so.
        identify.accessibility = { false }
        XCTAssertEqual(identify.look(input(CursorAppStoreTests.chat), environment: Self.app, hookPid: 21600).canType, false)
    }

    func testAnAppChatWhoseAgentRunsInAWorkerCursorLetGoOf() {
        // The app's agent workers are `cursor-agent` processes; some outlive the window that started them.
        procs.add(18163, parent: 1, name: "cursor-agent")
        procs.add(18200, parent: 18163, name: "zsh")
        procs.add(18201, parent: 18200, name: "context-guard")
        let look = identify.look(input(CursorAppStoreTests.chat), environment: Self.app.merging(["CURSOR_INVOKED_AS": "cursor-agent"]) { $1 },
                                 hookPid: 18201)
        XCTAssertEqual(look.surface, .app)
        XCTAssertEqual(look.pid, Self.cursorApp)
        // …and if Cursor has quit, the chat has no process.
        procs.add(Self.cursorApp, parent: 1, name: "Cursor", exe: "/gone")
        let gone = CursorIdentify(appStore: identify.appStore, cliStore: identify.cliStore, lineage: procs, probe: FakeProcesses())
        XCTAssertNil(gone.look(input(CursorAppStoreTests.chat), environment: Self.app, hookPid: 18201).pid)
    }

    func testHelperChats() {
        XCTAssertEqual(identify.look(input(CursorAppStoreTests.subagent), environment: Self.app, hookPid: 21600).helper, true)
        XCTAssertEqual(identify.look(input(CursorAppStoreTests.background), environment: Self.app, hookPid: 21600).helper, true)
    }

    func testACLIChatInTmux() {
        let env = Self.tmux.merging(["CURSOR_INVOKED_AS": "cursor-agent", "__CFBundleIdentifier": "dev.warp.Warp-Stable"]) { $1 }
        let look = identify.look(input(CursorCLIStoreTests.chat), environment: env, hookPid: 13048)
        XCTAssertEqual(look, CursorChatLook(surface: .cli, tokens: 17_458, window: 256_000, name: "README Summary",
                                            pid: Self.cursorAgent, start: ProcessStart(seconds: 71_020, microseconds: 0),
                                            terminal: CursorTerminal(kind: .tmux, pane: "%3", socket: "/private/tmp/tmux-501/default")))
    }

    func testACLIChatInHerdrOrAnotherTerminal() {
        let id = CursorCLIStoreTests.chat
        XCTAssertEqual(identify.look(input(id), environment: Self.herdr, hookPid: 13048).terminal,
                       CursorTerminal(kind: .herdr, pane: "w1:p2", socket: "/Users/me/.config/herdr/herdr.sock"))
        let warp = identify.look(input(id), environment: ["TERM_PROGRAM": "WarpTerminal"], hookPid: 13048)
        XCTAssertEqual(warp.surface, .cli)
        XCTAssertNil(warp.terminal)
        // In Cursor's own terminal the app's variables are there too: the store decides.
        XCTAssertEqual(identify.look(input(id), environment: Self.app, hookPid: 13048).surface, .cli)
    }

    func testCallsLeftAlone() {
        // The judge's own runs, whatever store they're in.
        let judge = identify.look(input(CursorCLIStoreTests.chat), environment: ["CONTEXT_GUARD_JUDGE": "1"], hookPid: 13048)
        XCTAssertEqual(judge, CursorChatLook(surface: nil))
        // A chat in neither store (a `-p` run before it saved anything), and nonsense.
        XCTAssertNil(identify.look(input("11111111-2222-3333-4444-555555555555"), environment: Self.app, hookPid: 21600).surface)
        XCTAssertNil(identify.look(input("../../etc"), environment: Self.app, hookPid: 21600).surface)
    }

    func testTerminal() {
        XCTAssertNil(CursorIdentify.terminal([:]))
        XCTAssertNil(CursorIdentify.terminal(["TMUX_PANE": "%1"]), "no server")
        XCTAssertNil(CursorIdentify.terminal(["HERDR_PANE_ID": "w1:p1"]), "not in herdr")
        XCTAssertEqual(CursorIdentify.terminal(["TMUX": ",1,0", "TMUX_PANE": "%1"]), CursorTerminal(kind: .tmux, pane: "%1"))
        // tmux inside a herdr pane, and herdr inside tmux: the inner one.
        XCTAssertEqual(CursorIdentify.terminal(Self.herdr.merging(Self.tmux) { $1 })?.kind, .tmux)
        XCTAssertEqual(CursorIdentify.terminal(Self.herdr.merging(Self.tmux) { $1 }.merging(["TERM_PROGRAM": "xterm"]) { $1 })?.kind, .herdr)
    }

    func testTheSystemsProcessTable() {
        let me = ProcessInfo.processInfo.processIdentifier
        let real = SystemProcessLineage()
        XCTAssertEqual(real.parent(of: me), getppid())
        XCTAssertNotNil(real.name(of: me))
        XCTAssertEqual(real.executable(of: me).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       Bundle.main.executableURL?.resolvingSymlinksInPath().path)
        XCTAssertNil(real.parent(of: -1))
        XCTAssertNil(real.name(of: 999_999))
        XCTAssertNil(real.executable(of: 999_999))
        XCTAssertNil(real.ancestor(of: me) { _ in false })
    }
}
