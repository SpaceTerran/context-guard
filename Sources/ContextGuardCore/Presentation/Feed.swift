import Foundation

/// `context-guard ui`'s engine: the Windows app's side of the shared `Presenter`, as lines of
/// JSON. The app writes what you clicked (`FeedIntent`, one object per line) and draws the
/// `Board` it gets back. This class only works out what to say; reading lines, watching folders
/// and keeping time are the CLI's. Run it on one thread.
///
/// Each call returns the lines to write, each one a `FeedMessage`:
/// - `board`: the whole board, at start and whenever it differs from the last one written;
/// - `chime`: a question popup just opened (the Mac plays a sound);
/// - `result`: one for each intent, with its `id` if it had one, and a `problem` when it couldn't be
///   done (the app beeps, as the Mac does);
/// - `error`: a line that isn't an intent.
public final class Feed {
    /// Each line says which version of this format it is in.
    public static let version = 1

    public let presenter: Presenter
    private let panels = FeedPanels()
    private let paths: Paths
    private let codexLinkInstalled: () -> Bool
    private let time: (Date) -> String
    /// Settings, while it's open, and what was installed when it opened.
    private var form: SettingsForm?
    private var installed = Installed(hooks: false, mod: false, codexLink: false)
    private var lastBoard: Data?

    struct Installed {
        var hooks: Bool
        var mod: Bool
        var codexLink: Bool
    }

    /// - Parameter time: how a save's time reads in Settings ("3:41 PM").
    public init(paths: Paths, registry: any RegistryReading, probe: any ProcessProbing = SystemProcessProbe(),
                codexLinkInstalled: @escaping () -> Bool, now: Date = Date(),
                time: @escaping (Date) -> String = SaveStatus.shortTime) {
        self.paths = paths
        self.codexLinkInstalled = codexLinkInstalled
        self.time = time
        presenter = Presenter(paths: paths, registry: registry, probe: probe, codexLinkInstalled: codexLinkInstalled, now: now)
    }

    // MARK: What happens

    /// Reads everything and writes the first board. Settings from before there was an `enabledAt`
    /// get one now; a result says if that couldn't be saved.
    public func start(now: Date = Date()) -> [String] {
        panels.now = now
        let problem = presenter.start(now: now)
        reload(now)
        let stamped = problem.map { [Self.line(.result(id: nil, problem: $0))] } ?? []
        return stamped + changes(now)
    }

    /// Something in Context Guard's folder changed, or it's time for the regular look (process
    /// exits and Claude Code's busy or idle don't always touch a watched folder).
    public func refresh(now: Date = Date()) -> [String] {
        panels.now = now
        reload(now)
        return changes(now)
    }

    /// A line from the app.
    public func handle(_ line: String, now: Date = Date()) -> [String] {
        let request: FeedRequest
        do {
            request = try JSONDecoder().decode(FeedRequest.self, from: Data(line.utf8))
        } catch {
            return [Self.line(.error("not an intent: \(line.prefix(200))"))]
        }
        panels.now = now
        let problem = perform(request.intent, now: now)
        return [Self.line(.result(id: request.id, problem: problem))] + changes(now)
    }

    /// The time `nextWake` gave has come: notices that have shown long enough close, popups that
    /// have shown their progress long enough close, and countdowns move on.
    public func tick(now: Date = Date()) -> [String] {
        panels.now = now
        if panels.expire(now) { presenter.sync(panels, now: now) }
        return changes(now)
    }

    /// When something on the board changes by itself next, or nil when nothing will until a file
    /// changes or the app says something.
    public func nextWake(now: Date = Date()) -> Date? {
        var times = panels.pending
        let config = presenter.config
        for key in panels.openKeys {
            guard let id = Self.questionID(key), let info = presenter.session(id), presenter.progress(info) == .question,
                  let deadline = info.autoYesDeadline(config, now: now), deadline > now else { continue }
            // "Compacts in N seconds" counts whole seconds rounded up: it changes as the time left
            // passes each whole second.
            let left = deadline.timeIntervalSince(now)
            times.append(now.addingTimeInterval(left - left.rounded(.up) + 1))
        }
        // A save's progress line in the menu goes once it has shown long enough.
        if presenter.liveSessions.contains(where: { $0.followUpText(config, now: now) != nil }) {
            times.append(now.addingTimeInterval(1))
        }
        return times.min()
    }

    // MARK: Intents

    /// Does what the app asked, as the Mac app does for the same click. Returns why it couldn't.
    private func perform(_ intent: FeedIntent, now: Date) -> String? {
        switch intent {
        case .answer(let id, let action, let source):
            do {
                guard try presenter.answer(id, action, from: source, now: now) else { return nil }
            } catch {
                return error.localizedDescription
            }
            reload(now)
        case .enable(let on):
            let problem = presenter.setEnabled(on, now: now)
            reload(now)
            return problem
        case .turnOff:
            let problem = presenter.setEnabled(false, now: now)
            reload(now)
            presenter.announceOff(panels)
            return problem
        case .watch(let id, let on):
            var problem: String?
            do {
                guard try presenter.setWatched(id, on) else { return nil }
            } catch {
                problem = error.localizedDescription
            }
            reload(now)
            return problem
        case .hide(let id):
            presenter.hideQuestion(id, panels)
            presenter.sync(panels, now: now)
        case .show(let id):
            presenter.showQuestion(id)
            presenter.sync(panels, now: now)
        case .close(let key):
            panels.close(key)
        case .settingsOpen:
            form = SettingsForm(presenter.config)
            installed = Installed(hooks: HookInstall.isInstalled(paths), mod: ModInstall.isInstalled(paths),
                                  codexLink: codexLinkInstalled())
        case .settingsClose:
            form = nil
        case .set(let field, let value):
            return editSettings(now) { form, save in form.set(field, typed: value, now: now, save: save) }
        case .step(let field, let up):
            let showsCodex = presenter.showsCodex
            return editSettings(now) { form, save in form.step(field, up: up, showsCodex: showsCodex, now: now, save: save) }
        case .restore(let field):
            return editSettings(now) { form, save in form.restore(field, now: now, save: save) }
        }
        return nil
    }

    /// Changes Settings' form; whatever it saves is read back at once, as on the Mac.
    private func editSettings(_ now: Date, _ edit: (inout SettingsForm, SettingsForm.Save) -> Void) -> String? {
        guard var f = form else { return "Settings isn't open." }
        var saved = false
        var problem: String?
        edit(&f) { change in
            var c = self.presenter.config
            change(&c)
            saved = true
            problem = self.presenter.save(c)
            return problem
        }
        form = f
        if saved { reload(now) }
        return problem
    }

    private func reload(_ now: Date) {
        presenter.reload(now: now)
        presenter.sync(panels, now: now)
    }

    /// The board if it changed, then a chime if a question opened.
    private func changes(_ now: Date) -> [String] {
        var out: [String] = []
        let board = self.board(now: now)
        if let data = try? Self.encoder.encode(board), data != lastBoard {
            lastBoard = data
            out.append(Self.line(.board(board)))
        }
        if panels.takeOpened() { out.append(Self.line(.chime)) }
        return out
    }

    // MARK: The board

    public func board(now: Date = Date()) -> Board {
        let config = presenter.config
        let state = !config.enabled ? "off" : Display.hasQuestion(presenter.sessions, config: config) ? "asking" : "on"
        return Board(tray: Board.Tray(state: state, label: config.enabled ? Words.appName : Words.appOff),
                     menu: menu(config, now: now),
                     popups: panels.openKeys.compactMap { popup($0, config, now: now) },
                     settings: form.map { settings($0, config) })
    }

    private func menu(_ config: Config, now: Date) -> Board.Menu {
        let sessions = presenter.liveSessions.map { info -> Board.Session in
            let asking = info.effectivePhase == .asking
            let deferral = info.deferral(config)
            let subtitle = info.toolSubtitle
            return Board.Session(
                id: info.id, title: info.title, symbol: info.symbol, tokens: info.tokensText, status: info.statusText(config),
                followUp: info.followUpText(config, now: now), subtitle: subtitle.isEmpty ? nil : subtitle,
                compactNow: Board.MenuItem(label: Words.Menu.compactNow, enabled: info.canCompactNow),
                deferral: asking ? Board.Deferral(label: info.label(for: deferral), help: nil, answer: deferral.action) : nil,
                showQuestion: asking ? Words.Menu.showQuestion : nil,
                watch: Board.Toggle(label: Words.Menu.watchThisSession, on: !info.muted))
        }
        return Board.Menu(on: Board.Toggle(label: Words.Menu.on, on: config.enabled),
                          lines: Display.thresholdLines(config, showsCodex: presenter.showsCodex),
                          heading: Words.Menu.sessions, empty: sessions.isEmpty ? Words.Menu.noSessions : nil,
                          sessions: sessions, settings: Words.Menu.settings, quit: Words.Menu.quit)
    }

    private func popup(_ key: String, _ config: Config, now: Date) -> Board.Popup? {
        if let notice = panels.notice(key) {
            return Board.Popup(key: key, question: nil, notice: Board.Notice(
                symbol: notice.symbol, tone: notice.tone, title: notice.title, detail: notice.detail,
                caption: notice.caption, captionWraps: notice.captionWraps, close: Words.Popup.close))
        }
        guard let id = Self.questionID(key), let info = presenter.session(id) else { return nil }
        let progress = presenter.progress(info)
        var question = Board.Question(session: id, heading: info.questionHeading, title: info.title,
                                      subtitle: info.toolSubtitle, ask: nil, progress: nil)
        if progress == .question {
            let deadline = info.autoYesDeadline(config, now: now)
            let deferral = info.deferral(config)
            question.ask = Board.Ask(
                text: info.questionText, help: config.message,
                countdown: deadline.map { info.countdownText(deadline: $0, now: now) },
                hide: deadline == nil ? Board.Action(label: Words.Popup.close, help: Words.Popup.hideHelp) : nil,
                turnOff: Board.Action(label: Words.Popup.turnOff, help: Words.Popup.turnOffHelp),
                deferral: Board.Deferral(label: info.label(for: deferral), help: info.help(for: deferral), answer: deferral.action),
                compact: Board.Action(label: Words.Popup.compact, help: Words.Popup.compactHelp(config.message)))
        } else {
            let text = progress.text(info)
            switch progress.mark {
            case .working: question.progress = Board.Progress(mark: "working", symbol: nil, tone: nil, text: text)
            case .icon(let symbol, let tone): question.progress = Board.Progress(mark: "icon", symbol: symbol, tone: tone, text: text)
            case .none: question.progress = Board.Progress(mark: "none", symbol: nil, tone: nil, text: text)
            }
        }
        return Board.Popup(key: key, question: question, notice: nil)
    }

    private func settings(_ form: SettingsForm, _ config: Config) -> Board.Settings {
        let showsCodex = presenter.showsCodex
        let link = presenter.codexLink
        func status(_ s: SaveStatus) -> Board.Status { Board.Status(s.line(time: time)) }
        func row(_ label: String, _ help: String, _ line: StatusLine) -> Board.Row {
            Board.Row(status: Board.StatusRow(label: label, help: help, status: Board.Status(line)))
        }
        func field(_ f: SettingsForm.Field) -> Board.Row {
            let spec = form.field(f, showsCodex: showsCodex)
            let value = form.number(f)
            return Board.Row(field: Board.Field(id: f, label: spec.label, unit: spec.unit, value: value,
                                                text: value > 0 ? String(value) : "", invalid: form.invalid(f)))
        }
        func message(_ f: SettingsForm.Field, title: String, what: String) -> Board.Block {
            .card(title, status: status(form.status(f)), [Board.Row(text: Board.TextRow(
                id: f, label: title, text: form.text(f), note: Board.Note(form.messageNote(f)),
                restore: Board.RestoreButton(label: Words.Settings.restoreDefault, help: SettingsText.restoreHelp(what),
                                             enabled: form.canRestore(f))))])
        }

        // General: Context Guard itself, then one card per tool (what's installed, the judge).
        let watch = SettingsText.watchLabel(showsCodex: showsCodex)
        var general: [Board.Block] = [
            .card(Words.Settings.contextGuard, [Board.Row(toggle: Board.ToggleRow(id: "enabled", label: watch, on: config.enabled)),
                                                Board.Row(login: Board.LoginRow(label: Words.Settings.openAtLogin))]),
            .note(SettingsNote(text: Words.Settings.offNote, tone: .muted)),
            .card(SessionHost.claude.name, [row(Words.Settings.hooks, Words.Settings.hooksHelp, SettingsText.installed(installed.hooks)),
                                            row(Words.Settings.mod, Words.Settings.modHelp, SettingsText.installed(installed.mod)),
                                            row(Words.Settings.judge, Words.Settings.judgeHelp, SettingsText.claudeJudge)]),
            .note(SettingsNote(text: SettingsText.signInNote(.claude), tone: .muted)),
        ]
        if showsCodex {
            var rows = [row(Words.Settings.link, Words.Settings.linkHelp, SettingsText.link(link, installed: installed.codexLink))]
            if case .onlyWatching(let why) = link {
                rows.append(Board.Row(note: Board.Note(SettingsNote(text: SettingsText.onlyWatchingNote(why), tone: .warning))))
            }
            rows.append(row(Words.Settings.judge, Words.Settings.judgeHelp, SettingsText.codexJudge(presenter.codexJudge, link: link)))
            general += [.card(SessionHost.codex.name, rows), .note(SettingsNote(text: SettingsText.signInNote(.codex), tone: .muted))]
        }

        // When to Ask: each tool's thresholds, then the countdown both share; one card before Codex.
        let asking: [Board.Block] = showsCodex
            ? [.card(SessionHost.claude.name, status: status(form.claudeStatus), [field(.askK), field(.laterK)]),
               .note(form.claudeNote),
               .card(SessionHost.codex.name, status: status(form.codexStatus), [field(.codexAsk), field(.codexLater)]),
               .note(form.codexNote),
               .card(Words.Settings.ifYouDontAnswer, status: status(form.countdownStatus), [field(.autoYes)]),
               .note(form.countdownNote)]
            : [.card(Words.Settings.whenToAskCard, status: status(form.whenToAskStatus), [field(.askK), field(.autoYes), field(.laterK)]),
               .note(form.whenToAskNote)]

        let judgeName = SettingsText.codexJudgeName(presenter.codexJudge, link: link)
        let messages: [Board.Block] = [
            message(.message, title: Words.Settings.beforeCompacting, what: Words.Settings.saveMessage),
            message(.continueMessage, title: Words.Settings.afterCompacting, what: Words.Settings.continueMessage),
            .note(SettingsNote(text: SettingsText.messagesNote(showsCodex: showsCodex, codexJudgeName: judgeName), tone: .muted)),
        ]
        return Board.Settings(title: Words.Settings.windowTitle, tabs: [
            Board.Tab(id: "general", title: Words.Settings.general, blocks: general),
            Board.Tab(id: "asking", title: Words.Settings.whenToAsk, blocks: asking),
            Board.Tab(id: "messages", title: Words.Settings.messages, blocks: messages),
        ])
    }

    // MARK: Lines

    static func questionID(_ key: String) -> String? {
        let prefix = Presenter.questionKey("")
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// One message as one line (no newline).
    public static func line(_ message: FeedMessage) -> String {
        guard let data = try? encoder.encode(message) else { return #"{"type":"error","v":1}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One line `context-guard ui` writes.
public enum FeedMessage: Encodable, Equatable, Sendable {
    case board(Board)
    case chime
    case result(id: String?, problem: String?)
    case error(String)

    private enum Key: String, CodingKey { case v, type, board, id, problem, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(Feed.version, forKey: .v)
        switch self {
        case .board(let board):
            try c.encode("board", forKey: .type)
            try c.encode(board, forKey: .board)
        case .chime:
            try c.encode("chime", forKey: .type)
        case .result(let id, let problem):
            try c.encode("result", forKey: .type)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encodeIfPresent(problem, forKey: .problem)
        case .error(let message):
            try c.encode("error", forKey: .type)
            try c.encode(message, forKey: .message)
        }
    }
}

/// One line the app writes: an intent, and an `id` its result will carry.
public struct FeedRequest: Decodable, Equatable, Sendable {
    public var id: String?
    public var intent: FeedIntent

    private enum Key: String, CodingKey { case id }

    public init(from decoder: Decoder) throws {
        id = try decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: .id)
        intent = try FeedIntent(from: decoder)
    }
}

/// What you did in the Windows app, named by `do`.
public enum FeedIntent: Decodable, Equatable, Sendable {
    /// A popup's or the menu's answer to a session's question; `yes` from the menu is Compact Now.
    case answer(session: String, action: Answer.Action, source: Answer.Source)
    /// Turn Off in a popup: off, and a notice says how to turn it back on.
    case turnOff
    /// The menu's or Settings' switch.
    case enable(Bool)
    /// Watch This Session.
    case watch(session: String, on: Bool)
    /// ✕ on a question: hidden until it asks again.
    case hide(session: String)
    /// Show the Question, in the menu.
    case show(session: String)
    /// ✕ on a notice.
    case close(key: String)
    /// Settings opened: it starts from the settings as they are now.
    case settingsOpen
    case settingsClose
    /// A field as typed (a number field's text is read as a number).
    case set(SettingsForm.Field, String)
    /// A number field's − or + button.
    case step(SettingsForm.Field, up: Bool)
    /// Restore Default under a message.
    case restore(SettingsForm.Field)

    private enum Key: String, CodingKey { case `do`, session, action, source, on, key, field, value, up }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let name = try c.decode(String.self, forKey: .do)
        switch name {
        case "answer":
            self = .answer(session: try c.decode(String.self, forKey: .session), action: try c.decode(Answer.Action.self, forKey: .action),
                           source: try c.decode(Answer.Source.self, forKey: .source))
        case "turnOff": self = .turnOff
        case "enable": self = .enable(try c.decode(Bool.self, forKey: .on))
        case "watch": self = .watch(session: try c.decode(String.self, forKey: .session), on: try c.decode(Bool.self, forKey: .on))
        case "hide": self = .hide(session: try c.decode(String.self, forKey: .session))
        case "show": self = .show(session: try c.decode(String.self, forKey: .session))
        case "close": self = .close(key: try c.decode(String.self, forKey: .key))
        case "settingsOpen": self = .settingsOpen
        case "settingsClose": self = .settingsClose
        case "set": self = .set(try c.decode(SettingsForm.Field.self, forKey: .field), try c.decode(String.self, forKey: .value))
        case "step": self = .step(try c.decode(SettingsForm.Field.self, forKey: .field), up: try c.decode(Bool.self, forKey: .up))
        case "restore": self = .restore(try c.decode(SettingsForm.Field.self, forKey: .field))
        default:
            throw DecodingError.dataCorruptedError(forKey: .do, in: c, debugDescription: "unknown intent \(name)")
        }
    }
}

/// The popups and notices `context-guard ui` says are open, top to bottom, with when each notice
/// closes and when the presenter wants another look.
final class FeedPanels: PanelHost {
    /// The time of the call in progress.
    var now = Date()
    private(set) var openKeys: [String] = []
    private var notices: [String: (content: NoticeContent, closesAt: Date)] = [:]
    private var rechecks: [Date] = []
    private var opened = false

    func openQuestion(_ id: String) -> Bool {
        guard openKeys.count < Presenter.maxOpen else { return false }
        openKeys.append(Presenter.questionKey(id))
        opened = true
        return true
    }

    func showNotice(_ notice: NoticeContent, key: String) {
        openKeys.append(key)
        notices[key] = (notice, now.addingTimeInterval(notice.seconds))
    }

    func close(_ key: String) {
        openKeys.removeAll { $0 == key }
        notices[key] = nil
    }

    func recheck(after seconds: TimeInterval) {
        rechecks.append(now.addingTimeInterval(seconds))
    }

    func notice(_ key: String) -> NoticeContent? { notices[key]?.content }

    /// When a notice closes or a recheck is due.
    var pending: [Date] { notices.values.map(\.closesAt) + rechecks }

    /// Closes the notices whose time is up; true when a recheck is due.
    func expire(_ now: Date) -> Bool {
        for (key, n) in notices where n.closesAt <= now { close(key) }
        let due = rechecks.contains { $0 <= now }
        rechecks.removeAll { $0 <= now }
        return due
    }

    /// Whether a question opened since the last call.
    func takeOpened() -> Bool {
        defer { opened = false }
        return opened
    }
}
