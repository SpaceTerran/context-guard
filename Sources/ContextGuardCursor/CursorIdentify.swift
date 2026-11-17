import ApplicationServices
import ContextGuardCore
import Foundation

/// Which chat a Cursor hook call is about, and where it runs: the Cursor app or the Cursor CLI, the
/// process that runs it, and (for the CLI) the terminal pane Context Guard can type into. Cursor's
/// own stores decide: a chat in neither one (a `cursor-agent -p` run, or one Context Guard's judge
/// started) is left alone.
public struct CursorIdentify: Sendable {
    public var appStore: CursorAppStore
    public var cliStore: CursorCLIStore
    public var lineage: any ProcessLineage
    public var probe: any ProcessProbing
    /// Whether this process may use Accessibility: a hook's is Cursor's own permission.
    public var accessibility: @Sendable () -> Bool = { AXIsProcessTrusted() }

    /// Set in the environment of the `cursor-agent` runs Context Guard's judge starts, so their hooks
    /// know to leave them alone.
    public static let judgeMarker = "CONTEXT_GUARD_JUDGE"

    public init(appStore: CursorAppStore = CursorAppStore(), cliStore: CursorCLIStore = CursorCLIStore(),
                lineage: any ProcessLineage = SystemProcessLineage(), probe: any ProcessProbing = SystemProcessProbe()) {
        self.appStore = appStore
        self.cliStore = cliStore
        self.lineage = lineage
        self.probe = probe
    }

    /// `hookPid`: the hook's own process; Cursor starts it through a shell.
    public func look(_ input: CursorHookInput, environment env: [String: String],
                     hookPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> CursorChatLook {
        let id = input.conversationId
        guard env[Self.judgeMarker] != "1", Paths.isValidSessionID(id) else { return CursorChatLook(surface: nil) }
        if let chat = appStore.chat(id) {
            let pid = lineage.ancestor(of: hookPid) { isCursorApp($0) }
                ?? env["VSCODE_PID"].flatMap { Int32($0) }.flatMap { probe.identity(of: $0) != nil ? $0 : nil }
            var found = look(.app, chat, pid: pid, terminal: nil)
            found.canType = accessibility()
            return found
        }
        if let chat = cliStore.chat(id) {
            let pid = lineage.ancestor(of: hookPid) { lineage.name(of: $0) == "cursor-agent" }
            return look(.cli, chat, pid: pid, terminal: Self.terminal(env))
        }
        return CursorChatLook(surface: nil)
    }

    private func look(_ surface: CursorSurface, _ chat: CursorStoredChat, pid: Int32?, terminal: CursorTerminal?) -> CursorChatLook {
        CursorChatLook(surface: surface, helper: chat.helper, tokens: chat.tokens, window: chat.window, name: chat.name,
                       pid: pid, start: pid.flatMap { probe.identity(of: $0)?.start }, terminal: terminal)
    }

    /// The Cursor app's main process (its helpers run from inside the bundle's Frameworks).
    func isCursorApp(_ pid: Int32) -> Bool {
        guard let exe = lineage.executable(of: pid) else { return false }
        return exe.hasSuffix(".app/Contents/MacOS/Cursor")
    }

    /// The pane a CLI chat runs in, from the environment its terminal program gives every process in
    /// it. The innermost wins: tmux names itself in `TERM_PROGRAM`; herdr sets `HERDR_ENV`.
    public static func terminal(_ env: [String: String]) -> CursorTerminal? {
        func tmux() -> CursorTerminal? {
            guard let pane = env["TMUX_PANE"], !pane.isEmpty, let tmux = env["TMUX"], !tmux.isEmpty else { return nil }
            let socket = tmux.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            return CursorTerminal(kind: .tmux, pane: pane, socket: socket.flatMap { $0.isEmpty ? nil : $0 })
        }
        func herdr() -> CursorTerminal? {
            guard env["HERDR_ENV"] == "1", let pane = env["HERDR_PANE_ID"], !pane.isEmpty else { return nil }
            return CursorTerminal(kind: .herdr, pane: pane, socket: env["HERDR_SOCKET_PATH"].flatMap { $0.isEmpty ? nil : $0 })
        }
        if env["TERM_PROGRAM"] == "tmux", let t = tmux() { return t }
        return herdr() ?? tmux()
    }
}
