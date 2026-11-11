import AppKit
import ContextGuardCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    /// The window, empty: Settings opens in it (and so does `live-test/ui-demo.sh capture`).
    static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.title = "Context Guard Settings"
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, asking, messages
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return Words.Settings.general
        case .asking: return Words.Settings.whenToAsk
        case .messages: return Words.Settings.messages
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var tab = SettingsTab.general
    @State private var askK: Int
    @State private var laterK: Int
    @State private var codexAsk: Int
    @State private var codexLater: Int
    @State private var autoYes: Int
    @State private var message: String
    @State private var continueMessage: String
    /// Whether each card's changes are on disk, for its header.
    @State private var thresholdsSaved = SaveStatus.unchanged
    @State private var codexSaved = SaveStatus.unchanged
    @State private var countdownSaved = SaveStatus.unchanged
    @State private var messageSaved = SaveStatus.unchanged
    @State private var continueSaved = SaveStatus.unchanged
    @State private var login = LoginItem.state
    @State private var loginError: String?
    private let hooksInstalled: Bool
    private let modInstalled: Bool
    private let codexLinkInstalled: Bool

    static let width: CGFloat = 600
    /// Both message boxes: five lines before they scroll.
    static let editorHeight: CGFloat = 112

    init(model: AppModel, tab: SettingsTab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
        let c = model.config
        _askK = State(initialValue: c.askAt / 1_000)
        _laterK = State(initialValue: c.laterAt / 1_000)
        _codexAsk = State(initialValue: c.codexAskPercent)
        _codexLater = State(initialValue: c.codexLaterPercent)
        _autoYes = State(initialValue: c.autoYesSeconds)
        _message = State(initialValue: c.message)
        _continueMessage = State(initialValue: c.continueMessage)
        hooksInstalled = HookInstall.isInstalled(model.paths)
        modInstalled = ModInstall.isInstalled(model.paths)
        codexLinkInstalled = CodexLinkInstall.isInstalled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TabBar(tabs: SettingsTab.allCases, title: \.title, selection: $tab)
            // Every tab is laid out, so the window is as tall as the tallest and never jumps.
            ZStack(alignment: .topLeading) {
                ForEach(SettingsTab.allCases) { t in
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
        .onChange(of: askK) { saveThresholds() }
        .onChange(of: laterK) { saveThresholds() }
        .onChange(of: codexAsk) { saveCodex() }
        .onChange(of: codexLater) { saveCodex() }
        .onChange(of: autoYes) { countdownSaved = update { $0.autoYesSeconds = autoYes } }
        .onChange(of: message) { messageSaved = update { $0.message = message } }
        .onChange(of: continueMessage) { continueSaved = update { $0.continueMessage = continueMessage } }
    }

    @ViewBuilder
    private func page(_ t: SettingsTab) -> some View {
        switch t {
        case .general: general
        case .asking: asking
        case .messages: messages
        }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(title: Words.Settings.contextGuard) {
                let watch = SettingsText.watchLabel(showsCodex: model.showsCodex)
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
                    Note(loginError, color: Theme.danger)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            Note(Words.Settings.offNote)
                .padding(.horizontal, 2)
                .padding(.bottom, 14)

            // One card per tool, as on When to Ask: what's installed, then the judge and whose sign-in it uses.
            Card(title: SessionHost.claude.name) {
                Row(label: Words.Settings.hooks) { StatusLabel(SettingsText.installed(hooksInstalled)) }
                    .help(Words.Settings.hooksHelp)
                Rule()
                Row(label: Words.Settings.mod) { StatusLabel(SettingsText.installed(modInstalled)) }
                    .help(Words.Settings.modHelp)
                Rule()
                Row(label: Words.Settings.judge) { StatusLabel(SettingsText.claudeJudge) }
                    .help(Words.Settings.judgeHelp)
            }
            Note(SettingsText.signInNote(.claude))
                .padding(.horizontal, 2)
            if model.showsCodex {
                Card(title: SessionHost.codex.name) {
                    Row(label: Words.Settings.link) { StatusLabel(SettingsText.link(model.codexLink, installed: codexLinkInstalled)) }
                        .help(Words.Settings.linkHelp)
                    if case .onlyWatching(let why) = model.codexLink {
                        Rule()
                        Note(SettingsText.onlyWatchingNote(why), color: Theme.warning)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    Rule()
                    Row(label: Words.Settings.judge) { StatusLabel(SettingsText.codexJudge(model.codexJudge, link: model.codexLink)) }
                        .help(Words.Settings.judgeHelp)
                }
                .padding(.top, 14)
                Note(SettingsText.signInNote(.codex))
                    .padding(.horizontal, 2)
            }
        }
    }

    // MARK: When to Ask

    @ViewBuilder
    private var asking: some View {
        if model.showsCodex {
            // Each tool's thresholds, then the countdown both share.
            VStack(alignment: .leading, spacing: 10) {
                Card(title: SessionHost.claude.name) {
                    askField
                    Rule()
                    laterField
                } accessory: {
                    SaveStatusLabel(status: thresholdProblem.map(SaveStatus.notSaved) ?? thresholdsSaved)
                }
                problemOr(thresholdProblem, SettingsText.claudeThresholdsNote(askK: askK, laterK: laterK))
                    .padding(.bottom, 14)
                Card(title: SessionHost.codex.name) {
                    NumberField(SettingsText.codexAskField, value: $codexAsk, invalid: SettingsText.codexAskInvalid(codexAsk))
                    Rule()
                    NumberField(SettingsText.codexLaterField, value: $codexLater,
                                invalid: SettingsText.codexLaterInvalid(ask: codexAsk, later: codexLater))
                } accessory: {
                    SaveStatusLabel(status: codexProblem.map(SaveStatus.notSaved) ?? codexSaved)
                }
                problemOr(codexProblem, SettingsText.codexThresholdsNote(ask: codexAsk, later: codexLater))
                    .padding(.bottom, 14)
                Card(title: Words.Settings.ifYouDontAnswer) {
                    autoYesField
                } accessory: {
                    SaveStatusLabel(status: countdownSaved)
                }
                Note(SettingsText.countdownNote(autoYes))
                    .padding(.horizontal, 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Card(title: Words.Settings.whenToAskCard) {
                    askField
                    Rule()
                    autoYesField
                    Rule()
                    laterField
                } accessory: {
                    // Thresholds that don't make sense aren't saved; the note under the card says why.
                    SaveStatusLabel(status: thresholdProblem.map(SaveStatus.notSaved) ?? .latest(thresholdsSaved, countdownSaved))
                }
                problemOr(thresholdProblem, SettingsText.whenToAskNote(askK: askK, laterK: laterK, autoYes: autoYes))
            }
        }
    }

    private var askField: some View {
        NumberField(SettingsText.askField, value: $askK, invalid: SettingsText.askInvalid(askK: askK, laterK: laterK))
    }

    private var laterField: some View {
        NumberField(SettingsText.laterField, value: $laterK, invalid: SettingsText.laterInvalid(askK: askK, laterK: laterK))
    }

    private var autoYesField: some View {
        NumberField(SettingsText.countdownField(showsCodex: model.showsCodex), value: $autoYes)
    }

    /// The note under a card: why it isn't saved, or what it does.
    private func problemOr(_ problem: String?, _ text: String) -> some View {
        Note(problem ?? text, color: problem == nil ? Theme.muted : Theme.danger)
            .padding(.horizontal, 2)
    }

    private var thresholdProblem: String? { SettingsText.thresholdProblem(askK: askK, laterK: laterK) }

    private var codexProblem: String? { SettingsText.codexProblem(ask: codexAsk, later: codexLater) }

    private func saveCodex() {
        guard codexProblem == nil else { return }
        codexSaved = update {
            $0.codexAskPercent = codexAsk
            $0.codexLaterPercent = codexLater
        }
    }

    private func saveThresholds() {
        guard thresholdProblem == nil else { return }
        thresholdsSaved = update {
            $0.askAt = askK * 1_000
            $0.laterAt = laterK * 1_000
        }
    }

    // MARK: Messages

    private var messages: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageCard(Words.Settings.beforeCompacting, text: $message, original: Config.defaultMessage,
                        about: Words.Settings.beforeCompactingAbout, what: Words.Settings.saveMessage, status: messageSaved)
            messageCard(Words.Settings.afterCompacting, text: $continueMessage, original: Config.defaultContinueMessage,
                        about: Words.Settings.afterCompactingAbout, what: Words.Settings.continueMessage, status: continueSaved)
                .padding(.top, 10)
            Note(SettingsText.messagesNote(showsCodex: model.showsCodex,
                                           codexJudgeName: SettingsText.codexJudgeName(model.codexJudge, link: model.codexLink)))
                .padding(.horizontal, 2)
        }
    }

    /// A message box, what it's for (or why it isn't saved) and Restore Default.
    private func messageCard(_ title: String, text: Binding<String>, original: String, about: String,
                             what: String, status: SaveStatus) -> some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                BrandTextEditor(label: title, text: text, height: Self.editorHeight)
                HStack(alignment: .center) {
                    let note = SettingsText.messageNote(text.wrappedValue, status: status, about: about)
                    Note(note.text, color: Theme.color(note.tone))
                    Button(Words.Settings.restoreDefault) { text.wrappedValue = original }
                        .buttonStyle(BrandButtonStyle(kind: .ghost, height: 28))
                        .disabled(text.wrappedValue == original)
                        .help(SettingsText.restoreHelp(what))
                }
            }
            .padding(16)
        } accessory: {
            SaveStatusLabel(status: status)
        }
    }

    // MARK: Saving

    /// Changes the settings and saves them at once, and says whether that worked.
    private func update(_ change: (inout Config) -> Void) -> SaveStatus {
        var c = model.config
        change(&c)
        return model.save(c).map(SaveStatus.notSaved) ?? .saved(Date())
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

enum CodexLinkInstall {
    /// install.sh writes this LaunchAgent, which keeps `context-guard codex` running.
    static let label = "com.spaceterran.ContextGuard.codex"

    /// `CONTEXT_GUARD_LAUNCH_AGENTS` moves the folder it's looked for in, so `live-test/ui-demo.sh`
    /// shows the same thing whatever this Mac has installed.
    static var plist: URL {
        let moved = ProcessInfo.processInfo.environment["CONTEXT_GUARD_LAUNCH_AGENTS"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = moved.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }
}
