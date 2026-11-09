import AppKit
import ContextGuardCore
import Observation
import SwiftUI

/// Everything the menu, popups and Settings show. The hook owns the session files; the app only
/// reads them and writes answers and settings.
@MainActor @Observable
final class AppModel {
    let paths: Paths
    private(set) var config: Config
    /// Every session Context Guard has a file for, largest context first.
    private(set) var sessions: [SessionInfo] = []
    /// What you answered in a popup, by session id. The popup shows progress in place of its buttons.
    private(set) var replies: [String: Reply] = [:]

    struct Reply: Equatable {
        var cycle: Int
        var action: Answer.Action
        var at: Date
    }

    @ObservationIgnored private let registry: FileRegistry
    @ObservationIgnored private var watchers: [FolderWatcher] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var pruneAt = Date.distantPast
    @ObservationIgnored private let startedAt = Date()
    /// Sends and compactions already announced (and everything from before launch).
    @ObservationIgnored private var announced: Set<String> = []
    /// Popups closed with ✕, by session id → the cycle they were closed in.
    @ObservationIgnored private var hidden: [String: Int] = [:]
    /// When each open popup reached what it shows now, for closing it after a moment.
    @ObservationIgnored private var shownSince: [String: (QuestionProgress, Date)] = [:]
    @ObservationIgnored let panels = PanelController()
    @ObservationIgnored private let settingsWindow = SettingsWindow()

    init(paths: Paths) {
        self.paths = paths
        self.config = Config.load(paths)
        self.registry = FileRegistry(dir: paths.registryDir)
    }

    // MARK: Watching

    func start() {
        try? paths.ensureDirectories()
        let changed: @MainActor () -> Void = { [weak self] in self?.queueRefresh() }
        watchers = [paths.root, paths.sessionsDir, paths.answersDir, paths.registryDir, paths.mutedDir].compactMap { FolderWatcher($0, onChange: changed) }
        // Registry status (busy/idle) and process exits don't always touch a watched folder.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels.layout() }
        }
        // Only announce what happens from now on.
        sessions = SessionCatalog.load(paths, registry: registry)
        for info in sessions { announced.formUnion(announcementKeys(info.state)) }
        // A popup's countdown runs from when Context Guard was turned on; settings from before
        // there was one start it now.
        if config.enabled, config.enabledAt == nil {
            var c = config
            c.setEnabled(true, now: Date())
            save(c)
        }
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
        let newConfig = Config.load(paths)
        if newConfig != config { config = newConfig }
        let loaded = SessionCatalog.load(paths, registry: registry)
        if loaded != sessions { sessions = loaded }
        if Date() > pruneAt {
            SessionCatalog.prune(paths, sessions: loaded, olderThan: 7 * 86_400)
            pruneAt = Date().addingTimeInterval(3_600)
        }
        syncPanels()
    }

    // MARK: What the menu shows

    /// Terminal sessions that are running now, largest context first.
    var liveSessions: [SessionInfo] { sessions.filter { $0.isLive && $0.state.guarded } }

    var hasQuestion: Bool { config.enabled && liveSessions.contains { !$0.muted && $0.effectivePhase == .asking } }

    func session(_ id: String) -> SessionInfo? { sessions.first { $0.id == id } }

    func tokensText(_ info: SessionInfo) -> String {
        info.state.awaitingCompactionRecord ? "compacted" : Format.tokens(info.state.tokens)
    }

    func statusText(_ info: SessionInfo) -> String {
        let ask = Format.tokens(config.askAt), later = Format.tokens(config.laterAt)
        if info.muted, config.enabled, !isSending(info) { return "Not watching this session" }
        switch info.effectivePhase {
        case .watching:
            return config.enabled ? "Asks at \(ask)" : "Not watching: Context Guard is off"
        case .asking:
            guard config.enabled else { return "Asks again when Context Guard is on" }
            guard config.autoYesSeconds > 0 else { return "Waiting for your answer" }
            return "Waiting for your answer · compacts after \(Format.seconds(config.autoYesSeconds))"
        case .later:
            return config.enabled ? "Compacts by itself at \(later)" : "Waiting for \(later): paused while off"
        case .queued:
            if !info.isIdle { return "Asking it to save at its next step" }
            return info.waiterAlive ? "Asking it to save…" : "Asks it to save when it next runs"
        case .sent:
            guard info.state.confirmedAt != nil else { return "Asking it to save…" }
            return "Asked it to save at \(Format.tokens(info.state.sentTokens ?? info.state.tokens))"
        case .skipped:
            return "Not asking again until it compacts"
        }
    }

    /// The save message is on its way and not yet confirmed: sending again would repeat it.
    func isSending(_ info: SessionInfo) -> Bool {
        info.effectivePhase == .queued || (info.state.phase == .sent && info.state.confirmedAt == nil)
    }

    /// Compact Now is off while one is already under way, since it would ask the session to save
    /// twice.
    func canCompactNow(_ info: SessionInfo) -> Bool {
        !isSending(info) && !(info.state.followUp?.isActive ?? false)
    }

    /// When an unanswered question sends by itself (the hook's own rule), or nil when it won't.
    func autoYesDeadline(_ info: SessionInfo) -> Date? {
        Engine.autoYesDeadline(info.state, config: config, watched: !info.muted, now: Date())
    }

    /// Where the session stands after its save message, for its menu.
    func followUpText(_ info: SessionInfo) -> String? {
        info.state.followUp.flatMap { FollowUpText.line($0, continueMessage: config.continueMessage, now: Date()) }
    }

    // MARK: Actions

    func answer(_ id: String, _ action: Answer.Action, from source: Answer.Source) {
        guard let info = session(id), save(Answer(cycle: info.state.cycle, action: action, source: source, at: Date()), for: id) else { return }
        replies[id] = Reply(cycle: info.state.cycle, action: action, at: Date())
        refresh()
    }

    private func save(_ answer: Answer, for id: String) -> Bool {
        do {
            try answer.save(for: id, paths)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }


    func setEnabled(_ on: Bool) {
        var c = config
        c.setEnabled(on, now: Date())
        save(c)
    }

    /// "Watch This Session": off stops questions, automatic sends and compacting for that tab
    /// until it closes or this turns it back on.
    func setWatched(_ id: String, _ on: Bool) {
        guard let info = session(id) else { return }
        do { try Mute.set(!on, for: info.state, paths) } catch { NSSound.beep() }
        refresh()
    }

    /// "Turn Off" in a popup: everything pauses, and a notice says how to turn it back on.
    func turnOffFromPopup() {
        setEnabled(false)
        panels.showNotice(key: "notice:off:\(UUID().uuidString)", NoticeView(
            symbol: "pause.circle.fill", tone: .muted, title: "Context Guard is off",
            detail: "Turn it back on from the gauge in the menu bar."))
    }

    /// Saves the settings and reads them back. nil once the file holds them; otherwise why not.
    @discardableResult
    func save(_ c: Config) -> String? {
        let problem = c.saveConfirmed(paths)
        if problem != nil { NSSound.beep() }
        refresh()
        return problem
    }

    /// ✕ on a popup: hide it for this cycle. The menu can show it again.
    func hideQuestion(_ id: String) {
        guard let info = session(id) else { return }
        hidden[id] = info.state.cycle
        panels.close("question:\(id)")
        syncPanels()
    }

    func showQuestion(_ id: String) {
        hidden[id] = nil
        replies[id] = nil
        syncPanels()
    }

    func openSettings() { settingsWindow.show(model: self) }

    // MARK: Popups and notices

    private func syncPanels() {
        let live = liveSessions
        let now = Date()

        // Close popups whose question is gone or whose progress has been shown long enough.
        for key in panels.keys where key.hasPrefix("question:") {
            let id = String(key.dropFirst("question:".count))
            let progress = live.first { $0.id == id }.map { questionProgress($0) } ?? .closed
            if shownSince[id]?.0 != progress { shownSince[id] = (progress, now) }
            let since = shownSince[id]?.1 ?? now
            if let linger = progress.linger, now.timeIntervalSince(since) >= linger {
                panels.close(key)
                shownSince[id] = nil
            } else if let linger = progress.linger {
                DispatchQueue.main.asyncAfter(deadline: .now() + linger - now.timeIntervalSince(since) + 0.05) { [weak self] in
                    MainActor.assumeIsolated { self?.syncPanels() }
                }
            }
        }

        // Open a popup for each session that just started asking.
        for info in live where config.enabled && !info.muted && info.effectivePhase == .asking && hidden[info.id] != info.state.cycle {
            let key = "question:\(info.id)"
            guard !panels.isOpen(key) else { continue }
            if let r = replies[info.id], r.cycle == info.state.cycle { continue }
            replies[info.id] = nil
            shownSince[info.id] = (.question, now)
            panels.showQuestion(key: key, QuestionView(model: self, sessionID: info.id))
            NSSound(named: "Glass")?.play()
        }

        announce(live)
        panels.fitSizes()
    }

    /// What a popup shows for a session, given what you answered in it.
    func questionProgress(_ info: SessionInfo) -> QuestionProgress {
        // A question left to its countdown went out as a Yes.
        let timedOut = info.state.askTimedOut == true && [.queued, .sent].contains(info.effectivePhase)
        let answered = replies[info.id].flatMap { $0.cycle == info.state.cycle ? $0.action : nil } ?? (timedOut ? .yes : nil)
        guard let action = answered else {
            return config.enabled && !info.muted && info.effectivePhase == .asking ? .question : .closed
        }
        switch action {
        case .skip: return .closed
        case .later: return .scheduled(at: config.laterAt)
        case .yes:
            switch info.effectivePhase {
            case .queued:
                if !info.isIdle { return .nextStep }
                return info.waiterAlive ? .waking : .nextRun
            case .sent:
                return info.state.confirmedAt != nil ? .sent : .waking
            default:
                return .closed
            }
        }
    }

    private func announcementKeys(_ s: SessionState) -> [String] {
        var keys: [String] = []
        if let nonce = s.sentNonce { keys.append("sent:\(nonce)") }
        if let c = s.lastCompaction { keys.append("compacted:\(s.sessionId):\(c.at.timeIntervalSince1970)") }
        if let f = s.followUp { keys.append(followUpKey(f)) }
        return keys
    }

    private func followUpKey(_ f: FollowUp) -> String { "follow-up:\(f.nonce):\(f.stage.rawValue)" }

    /// Short notices for things that happen without a question: an automatic or menu send, an
    /// auto-compaction that came before the save message did, and the steps of compacting.
    private func announce(_ live: [SessionInfo]) {
        for info in live {
            let s = info.state
            if let f = s.followUp, !announced.contains(followUpKey(f)) {
                announced.insert(followUpKey(f))
                // A new stage closes what the earlier ones said: "Needs you" once it's answered,
                // "Compacting" once it's done.
                panels.close { $0.hasPrefix("notice:follow-up:\(f.nonce):") }
                if let n = FollowUpText.notice(f, continueMessage: config.continueMessage) {
                    panels.showNotice(key: "notice:\(followUpKey(f))",
                                      NoticeView(symbol: n.symbol, tone: n.tone, title: n.title, detail: info.title,
                                                 caption: n.reason ?? info.subtitle, captionWraps: n.reason != nil),
                                      seconds: n.seconds)
                }
            }
            if let nonce = s.sentNonce, !announced.contains("sent:\(nonce)") {
                announced.insert("sent:\(nonce)")
                // A popup that's still open already shows this send.
                if !panels.isOpen("question:\(info.id)") {
                    let title = s.sendReason == .later
                        ? "Reached \(Format.tokens(s.sentTokens ?? s.tokens)): saving, then compacting"
                        : "Saving, then compacting"
                    panels.showNotice(key: "notice:\(nonce)", NoticeView(symbol: "tray.and.arrow.down.fill", tone: .accent, title: title, detail: info.title, caption: info.subtitle))
                }
            }
            if let c = s.lastCompaction, c.at > startedAt, c.interruptedPhase != nil, c.trigger != nil {
                let key = "compacted:\(s.sessionId):\(c.at.timeIntervalSince1970)"
                guard !announced.contains(key) else { continue }
                announced.insert(key)
                guard c.trigger == "auto" else { continue }
                let size = c.preTokens.map { " at \(Format.tokens($0))" } ?? ""
                panels.showNotice(key: "notice:\(key)", NoticeView(
                    symbol: "arrow.down.right.and.arrow.up.left.circle.fill", tone: .warning,
                    title: "Auto-compacted\(size) before it could save", detail: info.title, caption: info.subtitle))
            }
        }
    }
}

/// What a question popup shows.
enum QuestionProgress: Equatable {
    case question
    /// Busy: the hook adds it after the session's next step.
    case nextStep
    /// Idle with a waiter: going out now.
    case waking
    /// Idle and nothing waiting: it goes out when the session next runs.
    case nextRun
    case sent
    case scheduled(at: Int)
    case closed

    /// How long the popup stays once it shows this; nil stays until something changes.
    var linger: TimeInterval? {
        switch self {
        case .question: return nil
        case .nextStep, .waking: return 45
        case .nextRun: return 6
        case .sent: return 2.5
        case .scheduled: return 2.5
        case .closed: return 0
        }
    }
}

/// Calls back on the main thread when a folder's entries change (files renamed into place).
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
