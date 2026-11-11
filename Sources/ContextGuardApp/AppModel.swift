import AppKit
import ContextGuardCore
import Observation
import SwiftUI

/// The Mac app's side of the shared `Presenter`: it watches Context Guard's folder, keeps copies of
/// what the menu, popups and Settings show (so SwiftUI redraws when they change), and turns clicks
/// into the presenter's actions, with a beep when one couldn't be saved.
@MainActor @Observable
final class AppModel {
    let paths: Paths
    private(set) var config: Config
    /// Every session Context Guard has a file for, largest context first.
    private(set) var sessions: [SessionInfo] = []
    /// What you answered in a popup, by session id. The popup shows progress in place of its buttons.
    private(set) var replies: [String: Reply] = [:]
    /// The Codex link is installed or has run: the menu and Settings show each tool's own lines.
    private(set) var showsCodex = false
    /// How `context-guard codex` stands, and the model it judges Codex sessions with.
    private(set) var codexLink = CodexLinkStatus.State.notRunning
    private(set) var codexJudge: String?

    @ObservationIgnored private let presenter: Presenter
    @ObservationIgnored private var watchers: [FolderWatcher] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored let panels = PanelController()
    @ObservationIgnored private let settingsWindow = SettingsWindow()

    init(paths: Paths) {
        self.paths = paths
        presenter = Presenter(paths: paths, registry: FileRegistry(dir: paths.registryDir),
                              codexLinkInstalled: { CodexLinkInstall.isInstalled })
        config = presenter.config
        panels.question = { [unowned self] id in AnyView(QuestionView(model: self, sessionID: id)) }
        panels.onRecheck = { [weak self] in self?.syncPanels() }
    }

    // MARK: Watching

    func start() {
        try? paths.ensureDirectories()
        let changed: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.queueRefresh() } }
        }
        watchers = [paths.root, paths.sessionsDir, paths.answersDir, paths.registryDir, paths.mutedDir].map { FolderWatcher($0, changed) }
        // Registry status (busy/idle) and process exits don't always touch a watched folder.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels.layout() }
        }
        if presenter.start() != nil { NSSound.beep() }
        mirror()
        refresh()
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // A hook event rewrites several files in a burst; read them once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        presenter.reload()
        mirror()
        syncPanels()
    }

    /// Copies what changed, so SwiftUI only redraws for real changes.
    private func mirror() {
        if presenter.config != config { config = presenter.config }
        if presenter.sessions != sessions { sessions = presenter.sessions }
        if presenter.replies != replies { replies = presenter.replies }
        if presenter.showsCodex != showsCodex { showsCodex = presenter.showsCodex }
        if presenter.codexLink != codexLink { codexLink = presenter.codexLink }
        if presenter.codexJudge != codexJudge { codexJudge = presenter.codexJudge }
    }

    private func syncPanels() {
        presenter.sync(panels)
        mirror()
        panels.fitSizes()
    }

    // MARK: What the menu shows

    /// Terminal sessions that are running now, largest context first.
    var liveSessions: [SessionInfo] { Display.live(sessions) }

    var hasQuestion: Bool { Display.hasQuestion(sessions, config: config) }

    func session(_ id: String) -> SessionInfo? { sessions.first { $0.id == id } }

    /// What a popup shows for a session, given what you answered in it.
    func progress(_ info: SessionInfo) -> QuestionProgress {
        QuestionProgress.of(info, config: config, reply: replies[info.id])
    }

    // MARK: Actions

    func answer(_ id: String, _ action: Answer.Action, from source: Answer.Source) {
        do {
            guard try presenter.answer(id, action, from: source) else { return }
        } catch {
            NSSound.beep()
            return
        }
        refresh()
    }

    func setEnabled(_ on: Bool) {
        settled(presenter.setEnabled(on))
    }

    /// "Watch This Session" on or off.
    func setWatched(_ id: String, _ on: Bool) {
        do {
            guard try presenter.setWatched(id, on) else { return }
        } catch {
            NSSound.beep()
        }
        refresh()
    }

    /// "Turn Off" in a popup: everything pauses, and a notice says how to turn it back on.
    func turnOffFromPopup() {
        setEnabled(false)
        presenter.announceOff(panels)
    }

    /// Saves the settings and reads them back. nil once the file holds them; otherwise why not.
    @discardableResult
    func save(_ c: Config) -> String? {
        settled(presenter.save(c))
    }

    /// After a save: a beep if it failed, then everything read again.
    @discardableResult
    private func settled(_ problem: String?) -> String? {
        if problem != nil { NSSound.beep() }
        refresh()
        return problem
    }

    /// ✕ on a popup: hide it for this cycle. The menu can show it again.
    func hideQuestion(_ id: String) {
        presenter.hideQuestion(id, panels)
        syncPanels()
    }

    func showQuestion(_ id: String) {
        presenter.showQuestion(id)
        syncPanels()
    }

    func openSettings() { settingsWindow.show(model: self) }
}
