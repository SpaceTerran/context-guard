import AppKit
import ContextGuardCore
import ContextGuardCursor
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    /// The window, empty: Settings opens in it (and so does `live-test/ui-demo.sh capture`).
    static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.title = Words.Settings.windowTitle
        // The brand's background runs under the title bar.
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Theme.windowBackground
        w.isReleasedWhenClosed = false
        return w
    }

    static func fill(_ window: NSWindow, model: AppModel, tab: SettingsTab = .general) {
        let host = NSHostingController(rootView: SettingsView(model: model, tab: tab))
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
    }

    func show(model: AppModel) {
        if window == nil { window = Self.makeWindow() }
        guard let window else { return }
        if !window.isVisible {
            // Fresh each time it opens, so it shows settings changed elsewhere (the CLI, the menu).
            Self.fill(window, model: model)
            window.center()
        }
        // Wait for the menu to finish closing: activating while it still tracks the mouse is
        // refused, and the window opens behind the terminal.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// A tab per tool, so a tool that comes into the picture adds a tab, never height: General (Context
/// Guard itself and the countdown every tool shares), then each tool's setup and thresholds, then
/// the messages. Codex's and Cursor's show once they're in the picture.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, claude, codex, cursor, messages
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return Words.Settings.general
        case .claude: return SessionHost.claude.name
        case .codex: return SessionHost.codex.name
        case .cursor: return SessionHost.cursor.name
        case .messages: return Words.Settings.messages
        }
    }

    /// The tabs Settings shows, in order.
    static func shown(showsCodex: Bool, showsCursor: Bool) -> [SettingsTab] {
        allCases.filter { tab in
            switch tab {
            case .codex: return showsCodex
            case .cursor: return showsCursor
            case .general, .claude, .messages: return true
            }
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var tab = SettingsTab.general
    /// Each field as typed, and whether each card's changes are on disk.
    @State private var form: SettingsForm
    @State private var login = LoginItem.state
    @State private var loginError: String?
    private let hooksInstalled: Bool
    private let modInstalled: Bool
    private let codexLinkInstalled: Bool
    private let cursorHooksInstalled: Bool
    private let cursorCLIFound: Bool

    static let width: CGFloat = 600
    /// Both message boxes: five lines before they scroll.
    static let editorHeight: CGFloat = 112

    init(model: AppModel, tab: SettingsTab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
        _form = State(initialValue: SettingsForm(model.config))
        hooksInstalled = HookInstall.isInstalled(model.paths)
        modInstalled = ModInstall.isInstalled(model.paths)
        codexLinkInstalled = CodexLinkInstall.isInstalled(model.paths)
        cursorHooksInstalled = CursorHookSetup.isInstalled()
        cursorCLIFound = CursorAutoJudge.cliFound()
    }

    private var tabs: [SettingsTab] { SettingsTab.shown(showsCodex: model.showsCodex, showsCursor: model.showsCursor) }
    private var otherTools: Bool { model.showsCodex || model.showsCursor }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TabBar(tabs: tabs, title: \.title, selection: $tab)
            // Every tab is laid out, so the window is as tall as the tallest and never jumps.
            ZStack(alignment: .topLeading) {
                ForEach(tabs) { t in
                    let shown = t == tab
                    page(t)
                        .opacity(shown ? 1 : 0)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg)
        .toggleStyle(BrandSwitchStyle())
        .tint(Theme.primary)
    }

    @ViewBuilder
    private func page(_ t: SettingsTab) -> some View {
        switch t {
        case .general: general
        case .claude: claude
        case .codex: codex
        case .cursor: cursor
        case .messages: messages
        }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(title: Words.Settings.contextGuard) {
                let watch = SettingsText.watchLabel(otherTools: otherTools)
                Row(label: watch) {
                    Toggle(watch, isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
                        .labelsHidden()
                }
                Rule()
                Row(label: Words.Settings.openAtLogin) {
                    // A closure, not `set: setLogin`: Swift 6.1 to 6.3 crash building the method reference here.
                    Toggle(Words.Settings.openAtLogin, isOn: Binding(get: { login == .enabled }, set: { setLogin($0) }))
                        .labelsHidden()
                        .disabled(login == .unavailable)
                }
                if login == .needsApproval {
                    Rule()
                    Row(label: "Allow it in System Settings › General › Login Items.") {
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(BrandButtonStyle(kind: .secondary, height: 28))
                    }
                }
                if let loginError {
                    Rule()
                    cardNote(loginError, color: Theme.danger)
                }
            }
            Note(Words.Settings.offNote)
                .padding(.horizontal, 2)
                .padding(.bottom, 14)
            // The countdown every tool's popup shares.
            Card(title: Words.Settings.ifYouDontAnswer) {
                numberField(.autoYes)
            } accessory: {
                SaveStatusLabel(status: form.countdownStatus)
            }
            note(form.countdownNote(otherTools: otherTools))
        }
    }

    // MARK: Each tool: what's installed and who judges, then when to ask

    private var claude: some View {
        toolPage(.claude, status: form.claudeStatus, note: form.claudeNote, fields: [.askK, .laterK]) {
            Row(label: Words.Settings.hooks) { StatusLabel(SettingsText.installed(hooksInstalled)) }
                .help(Words.Settings.hooksHelp)
            Rule()
            Row(label: Words.Settings.mod) { StatusLabel(SettingsText.installed(modInstalled)) }
                .help(Words.Settings.modHelp)
            Rule()
            Row(label: Words.Settings.judge) { StatusLabel(SettingsText.claudeJudge) }
                .help(Words.Settings.judgeHelp)
        }
    }

    private var codex: some View {
        toolPage(.codex, status: form.codexStatus, note: form.codexNote, fields: [.codexAsk, .codexLater]) {
            Row(label: Words.Settings.link) { StatusLabel(SettingsText.link(model.codexLink, installed: codexLinkInstalled)) }
                .help(Words.Settings.linkHelp)
            if case .onlyWatching(let why) = model.codexLink {
                Rule()
                cardNote(SettingsText.onlyWatchingNote(why), color: Theme.warning)
            }
            Rule()
            Row(label: Words.Settings.judge) { StatusLabel(SettingsText.codexJudge(model.codexJudge, link: model.codexLink)) }
                .help(Words.Settings.judgeHelp)
        }
    }

    private var cursor: some View {
        let canType = Display.cursorCanType(model.sessions)
        return toolPage(.cursor, status: form.cursorStatus, note: form.cursorNote, fields: [.cursorAsk, .cursorLater]) {
            Row(label: Words.Settings.hooks) { StatusLabel(SettingsText.installed(cursorHooksInstalled)) }
                .help(Words.Settings.cursorHooksHelp)
            Rule()
            Row(label: Words.Settings.typing) { StatusLabel(SettingsText.cursorTyping(canType)) }
                .help(Words.Settings.typingHelp)
            if canType == false {
                Rule()
                cardNote(SettingsText.cursorAccessibilityNote, color: Theme.warning)
            }
            Rule()
            Row(label: Words.Settings.judge) { StatusLabel(SettingsText.cursorJudge(cliFound: cursorCLIFound)) }
                .help(Words.Settings.judgeHelp)
            if !cursorCLIFound {
                Rule()
                cardNote(SettingsText.noCursorCLINote, color: Theme.warning)
            }
        }
    }

    /// A tool's tab: its setup and whose sign-in the judge uses, then its thresholds and what they
    /// come to.
    private func toolPage<Rows: View>(_ host: SessionHost, status: SaveStatus, note thresholds: SettingsNote,
                                      fields: [SettingsForm.Field], @ViewBuilder setup: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(title: Words.Settings.setup, content: setup)
            Note(SettingsText.signInNote(host))
                .padding(.horizontal, 2)
                .padding(.bottom, 14)
            Card(title: Words.Settings.whenToAskCard) {
                ForEach(Array(fields.enumerated()), id: \.element) { i, f in
                    if i > 0 { Rule() }
                    numberField(f)
                }
            } accessory: {
                // Thresholds that don't make sense aren't saved; the note under the card says why.
                SaveStatusLabel(status: status)
            }
            note(thresholds)
        }
    }

    /// A line of text inside a card, between its rows.
    private func cardNote(_ text: String, color: Color) -> some View {
        Note(text, color: color)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private func numberField(_ f: SettingsForm.Field) -> some View {
        NumberField(form.field(f, ownCountdownCard: true),
                    value: Binding(get: { form.number(f) }, set: { form.set(f, number: $0, save: { save($0) }) }),
                    invalid: form.invalid(f))
    }

    /// The note under a card: why it isn't saved, or what it does.
    private func note(_ n: SettingsNote) -> some View {
        Note(n.text, color: Theme.color(n.tone))
            .padding(.horizontal, 2)
    }

    // MARK: Messages

    private var messages: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageCard(.message, title: Words.Settings.beforeCompacting, what: Words.Settings.saveMessage)
            messageCard(.continueMessage, title: Words.Settings.afterCompacting, what: Words.Settings.continueMessage)
                .padding(.top, 10)
            Note(SettingsText.messagesNote(codexJudge: model.showsCodex ? SettingsText.codexJudgeName(model.codexJudge, link: model.codexLink) : nil,
                                           showsCursor: model.showsCursor))
                .padding(.horizontal, 2)
        }
    }

    /// A message box, what it's for (or why it isn't saved) and Restore Default.
    private func messageCard(_ f: SettingsForm.Field, title: String, what: String) -> some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                BrandTextEditor(label: title, text: Binding(get: { form.text(f) }, set: { form.set(f, typed: $0, save: { save($0) }) }),
                                height: Self.editorHeight)
                HStack(alignment: .center) {
                    let note = form.messageNote(f)
                    Note(note.text, color: Theme.color(note.tone))
                    Button(Words.Settings.restoreDefault) { form.restore(f, save: { save($0) }) }
                        .buttonStyle(BrandButtonStyle(kind: .ghost, height: 28))
                        .disabled(!form.canRestore(f))
                        .help(SettingsText.restoreHelp(what))
                }
            }
            .padding(16)
        } accessory: {
            SaveStatusLabel(status: form.status(f))
        }
    }

    // MARK: Saving

    /// Changes the settings and saves them at once; why that didn't work, or nil.
    private func save(_ change: (inout Config) -> Void) -> String? {
        var c = model.config
        change(&c)
        return model.save(c)
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            try LoginItem.set(on)
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
        }
        login = LoginItem.state
    }
}

struct SaveStatusLabel: View {
    let status: SaveStatus

    var body: some View {
        StatusLabel(status.line, size: 12)
    }
}

enum LoginItem {
    enum State { case enabled, disabled, needsApproval, unavailable }

    /// Only a real app bundle can be a login item (not the bare binary `swift run` builds).
    static var state: State {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .disabled
        }
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
