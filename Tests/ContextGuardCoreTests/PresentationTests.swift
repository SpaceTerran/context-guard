import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// What the menu, popups and Settings say, worked out from a session and the settings.
final class PresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A running Claude Code session, idle or busy, with or without a waiter.
    func claude(_ tokens: Int, phase: Phase = .watching, status: String = "idle", waiter: Bool = false) -> SessionInfo {
        var s = SessionState(sessionId: "a1b2c3d4-0000-4000-8000-000000000001", now: now)
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.cycle = 1
        s.title = "Refactor the billing API"
        s.name = "api-server-4c"
        s.cwd = "/tmp/api-server"
        let entry = RegistryEntry(pid: 42, sessionId: s.sessionId, status: status)
        return SessionInfo(state: s, isLive: true, registry: entry, waiterAlive: waiter)
    }

    /// A Codex session in a 258k window, idle and shown in a terminal unless told otherwise.
    func codex(_ tokens: Int, phase: Phase = .watching, attached: Bool = true, status: String = "idle",
               onlyWatching: Bool = false) -> SessionInfo {
        var s = SessionState(sessionId: "01a1c7f0-4d8a-7870-aab2-07bc76ea7408", host: .codex, now: now)
        s.guarded = true
        s.tokens = tokens
        s.phase = phase
        s.cycle = 1
        s.title = "Add retries to the sync job"
        s.cwd = "/tmp/sync-service"
        s.codex = CodexFacts(window: 258_400, status: status, loaded: true)
        s.codex?.attached = attached
        s.codex?.onlyWatching = onlyWatching ? true : nil
        return SessionInfo(state: s, isLive: true, waiterAlive: false)
    }

    // MARK: A session's lines

    func testSizes() {
        var info = claude(302_517)
        XCTAssertEqual(info.tokensText, "302k")
        XCTAssertEqual(info.sizeText, "302k")
        XCTAssertEqual(info.questionHeading, "Context at 302k")
        info.state.awaitingCompactionRecord = true
        XCTAssertEqual(info.tokensText, "compacted")
        XCTAssertEqual(info.sizeText, "compacted")
        let c = codex(220_000)
        XCTAssertEqual(c.tokensText, "220k", "the menu's badge stays short")
        XCTAssertEqual(c.sizeText, "85% (220k)")
    }

    func testTheLocationLineNamesCodex() {
        XCTAssertEqual(claude(1).toolSubtitle, "api-server-4c · /tmp/api-server")
        XCTAssertEqual(codex(1).toolSubtitle, "Codex · /tmp/sync-service")
        var bare = codex(1)
        bare.state.cwd = nil
        XCTAssertEqual(bare.toolSubtitle, "Codex")
        var app = codex(1)
        app.state.codex?.surface = .app
        XCTAssertEqual(app.toolSubtitle, "Codex app · /tmp/sync-service", "an app chat says where it's open")
    }

    func testStatusInEachPhase() {
        let on = Config(), off = { var c = Config(); c.enabled = false; return c }()
        XCTAssertEqual(claude(40_000).statusText(on), "Asks at 300k")
        XCTAssertEqual(claude(40_000).statusText(off), "Not watching: Context Guard is off")
        XCTAssertEqual(claude(302_000, phase: .asking).statusText(on), "Waiting for your answer · compacts after 60 seconds")
        var noCountdown = on
        noCountdown.autoYesSeconds = 0
        XCTAssertEqual(claude(302_000, phase: .asking).statusText(noCountdown), "Waiting for your answer")
        XCTAssertEqual(claude(302_000, phase: .asking).statusText(off), "Asks again when Context Guard is on")
        XCTAssertEqual(claude(302_000, phase: .later).statusText(on), "Compacts by itself at 500k")
        XCTAssertEqual(claude(302_000, phase: .later).statusText(off), "Waiting for 500k: paused while off")
        XCTAssertEqual(claude(302_000, phase: .queued, status: "busy").statusText(on), "Asking it to save at its next step")
        XCTAssertEqual(claude(302_000, phase: .queued, waiter: true).statusText(on), "Asking it to save…")
        XCTAssertEqual(claude(302_000, phase: .queued).statusText(on), "Asks it to save when it next runs")
        XCTAssertEqual(codex(220_000, phase: .queued, attached: false).statusText(on), "Asks it to save when a terminal or the Codex app has it open")
        var sent = claude(341_250, phase: .sent)
        XCTAssertEqual(sent.statusText(on), "Asking it to save…", "not confirmed yet")
        sent.state.confirmedAt = now
        sent.state.sentTokens = 330_000
        XCTAssertEqual(sent.statusText(on), "Asked it to save at 330k")
        XCTAssertEqual(claude(302_000, phase: .skipped).statusText(on), "Not asking again until it compacts")
        XCTAssertEqual(codex(100_000).statusText(on), "Asks at 60% (155k)")
    }

    func testASessionTheLinkOnlyWatchesSaysSo() {
        let on = Config()
        for phase in [Phase.watching, .queued, .skipped] {
            let info = codex(220_000, phase: phase, onlyWatching: true)
            XCTAssertEqual(info.statusText(on), "Only watching, not compacting", "\(phase)")
            XCTAssertEqual(info.symbol, .watching, "\(phase)")
            XCTAssertFalse(info.canCompactNow, "\(phase): nothing could be sent")
            XCTAssertFalse(info.reachableNow, "\(phase)")
        }
        var sent = codex(220_000, phase: .sent, onlyWatching: true)
        sent.state.confirmedAt = now
        sent.state.sentTokens = 210_000
        XCTAssertEqual(sent.statusText(on), "Asked it to save at 81% (210k)", "one sent before reads as sent")
        var off = on
        off.enabled = false
        XCTAssertEqual(codex(220_000, onlyWatching: true).statusText(off), "Not watching: Context Guard is off")

        // You said Yes just as the link found it could only watch.
        let info = codex(220_000, phase: .queued, onlyWatching: true)
        let progress = QuestionProgress.of(info, config: on, reply: Reply(cycle: 1, action: .yes, at: now))
        XCTAssertEqual(progress, .nextRun)
        XCTAssertEqual(progress.text(info), "Only watching, not compacting")
    }

    func testAnUnwatchedSessionSaysSoUnlessItsSending() {
        var info = claude(302_000, phase: .asking)
        info.muted = true
        XCTAssertEqual(info.statusText(Config()), "Not watching this session")
        XCTAssertEqual(info.symbol, .notWatching)
        info.state.phase = .queued
        XCTAssertEqual(info.statusText(Config()), "Asks it to save when it next runs")
        XCTAssertEqual(info.symbol, .sending)
    }

    func testTheMenuSymbol() {
        XCTAssertEqual(claude(1).symbol, .watching)
        XCTAssertEqual(claude(1, phase: .asking).symbol, .asking)
        XCTAssertEqual(claude(1, phase: .later).symbol, .waiting)
        XCTAssertEqual(claude(1, phase: .queued).symbol, .sending)
        var sent = claude(1, phase: .sent)
        XCTAssertEqual(sent.symbol, .sending)
        sent.state.confirmedAt = now
        XCTAssertEqual(sent.symbol, .sent)
        XCTAssertEqual(claude(1, phase: .skipped).symbol, .skipped)
    }

    func testAnAnswerTheHookHasntAppliedYetCounts() {
        var info = claude(302_000, phase: .asking)
        info.pendingAnswer = Answer(cycle: 1, action: .yes, source: .menu, at: now)
        XCTAssertTrue(info.isSending)
        XCTAssertFalse(info.canCompactNow)
        info.pendingAnswer = Answer(cycle: 1, action: .later, source: .menu, at: now)
        XCTAssertEqual(info.symbol, .waiting)
        XCTAssertTrue(info.canCompactNow)
    }

    func testCompactNowWaitsForOneUnderWay() {
        var info = claude(341_000, phase: .sent)
        info.state.confirmedAt = now
        XCTAssertTrue(info.canCompactNow)
        info.state.followUp = FollowUp(nonce: "cg-1", now: now)
        XCTAssertFalse(info.canCompactNow, "a follow-up is still under way")
        info.state.followUp?.stage = .done
        XCTAssertTrue(info.canCompactNow)
    }

    func testWaitUntilTheCompactAtSizeThenNotNow() {
        let below = claude(302_000, phase: .asking)
        XCTAssertEqual(below.deferral(Config()), .wait(at: 500_000))
        XCTAssertEqual(below.label(for: below.deferral(Config())), "Wait until 500k")
        XCTAssertEqual(below.help(for: below.deferral(Config())), "Compact by itself when this session reaches 500k")
        XCTAssertEqual(Deferral.wait(at: 1).action, .later)
        let past = claude(500_000, phase: .asking)
        XCTAssertEqual(past.deferral(Config()), .notNow)
        XCTAssertEqual(past.label(for: .notNow), "Not Now")
        XCTAssertEqual(past.help(for: .notNow), "Don't ask again until this session compacts")
        XCTAssertEqual(Deferral.notNow.action, .skip)
        let c = codex(160_000, phase: .asking)
        XCTAssertEqual(c.label(for: c.deferral(Config())), "Wait until 80%")
        XCTAssertEqual(c.help(for: c.deferral(Config())), "Compact by itself when this session reaches 80% (206k)")
        XCTAssertEqual(codex(220_000, phase: .asking).deferral(Config()), .notNow)
    }

    func testTheQuestionSaysWhenItCantStartAtOnce() {
        let base = "Compact this session? It saves its work first."
        XCTAssertEqual(claude(302_000, phase: .asking, waiter: true).questionText, base)
        XCTAssertEqual(claude(302_000, phase: .asking, status: "busy").questionText, base)
        XCTAssertEqual(claude(302_000, phase: .asking).questionText, base + " It's idle, so it starts when it next runs.")
        XCTAssertEqual(codex(160_000, phase: .asking).questionText, base)
        XCTAssertEqual(codex(160_000, phase: .asking, attached: false).questionText,
                       base + " It isn't open in a terminal or the Codex app, so it starts once it is.")
    }

    func testTheCountdown() {
        let deadline = now.addingTimeInterval(59.2)
        XCTAssertEqual(claude(1, waiter: true).countdownText(deadline: deadline, now: now), "Compacts in 60 seconds unless you answer")
        XCTAssertEqual(claude(1, waiter: true).countdownText(deadline: now.addingTimeInterval(0.5), now: now), "Compacts in 1 second unless you answer")
        XCTAssertEqual(claude(1, waiter: true).countdownText(deadline: now, now: now), "Starting…")
        XCTAssertEqual(claude(1, status: "busy").countdownText(deadline: now, now: now), "Starting…")
        XCTAssertEqual(claude(1).countdownText(deadline: now, now: now), "Starts when this session next runs")
        XCTAssertEqual(codex(1, attached: false).countdownText(deadline: now, now: now), "Starts when a terminal or the Codex app has it open")
    }

    func testTheCountdownsDeadlineIsTheHooks() {
        var info = claude(302_000, phase: .asking)
        info.state.askedAt = now
        var c = Config()
        c.enabledAt = now.addingTimeInterval(-60)
        XCTAssertEqual(info.autoYesDeadline(c, now: now), now.addingTimeInterval(60))
        info.muted = true
        XCTAssertNil(info.autoYesDeadline(c, now: now), "an unwatched session never sends by itself")
    }

    func testTheFollowUpLine() {
        var info = claude(1)
        XCTAssertNil(info.followUpText(Config(), now: now))
        info.state.followUp = FollowUp(nonce: "cg-1", now: now)
        XCTAssertEqual(info.followUpText(Config(), now: now), "Compacts once it's done saving")
    }

    // MARK: The menu

    func testOnlyRunningGuardedSessionsAreListed() {
        var ended = claude(1)
        ended.isLive = false
        var unguarded = codex(1)
        unguarded.state.guarded = false
        XCTAssertEqual(Display.live([claude(1), ended, unguarded]).map(\.id), [claude(1).id])
    }

    func testTheGaugeShowsAQuestion() {
        var c = Config()
        XCTAssertFalse(Display.hasQuestion([claude(1)], config: c))
        XCTAssertTrue(Display.hasQuestion([claude(1, phase: .asking)], config: c))
        var muted = claude(1, phase: .asking)
        muted.muted = true
        XCTAssertFalse(Display.hasQuestion([muted], config: c))
        c.enabled = false
        XCTAssertFalse(Display.hasQuestion([claude(1, phase: .asking)], config: c))
    }

    func testTheMenusSettingsLines() {
        XCTAssertEqual(Display.thresholdLines(Config(), showsCodex: false), ["Asks at 300k · Wait until 500k"])
        XCTAssertEqual(Display.thresholdLines(Config(), showsCodex: true),
                       ["Claude Code: asks at 300k · Wait until 500k", "Codex: asks at 60% · Wait until 80%"])
    }

    func testLongTitlesAreCut() {
        XCTAssertEqual(Display.shortened("short"), "short")
        let long = String(repeating: "a", count: 50)
        XCTAssertEqual(Display.shortened(long), String(repeating: "a", count: 43) + "…")
        XCTAssertEqual(Display.shortened(long).count, 44)
    }

    // MARK: A popup's progress

    func testProgressAfterEachAnswer() {
        let c = Config()
        let asking = claude(302_000, phase: .asking)
        XCTAssertEqual(QuestionProgress.of(asking, config: c, reply: nil), .question)
        func reply(_ a: Answer.Action, cycle: Int = 1) -> Reply { Reply(cycle: cycle, action: a, at: now) }
        XCTAssertEqual(QuestionProgress.of(claude(302_000, phase: .later), config: c, reply: reply(.later)), .scheduled(at: 500_000))
        XCTAssertEqual(QuestionProgress.of(claude(302_000, phase: .skipped), config: c, reply: reply(.skip)), .closed)
        XCTAssertEqual(QuestionProgress.of(claude(302_000, phase: .queued, status: "busy"), config: c, reply: reply(.yes)), .nextStep)
        XCTAssertEqual(QuestionProgress.of(claude(302_000, phase: .queued, waiter: true), config: c, reply: reply(.yes)), .waking)
        XCTAssertEqual(QuestionProgress.of(claude(302_000, phase: .queued), config: c, reply: reply(.yes)), .nextRun)
        var sent = claude(302_000, phase: .sent)
        XCTAssertEqual(QuestionProgress.of(sent, config: c, reply: reply(.yes)), .waking)
        sent.state.confirmedAt = now
        XCTAssertEqual(QuestionProgress.of(sent, config: c, reply: reply(.yes)), .sent)
        XCTAssertEqual(QuestionProgress.of(claude(1), config: c, reply: reply(.yes)), .closed)
        XCTAssertEqual(QuestionProgress.of(asking, config: c, reply: reply(.yes, cycle: 0)), .question, "an answer from an earlier cycle")
    }

    func testAQuestionLeftToItsCountdownWentOutAsYes() {
        var info = claude(302_000, phase: .queued, waiter: true)
        info.state.askTimedOut = true
        XCTAssertEqual(QuestionProgress.of(info, config: Config(), reply: nil), .waking)
    }

    func testNoQuestionWhileOffOrUnwatched() {
        var c = Config()
        c.enabled = false
        XCTAssertEqual(QuestionProgress.of(claude(302_000, phase: .asking), config: c, reply: nil), .closed)
        var muted = claude(302_000, phase: .asking)
        muted.muted = true
        XCTAssertEqual(QuestionProgress.of(muted, config: Config(), reply: nil), .closed)
    }

    func testHowLongEachProgressStaysAndWhatItSays() {
        XCTAssertNil(QuestionProgress.question.linger)
        XCTAssertEqual(QuestionProgress.nextStep.linger, 45)
        XCTAssertEqual(QuestionProgress.waking.linger, 45)
        XCTAssertEqual(QuestionProgress.nextRun.linger, 6)
        XCTAssertEqual(QuestionProgress.sent.linger, 2.5)
        XCTAssertEqual(QuestionProgress.scheduled(at: 1).linger, 2.5)
        XCTAssertEqual(QuestionProgress.closed.linger, 0)
        let info = codex(160_000)
        XCTAssertEqual(QuestionProgress.nextStep.text(info), "Asking it to save at its next step…")
        XCTAssertEqual(QuestionProgress.waking.text(info), "Asking it to save…")
        XCTAssertEqual(QuestionProgress.nextRun.text(info), "Asks it to save when a terminal or the Codex app has it open")
        XCTAssertEqual(QuestionProgress.sent.text(info), "Asked it to save, then it compacts")
        XCTAssertEqual(QuestionProgress.scheduled(at: 206_720).text(info), "Compacts by itself at 80% (206k)")
        XCTAssertEqual(QuestionProgress.question.text(info), "")
        XCTAssertEqual(QuestionProgress.waking.mark, .working)
        XCTAssertEqual(QuestionProgress.sent.mark, .icon(.success, .success))
        XCTAssertEqual(QuestionProgress.nextRun.mark, .icon(.waiting, .muted))
        XCTAssertEqual(QuestionProgress.closed.mark, .none)
    }

    // MARK: Settings

    func testClaudeCodesThresholds() {
        XCTAssertNil(SettingsText.thresholdProblem(askK: 300, laterK: 500))
        XCTAssertEqual(SettingsText.thresholdProblem(askK: 0, laterK: 500), "“Ask at” needs a number, like 300.")
        XCTAssertEqual(SettingsText.thresholdProblem(askK: 300, laterK: 0), "“If you choose Wait, compact at” needs a number, like 500.")
        XCTAssertEqual(SettingsText.thresholdProblem(askK: 500, laterK: 500), "“If you choose Wait, compact at” has to be more than “Ask at”.")
        XCTAssertTrue(SettingsText.askInvalid(askK: 500, laterK: 500))
        XCTAssertTrue(SettingsText.laterInvalid(askK: 500, laterK: 500))
        XCTAssertTrue(SettingsText.askInvalid(askK: 0, laterK: 500))
        XCTAssertFalse(SettingsText.laterInvalid(askK: 0, laterK: 500))
        XCTAssertEqual(SettingsText.claudeThresholdsNote(askK: 300, laterK: 500),
                       "When a session reaches 300k tokens, a popup asks whether to compact it. If you choose Wait, it compacts at 500k.")
        XCTAssertEqual(SettingsText.whenToAskNote(askK: 300, laterK: 500, autoYes: 60),
                       "When a session reaches 300k tokens, a popup asks whether to compact it. If you don't answer within 60 seconds, it compacts. If you choose Wait, it compacts at 500k.")
        XCTAssertEqual(SettingsText.whenToAskNote(askK: 300, laterK: 500, autoYes: 0),
                       "When a session reaches 300k tokens, a popup asks whether to compact it. It waits for your answer (0 seconds: it never compacts on its own). If you choose Wait, it compacts at 500k.")
    }

    func testCodexsThresholdsHaveTheSameLimitsAsTheConfig() {
        XCTAssertNil(SettingsText.problem(.codex, ask: 60, later: 80))
        XCTAssertEqual(SettingsText.problem(.codex, ask: 0, later: 80), "Codex's “Ask at” needs a number, like 60.")
        XCTAssertEqual(SettingsText.problem(.codex, ask: 5, later: 80), "Codex's “Ask at” has to be from 10% to 79%.")
        XCTAssertEqual(SettingsText.problem(.codex, ask: 60, later: 0), "Codex's “If you choose Wait, compact at” needs a number, like 80.")
        XCTAssertEqual(SettingsText.problem(.codex, ask: 60, later: 90),
                       "Codex's “If you choose Wait, compact at” goes up to 84%: Codex compacts by itself at about 95%, and saving needs room before that.")
        XCTAssertEqual(SettingsText.problem(.codex, ask: 60, later: 64), "Codex's “If you choose Wait, compact at” has to be at least 5% more than its “Ask at”.")
        XCTAssertTrue(SettingsText.askInvalid(.codex, ask: 5))
        XCTAssertFalse(SettingsText.laterInvalid(.codex, ask: 5, later: 64), "only Ask at is marked")
        XCTAssertTrue(SettingsText.laterInvalid(.codex, ask: 60, later: 64))
        // Whatever passes is saved as typed.
        for ask in 0...100 {
            for later in 0...100 where SettingsText.problem(.codex, ask: ask, later: later) == nil {
                var c = Config()
                c.codexAskPercent = ask
                c.codexLaterPercent = later
                XCTAssertEqual(c.normalized.codexAskPercent, ask)
                XCTAssertEqual(c.normalized.codexLaterPercent, later)
            }
        }
        XCTAssertEqual(SettingsText.thresholdsNote(.codex, ask: 60, later: 80),
                       "When a session reaches 60% of its window, a popup asks whether to compact it. If you choose Wait, it compacts at 80%. In a 258k window, that's 155k and 206k.")
    }

    func testCursorsThresholdsHaveTheSameLimitsAsTheConfig() {
        XCTAssertNil(SettingsText.problem(.cursor, ask: 60, later: 80))
        XCTAssertEqual(SettingsText.problem(.cursor, ask: 0, later: 80), "Cursor's “Ask at” needs a number, like 60.")
        XCTAssertEqual(SettingsText.problem(.cursor, ask: 80, later: 84), "Cursor's “Ask at” has to be from 10% to 79%.")
        XCTAssertEqual(SettingsText.problem(.cursor, ask: 60, later: 85),
                       "Cursor's “If you choose Wait, compact at” goes up to 84%: saving needs room before Cursor summarizes by itself.")
        XCTAssertEqual(SettingsText.problem(.cursor, ask: 60, later: 61),
                       "Cursor's “If you choose Wait, compact at” has to be at least 5% more than its “Ask at”.")
        XCTAssertTrue(SettingsText.laterInvalid(.cursor, ask: 60, later: 61))
        XCTAssertFalse(SettingsText.laterInvalid(.cursor, ask: 80, later: 61), "only Ask at is marked")
        for ask in 0...100 {
            for later in 0...100 where SettingsText.problem(.cursor, ask: ask, later: later) == nil {
                var c = Config()
                c.cursorAskPercent = ask
                c.cursorLaterPercent = later
                XCTAssertEqual(c.normalized.cursorAskPercent, ask)
                XCTAssertEqual(c.normalized.cursorLaterPercent, later)
            }
        }
        XCTAssertEqual(SettingsText.thresholdsNote(.cursor, ask: 60, later: 80),
                       "When a session reaches 60% of its window, a popup asks whether to compact it. If you choose Wait, it compacts at 80%. In a 200k window, that's 120k and 160k.")
        XCTAssertEqual(SettingsText.askField(.cursor).range, Config.cursorAskPercentRange)
        XCTAssertEqual(SettingsText.laterField(.cursor).range, Config.cursorLaterPercentRange)
        XCTAssertEqual(SettingsText.laterField(.cursor).unit, "%")
    }

    func testTheFields() {
        XCTAssertEqual(SettingsText.askField.range, 50...10_000)
        XCTAssertEqual(SettingsText.laterField(.codex).range, Config.codexLaterPercentRange)
        XCTAssertEqual(SettingsText.countdownField(ownCard: true).label, "Compact after")
        XCTAssertEqual(SettingsText.countdownField(ownCard: false).label, "If you don't answer, compact after")
        XCTAssertEqual(SettingsText.countdownField(ownCard: false).range, 0...3_600, "the same limits as Config.normalized")
        XCTAssertEqual(SettingsText.countdownNote(60),
                       "If you don't answer a popup within 60 seconds, it compacts the session, whichever tool it runs in.")
        XCTAssertEqual(SettingsText.countdownNote(0),
                       "A popup waits for your answer, whichever tool the session runs in (0 seconds: it never compacts on its own).")
        XCTAssertEqual(SettingsText.countdownNote(60, otherTools: false), "If you don't answer a popup within 60 seconds, it compacts the session.")
        XCTAssertEqual(SettingsText.countdownNote(0, otherTools: false), "A popup waits for your answer (0 seconds: it never compacts on its own).")
    }

    func testTheCodexLinkAndJudges() {
        XCTAssertEqual(SettingsText.link(.connected, installed: true), StatusLine(text: "Connected", symbol: .success, tone: .success))
        XCTAssertEqual(SettingsText.link(.onlyWatching("why"), installed: true).text, "Only watching")
        XCTAssertEqual(SettingsText.link(.waiting, installed: true), StatusLine(text: "Waiting for Codex", symbol: .waiting, tone: .muted))
        XCTAssertEqual(SettingsText.link(.notRunning, installed: true).text, "Not running: run \(Words.installer)")
        XCTAssertEqual(SettingsText.link(.notRunning, installed: false), SettingsText.installed(false))
        XCTAssertEqual(SettingsText.installed(true), StatusLine(text: "Installed", symbol: .success, tone: .success))
        XCTAssertEqual(SettingsText.installed(false), StatusLine(text: "Not installed: run \(Words.installer)", symbol: .warning, tone: .warning))
        XCTAssertEqual(SettingsText.claudeJudge.text, "Haiku")
        XCTAssertEqual(SettingsText.codexJudge("gpt-6-luna", link: .waiting).text, "gpt-6-luna")
        XCTAssertEqual(SettingsText.codexJudge(nil, link: .connected), StatusLine(text: "Each session's own model", symbol: .success, tone: .success))
        XCTAssertEqual(SettingsText.codexJudge(nil, link: .notRunning), StatusLine(text: "Picked when Codex connects", symbol: .waiting, tone: .muted))
        XCTAssertEqual(SettingsText.codexJudgeName("gpt-6-luna", link: .notRunning), "gpt-6-luna")
        XCTAssertEqual(SettingsText.codexJudgeName(nil, link: .onlyWatching("x")), "each session's own model")
        XCTAssertEqual(SettingsText.codexJudgeName(nil, link: .waiting), "a small OpenAI model")
        XCTAssertEqual(SettingsText.onlyWatchingNote("this Codex has no thread/queue/add"),
                       "Only watching, not compacting: this Codex has no thread/queue/add. A newer Codex may fix this.")
        XCTAssertEqual(SettingsText.signInNote(.codex), "No API key: the judge uses your Codex sign-in.")
        XCTAssertEqual(SettingsText.watchLabel(otherTools: false), "Watch Claude Code sessions")
        XCTAssertEqual(SettingsText.watchLabel(otherTools: true), "Watch sessions")
    }

    func testCursorsTypingAsTheLatestAppChatSawIt() {
        func chat(_ n: Int, _ surface: CursorSurface, canType: Bool?, at: TimeInterval) -> SessionInfo {
            var s = SessionState(sessionId: "00000000-0000-4000-8000-00000000000\(n)", host: .cursor, now: now.addingTimeInterval(at))
            s.cursorChat = CursorFacts(surface: surface, window: 200_000)
            s.cursorChat?.canType = canType
            return SessionInfo(state: s, isLive: true, waiterAlive: false)
        }
        XCTAssertNil(Display.cursorCanType([]))
        XCTAssertNil(Display.cursorCanType([chat(1, .cli, canType: true, at: 0), chat(2, .app, canType: nil, at: 9)]),
                     "the CLI types through its terminal, and an older chat file doesn't say")
        XCTAssertEqual(Display.cursorCanType([chat(1, .app, canType: false, at: 0), chat(2, .app, canType: true, at: 60)]), true)
        XCTAssertEqual(Display.cursorCanType([chat(1, .app, canType: false, at: 60), chat(2, .app, canType: true, at: 0)]), false)
    }

    func testCursorsRows() {
        XCTAssertEqual(SettingsText.cursorTyping(true), StatusLine(text: "Cursor's Accessibility", symbol: .success, tone: .success))
        XCTAssertEqual(SettingsText.cursorTyping(false), StatusLine(text: "Cursor needs Accessibility", symbol: .warning, tone: .warning))
        XCTAssertEqual(SettingsText.cursorTyping(nil).tone, .muted)
        XCTAssertEqual(SettingsText.cursorJudge(cliFound: true), StatusLine(text: "Auto", symbol: .success, tone: .success))
        XCTAssertEqual(SettingsText.cursorJudge(cliFound: false), StatusLine(text: "Needs the Cursor CLI", symbol: .warning, tone: .warning))
        XCTAssertEqual(SettingsText.signInNote(.cursor), "No API key: the judge uses your Cursor sign-in.")
    }

    func testTheMessagesNotes() {
        let about = Words.Settings.beforeCompactingAbout
        XCTAssertEqual(SettingsText.messageNote("hi", status: .unchanged, about: about).text, about)
        XCTAssertEqual(SettingsText.messageNote(" \n", status: .saved(now), about: about).text, "Empty, so it sends the default.")
        XCTAssertEqual(SettingsText.messageNote(" \n", status: .saved(now), about: about).tone, .warning)
        XCTAssertEqual(SettingsText.messageNote("", status: .notSaved("disk full"), about: about).text, "Not saved: disk full")
        XCTAssertEqual(SettingsText.messageNote("", status: .notSaved("disk full"), about: about).tone, .danger)
        XCTAssertEqual(SettingsText.restoreHelp("save message"), "Put back the default save message")
        XCTAssertTrue(SettingsText.messagesNote(codexJudge: nil).contains("The judge (Haiku) reads"))
        XCTAssertTrue(SettingsText.messagesNote(codexJudge: "gpt-6-luna")
            .contains("The judge (Haiku for Claude Code, gpt-6-luna for Codex) reads"))
        XCTAssertTrue(SettingsText.messagesNote(codexJudge: "gpt-6-luna", showsCursor: true)
            .contains("The judge (Haiku for Claude Code, gpt-6-luna for Codex, Auto for Cursor) reads"))
        XCTAssertTrue(SettingsText.messagesNote(codexJudge: nil, showsCursor: true)
            .contains("The judge (Haiku for Claude Code, Auto for Cursor) reads"))
    }

    func testACardsHeader() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(SaveStatus.latest(.saved(early), .notSaved("x")), .notSaved("x"))
        XCTAssertEqual(SaveStatus.latest(.notSaved("a"), .notSaved("b")), .notSaved("a"))
        XCTAssertEqual(SaveStatus.latest(.saved(early), .saved(late)), .saved(late))
        XCTAssertEqual(SaveStatus.latest(.saved(early), .unchanged), .saved(early))
        XCTAssertEqual(SaveStatus.latest(.unchanged, .saved(late)), .saved(late))
        XCTAssertEqual(SaveStatus.latest(.unchanged, .unchanged), .unchanged)
        XCTAssertEqual(SaveStatus.unchanged.line, StatusLine(text: "Saved", symbol: .saved, tone: .muted))
        XCTAssertTrue(SaveStatus.saved(now).line.text.hasPrefix("Saved "))
        XCTAssertEqual(SaveStatus.saved(now).line.tone, .success)
        XCTAssertEqual(SaveStatus.notSaved("x").line, StatusLine(text: "Not saved", symbol: .warning, tone: .danger))
    }

    // MARK: Installs

    func testTheHooksAreFoundByTheirProgramsPath() throws {
        let dir = TempDir()
        let paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        let settings = paths.claudeDir.appendingPathComponent("settings.json")
        XCTAssertFalse(HookInstall.isInstalled(paths), "no settings file")
        try Data(#"{"hooks": {}}"#.utf8).write(to: settings)
        XCTAssertFalse(HookInstall.isInstalled(paths))
        try Data(#"{"hooks": {"Stop": [{"hooks": [{"command": "CG_CLAUDE_PID=$PPID exec \"$HOME/.claude/hooks/context-guard/context-guard\" hook"}]}]}}"#.utf8)
            .write(to: settings)
        XCTAssertTrue(HookInstall.isInstalled(paths))
        // Windows: an exec-form hook's program path, backslashes doubled in JSON.
        try Data(#"{"hooks": {"Stop": [{"hooks": [{"command": "C:\\Users\\x\\.claude\\hooks\\context-guard\\context-guard.exe"}]}]}}"#.utf8)
            .write(to: settings)
        XCTAssertTrue(HookInstall.isInstalled(paths))
    }

    func testTheModNeedsItsFilesAndThePluginOn() throws {
        let dir = TempDir()
        let paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        let hooks = paths.claudeDir.appendingPathComponent("hooks/context-guard/mod/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let settings = paths.claudeDir.appendingPathComponent("settings.json")
        try Data(#"{"enabledPlugins": {"context-guard@context-guard": true}}"#.utf8).write(to: settings)
        XCTAssertFalse(ModInstall.isInstalled(paths), "the module isn't there")
        try Data("export {}".utf8).write(to: hooks.appendingPathComponent("register.ts"))
        XCTAssertTrue(ModInstall.isInstalled(paths))
        try Data(#"{"enabledPlugins": {"context-guard@context-guard": false}}"#.utf8).write(to: settings)
        XCTAssertFalse(ModInstall.isInstalled(paths), "the plugin is off")
    }
}
