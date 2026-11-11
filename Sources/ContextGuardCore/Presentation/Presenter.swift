import Foundation

/// Where popups and notices appear: the Mac app's floating panels, or the Windows app through
/// `context-guard ui`. A question popup's key is `question:<session id>`, a notice's `notice:…`.
public protocol PanelHost: AnyObject {
    /// The keys of what's open now, top to bottom.
    var openKeys: [String] { get }
    /// Opens the question popup for this session. False when there's no room for another.
    func openQuestion(_ id: String) -> Bool
    /// Shows a notice that closes by itself after `notice.seconds`, or with its ✕.
    func showNotice(_ notice: NoticeContent, key: String)
    func close(_ key: String)
    /// Calls `Presenter.sync` again after this long: a popup has shown its progress long enough.
    func recheck(after seconds: TimeInterval)
}

extension PanelHost {
    public func isOpen(_ key: String) -> Bool { openKeys.contains(key) }

    /// Closes everything whose key matches.
    public func close(where matches: (String) -> Bool) {
        for key in openKeys where matches(key) { close(key) }
    }
}

/// A short message that closes by itself: an automatic send, a compaction, turning off.
public struct NoticeContent: Equatable, Sendable {
    public var symbol: Symbol
    public var tone: Tone
    public var title: String
    public var detail: String
    public var caption: String
    /// A reason wraps; a name and folder stays on one line, cut in the middle.
    public var captionWraps: Bool
    /// How long it stays up.
    public var seconds: TimeInterval

    public init(symbol: Symbol, tone: Tone, title: String, detail: String, caption: String = "",
                captionWraps: Bool = false, seconds: TimeInterval = 8) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.detail = detail
        self.caption = caption
        self.captionWraps = captionWraps
        self.seconds = seconds
    }
}

/// Everything the menu, popups and Settings show, read from Context Guard's folder, and which
/// popups and notices are open. The hook owns the session files; this only reads them and writes
/// answers and settings. Each app keeps one and draws from it, on one thread (the Mac app's main
/// thread).
public final class Presenter {
    public let paths: Paths
    public private(set) var config: Config
    /// Every session Context Guard has a file for, largest context first.
    public private(set) var sessions: [SessionInfo] = []
    /// What you answered in a popup, by session id.
    public private(set) var replies: [String: Reply] = [:]
    /// The Codex link is installed or has run (its background task or `codex-link.json` is there):
    /// the menu and Settings show each tool's own lines. Otherwise they read as they did before
    /// Codex. The installer's `--no-codex` and uninstall remove both, so the views go back at once.
    public private(set) var showsCodex = false
    /// How `context-guard codex` stands, and the model it judges Codex sessions with.
    public private(set) var codexLink = CodexLinkStatus.State.notRunning
    public private(set) var codexJudge: String?

    private let registry: any RegistryReading
    private let probe: any ProcessProbing
    private let codexLinkInstalled: () -> Bool
    private let startedAt: Date
    private var pruneAt = Date.distantPast
    /// Sends and compactions already announced (and everything from before it started).
    private var announced: Set<String> = []
    /// Popups closed with ✕, by session id → the cycle they were closed in.
    private var hidden: [String: Int] = [:]
    /// When each open popup reached what it shows now, for closing it after a moment.
    private var shownSince: [String: (QuestionProgress, Date)] = [:]

    /// Session files of sessions gone this long are removed, an hour apart.
    public static let pruneAge: TimeInterval = 7 * 86_400
    public static let pruneEvery: TimeInterval = 3_600

    /// - Parameter codexLinkInstalled: whether the Codex link's background task is installed
    ///   (a LaunchAgent on the Mac).
    public init(paths: Paths, registry: any RegistryReading, probe: any ProcessProbing = SystemProcessProbe(),
                codexLinkInstalled: @escaping () -> Bool, now: Date = Date()) {
        self.paths = paths
        self.registry = registry
        self.probe = probe
        self.codexLinkInstalled = codexLinkInstalled
        self.startedAt = now
        self.config = Config.load(paths)
    }

    public static func questionKey(_ id: String) -> String { "question:\(id)" }

    public func session(_ id: String) -> SessionInfo? { sessions.first { $0.id == id } }

    /// Terminal sessions that are running now, largest context first.
    public var liveSessions: [SessionInfo] { Display.live(sessions) }

    // MARK: Reading

    /// Reads the sessions, and from then on announces only what happens next. Settings from before
    /// there was an `enabledAt` get one now, since a popup's countdown runs from it. Returns why
    /// those couldn't be saved, or nil.
    @discardableResult
    public func start(now: Date = Date()) -> String? {
        try? paths.ensureDirectories()
        sessions = SessionCatalog.load(paths, registry: registry, probe: probe)
        for info in sessions { announced.formUnion(Self.announcementKeys(info.state)) }
        guard config.enabled, config.enabledAt == nil else { return nil }
        var c = config
        c.setEnabled(true, now: now)
        return save(c)
    }

    /// Reads the settings, sessions and Codex link again, and removes old session files once an hour.
    public func reload(now: Date = Date()) {
        config = Config.load(paths)
        sessions = SessionCatalog.load(paths, registry: registry, probe: probe)
        let link = CodexLinkStatus.load(paths)
        codexLink = CodexLinkStatus.state(link, now: now)
        codexJudge = link?.judgeModel
        showsCodex = codexLinkInstalled() || link != nil
        if now > pruneAt {
            SessionCatalog.prune(paths, sessions: sessions, olderThan: Self.pruneAge, now: now, probe: probe)
            pruneAt = now.addingTimeInterval(Self.pruneEvery)
        }
    }

    // MARK: Popups and notices

    /// What a popup shows for a session now.
    public func progress(_ info: SessionInfo) -> QuestionProgress {
        QuestionProgress.of(info, config: config, reply: replies[info.id])
    }

    /// Opens a popup for each session that just started asking, closes the ones whose question is
    /// gone or whose progress has shown long enough, and raises notices for what just happened.
    public func sync(_ host: PanelHost, now: Date = Date()) {
        let live = liveSessions
        let prefix = Self.questionKey("")
        for key in host.openKeys where key.hasPrefix(prefix) {
            let id = String(key.dropFirst(prefix.count))
            let shows = live.first { $0.id == id }.map(progress) ?? .closed
            if shownSince[id]?.0 != shows { shownSince[id] = (shows, now) }
            guard let linger = shows.linger else { continue }
            let shown = now.timeIntervalSince(shownSince[id]?.1 ?? now)
            if shown >= linger {
                host.close(key)
                shownSince[id] = nil
            } else {
                host.recheck(after: linger - shown + 0.05)
            }
        }

        for info in live where config.enabled && !info.muted && info.effectivePhase == .asking && hidden[info.id] != info.state.cycle {
            guard !host.isOpen(Self.questionKey(info.id)) else { continue }
            if let r = replies[info.id], r.cycle == info.state.cycle { continue }
            replies[info.id] = nil
            if host.openQuestion(info.id) { shownSince[info.id] = (.question, now) }
        }

        announce(live, host)
    }

    private static func announcementKeys(_ s: SessionState) -> [String] {
        var keys: [String] = []
        if let nonce = s.sentNonce { keys.append("sent:\(nonce)") }
        if let c = s.lastCompaction { keys.append(compactionKey(s, c)) }
        if let f = s.followUp { keys.append(followUpKey(f)) }
        return keys
    }

    private static func followUpKey(_ f: FollowUp) -> String { "follow-up:\(f.nonce):\(f.stage.rawValue)" }

    private static func compactionKey(_ s: SessionState, _ c: Compaction) -> String {
        "compacted:\(s.sessionId):\(c.at.timeIntervalSince1970)"
    }

    private func show(_ notice: NoticeContent, key: String, _ host: PanelHost) {
        guard !host.isOpen(key) else { return }
        host.showNotice(notice, key: key)
    }

    /// Short notices for things that happen without a question: an automatic or menu send, an
    /// auto-compaction that came before the save message did, and the steps of compacting.
    private func announce(_ live: [SessionInfo], _ host: PanelHost) {
        for info in live {
            let s = info.state
            if let f = s.followUp, !announced.contains(Self.followUpKey(f)) {
                announced.insert(Self.followUpKey(f))
                // A new stage closes what the earlier ones said: "Needs you" once it's answered,
                // "Compacting" once it's done.
                host.close { $0.hasPrefix("notice:follow-up:\(f.nonce):") }
                if let n = FollowUpText.notice(f, continueMessage: config.continueMessage) {
                    show(NoticeContent(symbol: n.symbol, tone: n.tone, title: n.title, detail: info.title,
                                       caption: n.reason ?? info.toolSubtitle, captionWraps: n.reason != nil, seconds: n.seconds),
                         key: "notice:\(Self.followUpKey(f))", host)
                }
            }
            if let nonce = s.sentNonce, !announced.contains("sent:\(nonce)") {
                announced.insert("sent:\(nonce)")
                // A popup that's still open already shows this send.
                if !host.isOpen(Self.questionKey(info.id)) {
                    let title = s.sendReason == .later
                        ? "Reached \(info.size(s.sentTokens ?? s.tokens)): saving, then compacting"
                        : Words.Notice.saving
                    show(NoticeContent(symbol: .saving, tone: .accent, title: title, detail: info.title, caption: info.toolSubtitle),
                         key: "notice:\(nonce)", host)
                }
            }
            if let c = s.lastCompaction, c.at > startedAt, c.interruptedPhase != nil, c.trigger != nil {
                let key = Self.compactionKey(s, c)
                guard !announced.contains(key) else { continue }
                announced.insert(key)
                guard c.trigger == "auto" else { continue }
                let size = c.preTokens.map { " at \(info.size($0))" } ?? ""
                show(NoticeContent(symbol: .compacting, tone: .warning, title: "Auto-compacted\(size) before it could save",
                                   detail: info.title, caption: info.toolSubtitle),
                     key: "notice:\(key)", host)
            }
        }
    }

    // MARK: Actions

    /// Writes your answer for the session's current cycle; its popup then shows the progress.
    /// False when there's no such session; throws when the answer couldn't be saved.
    @discardableResult
    public func answer(_ id: String, _ action: Answer.Action, from source: Answer.Source, now: Date = Date()) throws -> Bool {
        guard let info = session(id) else { return false }
        try Answer(cycle: info.state.cycle, action: action, source: source, at: now).save(for: id, paths)
        replies[id] = Reply(cycle: info.state.cycle, action: action, at: now)
        return true
    }

    /// Saves the settings and reads them back. nil once the file holds them; otherwise why not.
    @discardableResult
    public func save(_ c: Config) -> String? { c.saveConfirmed(paths) }

    @discardableResult
    public func setEnabled(_ on: Bool, now: Date = Date()) -> String? {
        var c = config
        c.setEnabled(on, now: now)
        return save(c)
    }

    /// "Watch This Session": off stops questions, automatic sends and compacting for that tab
    /// until it closes or this turns it back on. False when there's no such session.
    @discardableResult
    public func setWatched(_ id: String, _ on: Bool) throws -> Bool {
        guard let info = session(id) else { return false }
        try Mute.set(!on, for: info.state, paths)
        return true
    }

    /// After "Turn Off" in a popup: a notice says how to turn it back on.
    public func announceOff(_ host: PanelHost) {
        show(NoticeContent(symbol: .off, tone: .muted, title: Words.Notice.off, detail: Words.Notice.turnBackOn),
             key: "notice:off:\(UUID().uuidString)", host)
    }

    /// ✕ on a popup: hidden for this cycle. The menu can show it again. Then `sync`.
    public func hideQuestion(_ id: String, _ host: PanelHost) {
        guard let info = session(id) else { return }
        hidden[id] = info.state.cycle
        host.close(Self.questionKey(id))
    }

    /// "Show the Question" in the menu: the popup opens again on the next `sync`, with its buttons.
    public func showQuestion(_ id: String) {
        hidden[id] = nil
        replies[id] = nil
    }
}
