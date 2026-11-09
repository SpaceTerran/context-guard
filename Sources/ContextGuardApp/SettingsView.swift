import AppKit
import ContextGuardCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: true)
            w.title = "Context Guard Settings"
            // The brand's background runs under the title bar.
            w.titlebarAppearsTransparent = true
            w.backgroundColor = Theme.windowBackground
            w.isReleasedWhenClosed = false
            window = w
        }
        guard let window else { return }
        if !window.isVisible {
            // Fresh each time it opens, so it shows settings changed elsewhere (the CLI, the menu).
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = .preferredContentSize
            window.contentViewController = host
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
        case .general: return "General"
        case .asking: return "When to Ask"
        case .messages: return "Messages"
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var tab = SettingsTab.general
    @State private var askK: Int
    @State private var laterK: Int
    @State private var autoYes: Int
    @State private var message: String
    @State private var continueMessage: String
    /// Whether each card's changes are on disk, for its header.
    @State private var thresholdsSaved = SaveStatus.unchanged
    @State private var messageSaved = SaveStatus.unchanged
    @State private var continueSaved = SaveStatus.unchanged
    @State private var login = LoginItem.state
    @State private var loginError: String?
    private let hooksInstalled: Bool
    private let modInstalled: Bool

    static let width: CGFloat = 600
    /// Both message boxes: five lines before they scroll.
    static let editorHeight: CGFloat = 112

    init(model: AppModel) {
        self.model = model
        let c = model.config
        _askK = State(initialValue: c.askAt / 1_000)
        _laterK = State(initialValue: c.laterAt / 1_000)
        _autoYes = State(initialValue: c.autoYesSeconds)
        _message = State(initialValue: c.message)
        _continueMessage = State(initialValue: c.continueMessage)
        hooksInstalled = HookInstall.isInstalled(model.paths)
        modInstalled = ModInstall.isInstalled(model.paths)
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
        .onChange(of: autoYes) { thresholdsSaved = update { $0.autoYesSeconds = autoYes } }
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
            Card(title: "Context Guard") {
                Row(label: "Watch Claude Code sessions") {
                    Toggle("Watch Claude Code sessions", isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
                        .labelsHidden()
                }
                Rule()
                Row(label: "Open at login") {
                    // A closure, not `set: setLogin`: Swift 6.1 to 6.3 crash building the method reference here.
                    Toggle("Open at login", isOn: Binding(get: { login == .enabled }, set: { setLogin($0) }))
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
            Note("When off, nothing pops up and nothing compacts by itself. Compact Now in a session's menu still works.")
                .padding(.horizontal, 2)
                .padding(.bottom, 14)

            Card(title: "Setup") {
                Row(label: "Claude Code hooks") { installed(hooksInstalled) }
                Rule()
                Row(label: "Claude Code mod") { installed(modInstalled) }
                    .help("Compacts sessions once they have saved")
                Rule()
                Row(label: "Haiku") {
                    StatusLabel(text: "Each session's sign-in", symbol: "checkmark.circle.fill", color: Theme.success)
                }
            }
            Note("Nothing to sign in to. The mod asks Haiku through the Claude Code session it runs in, with that session's account.")
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func installed(_ ok: Bool) -> some View {
        if ok {
            StatusLabel(text: "Installed", symbol: "checkmark.circle.fill", color: Theme.success)
        } else {
            StatusLabel(text: "Not installed: run install.sh", symbol: "exclamationmark.triangle.fill", color: Theme.warning)
        }
    }

    // MARK: When to Ask

    private var asking: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(title: "When to ask") {
                NumberField(label: "Ask at", value: $askK, unit: "k tokens", step: 50, range: 50...10_000,
                            invalid: askK < 1 || laterK <= askK)
                Rule()
                NumberField(label: "If you don't answer, compact after", value: $autoYes, unit: "seconds", step: 15, range: 0...3_600)
                Rule()
                NumberField(label: "If you choose Wait, compact at", value: $laterK, unit: "k tokens", step: 50, range: 50...10_000,
                            invalid: laterK < 1 || laterK <= askK)
            } accessory: {
                // Thresholds that don't make sense aren't saved; the note under the card says why.
                SaveStatusLabel(status: thresholdProblem.map(SaveStatus.notSaved) ?? thresholdsSaved)
            }
            if let thresholdProblem {
                Note(thresholdProblem, color: Theme.danger)
                    .padding(.horizontal, 2)
            } else {
                Note(whenToAskText)
                    .padding(.horizontal, 2)
            }
        }
    }

    /// What's wrong with the thresholds as typed, or nil when they can be saved.
    private var thresholdProblem: String? {
        if askK < 1 { return "“Ask at” needs a number, like 300." }
        if laterK < 1 { return "“If you choose Wait, compact at” needs a number, like 500." }
        if laterK <= askK { return "“If you choose Wait, compact at” has to be more than “Ask at”." }
        return nil
    }

    private var whenToAskText: String {
        let ask = "At \(askK)k tokens a popup asks whether to compact the session."
        let answer = autoYes > 0
            ? " If you don't answer within \(Format.seconds(autoYes)), it compacts."
            : " It waits for your answer (0 seconds: it never compacts on its own)."
        return ask + answer + " If you choose Wait, it compacts at \(laterK)k."
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
            messageCard("Before compacting, send", text: $message, original: Config.defaultMessage,
                        about: "Asks the session to save its work first.", what: "save message", status: messageSaved)
            messageCard("After compacting, send", text: $continueMessage, original: Config.defaultContinueMessage,
                        about: "Tells the session to carry on.", what: "continue message", status: continueSaved)
                .padding(.top, 10)
            Note("Changes save as you type. Both go to the session as your words. Haiku reads what the session does after the first one; once it has saved and is idle, Context Guard compacts it, then sends the second. If you type in the session first, it leaves the rest to you.")
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
                    if case .notSaved(let problem) = status {
                        Note("Not saved: \(problem)", color: Theme.danger)
                    } else if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Note("Empty, so it sends the default.", color: Theme.warning)
                    } else {
                        Note(about)
                    }
                    Button("Restore Default") { text.wrappedValue = original }
                        .buttonStyle(BrandButtonStyle(kind: .ghost, height: 28))
                        .disabled(text.wrappedValue == original)
                        .help("Put back the default \(what)")
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

/// Where a card's changes stand, shown in its header: Settings saves as you type, and this is how
/// you can tell.
enum SaveStatus: Equatable {
    /// Nothing changed since Settings opened: the card shows what's on disk.
    case unchanged
    /// Changed here, and the file read back holds it.
    case saved(Date)
    /// Changed here but not on disk, and why.
    case notSaved(String)
}

struct SaveStatusLabel: View {
    let status: SaveStatus

    var body: some View {
        switch status {
        case .unchanged:
            StatusLabel(text: "Saved", symbol: "checkmark.circle", color: Theme.muted, size: 12)
        case .saved(let at):
            StatusLabel(text: "Saved \(at.formatted(date: .omitted, time: .shortened))", symbol: "checkmark.circle.fill",
                        color: Theme.success, size: 12)
        case .notSaved:
            StatusLabel(text: "Not saved", symbol: "exclamationmark.triangle.fill", color: Theme.danger, size: 12)
        }
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

enum ModInstall {
    /// install.sh copies the mod here and turns the plugin on in Claude Code's user settings.
    static let plugin = "context-guard@context-guard"

    static func isInstalled(_ paths: Paths) -> Bool {
        let module = paths.claudeDir.appendingPathComponent("hooks/context-guard/mod/hooks/register.ts")
        guard FileManager.default.fileExists(atPath: module.path),
              let data = try? Data(contentsOf: paths.claudeDir.appendingPathComponent("settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let enabled = settings["enabledPlugins"] as? [String: Any] else { return false }
        return enabled[plugin] as? Bool == true
    }
}

enum HookInstall {
    /// install.sh adds this path to every Context Guard hook in Claude Code's user settings.
    static let marker = "hooks/context-guard/context-guard"

    static func isInstalled(_ paths: Paths) -> Bool {
        let settings = paths.claudeDir.appendingPathComponent("settings.json")
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return text.contains(marker)
    }
}
