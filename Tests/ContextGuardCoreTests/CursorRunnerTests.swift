import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

/// Transcript lines shaped like Cursor 3.30's (app) and 2026.11's (CLI), with demo values.
enum CursorLine {
    static func prompt(_ text: String) -> String {
        Line.json(["role": "user", "message": ["content": [["type": "text",
            "text": "<timestamp>Friday, Nov 13, 2026, 9:16 PM (UTC-7)</timestamp>\n<user_query>\n\(text)\n</user_query>"]]]])
    }

    static func reply(_ text: String) -> String {
        Line.json(["role": "assistant", "message": ["content": [["type": "text", "text": text]]]])
    }

    static func tool(_ name: String, _ input: [String: Any]) -> String {
        Line.json(["role": "assistant", "message": ["content": [["type": "tool_use", "name": name, "input": input]]]])
    }

    static func turnEnded(_ status: String = "success") -> String {
        Line.json(["type": "turn_ended", "status": status])
    }
}

/// Types into a chat the way a test says it went.
final class FakeTyping: CursorTyping, @unchecked Sendable {
    private let lock = NSLock()
    var reachNow: TypingReach = .ready
    /// Runs while `/summarize` is typed: what Cursor does then (its preCompact hook).
    var onSummarize: () -> Void = {}
    var compactResult: CursorTypingResult?
    private(set) var compacts: [CursorChatRef] = []
    private(set) var typed: [String] = []

    func reach(_ chat: CursorChatRef) -> TypingReach { reachNow }

    func compact(_ chat: CursorChatRef, started: @escaping @Sendable () -> Bool,
                 continueText: @escaping @Sendable () -> String?) -> CursorTypingResult {
        lock.lock(); compacts.append(chat); lock.unlock()
        if let compactResult { return compactResult }
        onSummarize()
        guard started() else { return .failed("Cursor didn't start summarizing") }
        // The CLI's continue message goes in with the stop that ends the summary.
        guard chat.surface == .app else { return .compacted(continued: false) }
        guard let text = continueText() else { return .compacted(continued: false) }
        lock.lock(); typed.append(text); lock.unlock()
        return .compacted(continued: true)
    }

    func send(_ chat: CursorChatRef, text: String) -> CursorTypingResult {
        lock.lock(); typed.append(text); lock.unlock()
        return .sent
    }
}

final class FakeJudge: CursorJudging, @unchecked Sendable {
    var reply: Result<String, CursorJudgeFailure> = .success(#"{"verdict":"ready","reason":"Saved and pushed."}"#)
    private(set) var prompts: [String] = []

    func judge(_ prompt: String) -> Result<String, CursorJudgeFailure> {
        prompts.append(prompt)
        return reply
    }
}

/// Cursor's own list of chats, as a test sets it.
final class FakeChats: CursorChatChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var said: CursorChatStanding? = .open
    private var count = 0

    /// What every look-up says from now on (nil: Cursor's store can't be read).
    var now: CursorChatStanding? {
        get { lock.lock(); defer { lock.unlock() }; return said }
        set { lock.lock(); said = newValue; lock.unlock() }
    }

    var asked: Int { lock.lock(); defer { lock.unlock() }; return count }

    func standing(_ chat: CursorChatRef) -> CursorChatStanding? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return said
    }
}

/// A Cursor chat through `CursorRunner`, against real files: its transcript as Cursor writes it and
/// the hook calls as Cursor makes them.
final class CursorRunnerTests: XCTestCase {
    let dir = TempDir()
    let clock = TestClock()
    let probe = FakeProbe()
    let typing = FakeTyping()
    let judge = FakeJudge()
    let chats = FakeChats()
    let id = "0b6f3d2e-5a41-4c7e-9d0a-3f2e1c4b5a69"
    let appPid: Int32 = 4242
    let appStart = ProcessStart(seconds: 1_700_000_000, microseconds: 0)
    var paths: Paths!
    var log: Transcript!
    var surface: CursorSurface? = .app
    var helper = false
    var terminal: CursorTerminal?
    var canType: Bool?
    var turnNumber = 0
    var standingEvery: TimeInterval = 10

    override func setUp() {
        paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        log = Transcript(dir, name: "\(id).jsonl")
        probe.set(appPid, ProcessIdentity(start: appStart, hasTTY: false))
        probe.set(ProcessInfo.processInfo.processIdentifier,
                  ProcessIdentity(start: ProcessStart(seconds: 1_700_000_100, microseconds: 0), hasTTY: false))
    }

    var runner: CursorRunner {
        let clock = self.clock
        var runner = CursorRunner(paths: paths, probe: probe, clock: { clock.now })
        runner.standingEvery = standingEvery
        return runner
    }

    var state: SessionState? { SessionState.load(id, paths) }
    var generation: String { "gen-\(turnNumber)" }

    func look(tokens: Int? = nil) -> CursorChatLook {
        CursorChatLook(surface: surface, helper: helper, tokens: tokens, window: 200_000, name: "Settings screen",
                       pid: appPid, start: appStart, terminal: terminal, canType: canType)
    }

    func input(_ event: CursorEvent, prompt: String? = nil, status: String? = nil, trigger: String? = nil,
               contextTokens: Int? = nil) -> CursorHookInput {
        CursorHookInput(event: event.rawValue, conversationId: id, generationId: generation, model: "default",
                        transcriptPath: log.path, workspace: "/Users/demo/code", prompt: prompt, status: status,
                        trigger: trigger, contextTokens: contextTokens, contextWindow: contextTokens == nil ? nil : 200_000)
    }

    @discardableResult
    func call(_ event: CursorEvent, tokens: Int? = nil, prompt: String? = nil, status: String? = nil,
              trigger: String? = nil, contextTokens: Int? = nil) -> CursorReply {
        runner.handle(input(event, prompt: prompt, status: status, trigger: trigger, contextTokens: contextTokens),
                      look: look(tokens: tokens))
    }

    func configure(_ change: (inout Config) -> Void = { _ in }) throws {
        var c = Config()
        c.enabledAt = clock.now.addingTimeInterval(-3_600)
        change(&c)
        try c.save(paths)
    }

    func answer(_ action: Answer.Action) throws {
        try Answer(cycle: state?.cycle ?? 0, action: action, source: .popup, at: clock.now).save(for: id, paths)
    }

    /// Makes the transcript look untouched for a while.
    func settle() throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: log.path)
    }

    /// A turn of yours that ends at `tokens` (of a 200k window).
    @discardableResult
    func turn(_ prompt: String, reply: String, tokens: Int) -> CursorReply {
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: prompt)
        log.append(CursorLine.prompt(prompt), CursorLine.tool("Read", ["path": "/Users/demo/code/README.md"]))
        call(.postToolUse, tokens: tokens)
        log.append(CursorLine.reply(reply), CursorLine.turnEnded())
        return call(.stop, tokens: tokens, status: "completed")
    }

    func hold(_ seconds: TimeInterval = 1.5) -> String? {
        guard let token = state?.waiterToken else { return nil }
        return runner.hold(sessionId: id, token: token, maxDuration: seconds, poll: 0.05, typing: typing, judge: judge,
                           chats: chats)
    }

    /// A chat at 130k of 200k (65%) that you said Yes to, with the save message sent between turns and
    /// in its transcript as the next prompt. Returns the save message's tag.
    func askAndSend() throws -> String {
        try configure()
        guard case .hold = turn("Add a settings screen", reply: "Added it.", tokens: 130_000) else {
            XCTFail("a guarded chat waits after its turn")
            return ""
        }
        XCTAssertEqual(state?.phase, .asking)
        try answer(.yes)
        let text = try XCTUnwrap(hold())
        let nonce = try XCTUnwrap(state?.sentNonce)
        XCTAssertEqual(text, "\(Config.defaultMessage) [\(nonce)]", "between turns it's your words, as you'd type them")
        XCTAssertEqual(state?.sentVia, .turn)
        XCTAssertNil(state?.waiterToken, "the hold ended with the message")

        turnNumber += 1
        // The app says the follow-up is going in; the CLI sends it as a new turn without
        // `beforeSubmitPrompt` (2026.11.13), so its turn's stop finds it in the transcript.
        if surface == .app {
            call(.beforeSubmitPrompt, prompt: text)
            XCTAssertNotNil(state?.confirmedAt, "the tag in the prompt confirms it")
        }
        log.append(CursorLine.prompt(text), CursorLine.tool("Shell", ["command": "git push"]),
                   CursorLine.reply("Pushed and saved. Ready for compaction."), CursorLine.turnEnded())
        guard case .hold = call(.stop, tokens: 140_000, status: "completed") else {
            XCTFail("it waits again after saving")
            return ""
        }
        XCTAssertNotNil(state?.confirmedAt, "confirmed by the time its turn ends")
        try settle()
        return nonce
    }

    // MARK: - Which calls count

    func testCallsItDoesntGuardMakeNoSession() {
        surface = nil
        XCTAssertEqual(turn("Hi", reply: "Hello", tokens: 130_000), .none)
        XCTAssertNil(state, "a judge run, a -p run, or a chat in neither store")

        surface = .app
        XCTAssertEqual(call(.sessionEnd), .none)
        XCTAssertNil(state, "a chat it never saw a turn of has nothing to end")
    }

    func testAHelperChatIsTrackedButNeverGuarded() throws {
        try configure()
        helper = true
        XCTAssertEqual(turn("Look into it", reply: "Done", tokens: 150_000), .none)
        XCTAssertEqual(state?.guarded, false)
        XCTAssertEqual(state?.tokens, 150_000)
    }

    func testAChatIsGuardedWithItsWindowAndProcess() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        let s = try XCTUnwrap(state)
        XCTAssertEqual(s.hostKind, .cursor)
        XCTAssertTrue(s.guarded)
        XCTAssertEqual(s.window, 200_000)
        XCTAssertEqual(s.cursorChat?.pid, appPid)
        XCTAssertEqual(s.cursorChat?.runsIn, .app)
        XCTAssertEqual(s.title, "Settings screen")
        XCTAssertEqual(s.phase, .watching, "50% is below Ask at 60%")
        XCTAssertEqual(TurnRecord.load(id, paths)?.active, false)
        XCTAssertNil(s.cursorChat?.canType)
        // Whether Cursor may type, as its hooks last saw it (Settings shows it); a call that doesn't say keeps it.
        canType = false
        call(.postToolUse)
        XCTAssertEqual(state?.cursorChat?.canType, false)
        canType = nil
        call(.postToolUse)
        XCTAssertEqual(state?.cursorChat?.canType, false)
    }

    // MARK: - The save message

    func testTheSaveMessageGoesInBetweenTurnsAndItsTagConfirmsIt() throws {
        _ = try askAndSend()
        XCTAssertEqual(state?.phase, .sent)
    }

    func testAnotherPromptFirstSendsItAtTheNextStepWithItsReason() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 130_000)
        try answer(.yes)
        _ = try XCTUnwrap(hold())

        // Your own prompt came first: Cursor dropped the follow-up.
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Also add a dark mode")
        XCTAssertEqual(state?.phase, .queued)
        guard case .context(let text) = call(.postToolUse, tokens: 131_000) else { return XCTFail("expected it mid-turn") }
        let nonce = try XCTUnwrap(state?.sentNonce)
        XCTAssertTrue(text.hasPrefix("Context Guard (a Cursor hook the user installed to watch context size)"), text)
        XCTAssertTrue(text.hasSuffix("[\(nonce)]"))
        XCTAssertEqual(state?.sentVia, .step)
        XCTAssertNil(state?.confirmedAt)
        call(.postToolUse, tokens: 132_000)
        XCTAssertNotNil(state?.confirmedAt, "the turn went on after it")
    }

    func testAStoppedTurnSendsItAgain() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 130_000)
        try answer(.yes)
        _ = try XCTUnwrap(hold())
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Also add a dark mode")
        guard case .context = call(.postToolUse, tokens: 131_000) else { return XCTFail("expected it mid-turn") }
        guard case .hold = call(.stop, tokens: 131_000, status: "aborted") else { return XCTFail("it still waits") }
        XCTAssertEqual(state?.phase, .queued)
        XCTAssertEqual(state?.resendCount, 1)
        XCTAssertNil(hold(0.5), "you stopped the turn: nothing starts another")
        XCTAssertEqual(state?.phase, .queued)

        // Your next turn takes it, at its first step.
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Carry on")
        guard case .context = call(.postToolUse, tokens: 132_000) else { return XCTFail("expected it at the next step") }
    }

    func testTheCLIsFollowUpIsConfirmedByItsPromptInTheTranscript() throws {
        surface = .cli
        terminal = CursorTerminal(kind: .tmux, pane: "%3", socket: "/private/tmp/tmux-501/default")
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 130_000)
        try answer(.yes)
        let text = try XCTUnwrap(hold())

        // Its turn, with no beforeSubmitPrompt; a reply that repeats the tag doesn't count.
        turnNumber += 1
        log.append(CursorLine.reply("Saving now [\(try XCTUnwrap(state?.sentNonce))]"))
        call(.postToolUse, tokens: 131_000)
        XCTAssertNil(state?.confirmedAt, "only a prompt with the tag confirms it")
        log.append(CursorLine.prompt(text), CursorLine.reply("Pushed and saved."), CursorLine.turnEnded())
        guard case .hold = call(.stop, tokens: 140_000, status: "completed") else { return XCTFail("it waits again") }
        XCTAssertNotNil(state?.confirmedAt)
        XCTAssertEqual(state?.phase, .sent)
    }

    func testTheCLIsFollowUpInTheTranscriptIsntSentAgainByYourNextPrompt() throws {
        surface = .cli
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 130_000)
        try answer(.yes)
        let text = try XCTUnwrap(hold())
        // Its turn went in, but no stop was heard of it (a hook that timed out): your next prompt
        // finds it in the transcript rather than sending it again.
        log.append(CursorLine.prompt(text), CursorLine.reply("Pushed and saved."), CursorLine.turnEnded())
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Also add a dark mode")
        XCTAssertEqual(state?.phase, .sent)
        XCTAssertNotNil(state?.confirmedAt)
    }

    // MARK: - Judge, compact, continue

    func testTheAppChatIsJudgedCompactedAndContinued() throws {
        let nonce = try askAndSend()
        typing.onSummarize = { [self] in call(.preCompact, trigger: "manual", contextTokens: 140_000) }
        XCTAssertNil(hold())

        XCTAssertEqual(judge.prompts.count, 1)
        XCTAssertTrue(judge.prompts[0].contains("Pushed and saved"), "the judge reads what the chat did")
        XCTAssertEqual(typing.compacts.map(\.id), [id])
        XCTAssertEqual(typing.typed, [Config.defaultContinueMessage], "typed right after /summarize")
        let f = try XCTUnwrap(state?.followUp)
        XCTAssertEqual(f.nonce, nonce)
        XCTAssertEqual(f.stage, .done)
        XCTAssertEqual(state?.lastCompaction?.trigger, "manual")
        XCTAssertEqual(state?.lastCompaction?.preTokens, 140_000)

        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: Config.defaultContinueMessage)
        call(.stop, tokens: 21_000, status: "completed")
        XCTAssertEqual(state?.followUp?.tokensAfter, 21_000, "the first size after the summary is what it came to")
        XCTAssertEqual(state?.phase, .watching)
    }

    func testTheCLIChatsContinueMessageGoesInWithTheSummarysStop() throws {
        surface = .cli
        terminal = CursorTerminal(kind: .tmux, pane: "%3", socket: "/private/tmp/tmux-501/default")
        _ = try askAndSend()
        XCTAssertEqual(state?.cursorChat?.terminal?.pane, "%3")
        typing.onSummarize = { [self] in call(.preCompact, trigger: "manual", contextTokens: 140_000) }
        XCTAssertNil(hold())
        XCTAssertEqual(typing.compacts.first?.surface, .cli)
        XCTAssertEqual(typing.typed, [], "nothing typed after /summarize in the CLI")
        XCTAssertEqual(state?.followUp?.stage, .continuing)

        // The CLI ends the summary with a stop of its own.
        turnNumber += 1
        XCTAssertEqual(call(.stop, tokens: 19_000, status: "completed"), .followUp(Config.defaultContinueMessage))
        XCTAssertEqual(state?.followUp?.stage, .done)
        XCTAssertNil(state?.waiterToken)
    }

    func testWithNothingToTypeThroughItWaitsForYouToCompact() throws {
        surface = .cli
        typing.reachNow = .never
        _ = try askAndSend()
        XCTAssertNil(hold())
        XCTAssertEqual(state?.followUp?.stage, .yours)
        XCTAssertEqual(state?.followUp?.note, "type /summarize in it")
        XCTAssertEqual(typing.compacts, [], "never typed")

        // You type /summarize; the summary's stop carries on.
        call(.preCompact, trigger: "manual", contextTokens: 141_000)
        XCTAssertEqual(state?.followUp?.stage, .continuing)
        XCTAssertNil(state?.followUp?.note, "what to type is past")
        turnNumber += 1
        XCTAssertEqual(call(.stop, tokens: 19_000, status: "completed"), .followUp(Config.defaultContinueMessage))
    }

    func testOnceTheChatIsOnScreenAgainItCompactsItItself() throws {
        typing.reachNow = .never
        _ = try askAndSend()
        typing.onSummarize = { [self] in call(.preCompact, trigger: "manual", contextTokens: 140_000) }
        // The chat's panel comes back while the hook waits.
        let typing = self.typing
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { typing.reachNow = .ready }
        XCTAssertNil(hold(3))
        XCTAssertEqual(typing.compacts.map(\.id), [id])
        XCTAssertEqual(state?.followUp?.stage, .done)
        XCTAssertNil(state?.followUp?.note, "no \"type /summarize in it\" left over")
    }

    func testWhileYoureUsingTheComputerItWaits() throws {
        _ = try askAndSend()
        typing.reachNow = .notNow
        XCTAssertNil(hold())
        XCTAssertEqual(typing.compacts, [])
        XCTAssertEqual(state?.followUp?.stage, .checking, "ready, waiting for a moment you aren't typing")
        XCTAssertEqual(state?.followUp?.verdict, .ready)
    }

    func testADraftInThePromptBoxPutsItOff() throws {
        _ = try askAndSend()
        typing.compactResult = .draft
        XCTAssertNil(hold())
        XCTAssertEqual(typing.compacts.count, 1, "looked again only after a while")
        XCTAssertNotNil(state?.cursorChat?.draftAt)
        XCTAssertEqual(state?.followUp?.compactAttempts, 0, "a draft isn't a failed try")
    }

    func testWithNoCursorCLIToJudgeYouAreAsked() throws {
        judge.reply = .failure(CursorJudgeFailure("the Cursor CLI isn't signed in: run cursor-agent login", asksYou: true))
        _ = try askAndSend()
        XCTAssertNil(hold())
        XCTAssertEqual(judge.prompts.count, 1, "not asked again")
        XCTAssertEqual(state?.followUp?.stage, .needsYou)
        XCTAssertEqual(state?.followUp?.note, "the Cursor CLI isn't signed in: run cursor-agent login")
        XCTAssertEqual(typing.compacts, [])
    }

    func testAJudgeThatDidntAnswerIsAskedAgainLater() throws {
        judge.reply = .failure(CursorJudgeFailure("Cursor's judge didn't answer in time"))
        _ = try askAndSend()
        XCTAssertNil(hold(0.5))
        XCTAssertEqual(state?.followUp?.judgeFailures, 1)
        XCTAssertNotNil(state?.followUp?.nextJudgeAt)
        XCTAssertNotEqual(state?.followUp?.stage, .needsYou)
        XCTAssertEqual(typing.compacts, [])
    }

    func testTypingThatFailsIsRecorded() throws {
        _ = try askAndSend()
        typing.compactResult = .failed("the chat's prompt box wasn't found")
        XCTAssertNil(hold(0.5))
        XCTAssertEqual(state?.cursorChat?.typingProblem, "the chat's prompt box wasn't found")
        XCTAssertGreaterThanOrEqual(state?.followUp?.compactAttempts ?? 0, 1)
    }

    // MARK: - The hold ends

    func testANewTurnEndsTheHold() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        let token = try XCTUnwrap(state?.waiterToken)
        let done = expectation(description: "the hold ends")
        let runner = self.runner, id = self.id, typing = self.typing, judge = self.judge, chats = self.chats
        DispatchQueue.global().async {
            XCTAssertNil(runner.hold(sessionId: id, token: token, maxDuration: 30, poll: 0.05, typing: typing, judge: judge,
                                     chats: chats))
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Next thing")
        wait(for: [done], timeout: 5)
    }

    func testCursorQuittingEndsTheHold() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        probe.set(appPid, nil)
        XCTAssertNil(hold(5))
        XCTAssertNil(state?.waiterToken, "the apps stop counting on it")
    }

    func testTheChatClosingEndsIt() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        call(.sessionEnd)
        XCTAssertEqual(state?.ended, true)
        XCTAssertNil(state?.waiterToken)
        turn("Back again", reply: "Hi", tokens: 101_000)
        XCTAssertEqual(state?.ended, false, "opened again")
    }

    /// Archiving a chat in the app runs no hook (Cursor 3.30): the hold finds it in Cursor's store.
    func testArchivingTheChatEndsIt() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        XCTAssertEqual(SessionCatalog.load(paths, registry: FakeRegistry(), probe: probe).first?.isLive, true)
        chats.now = .archived
        let started = Date()
        XCTAssertNil(hold(5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "its first look-up finds it")
        XCTAssertEqual(state?.ended, true)
        XCTAssertEqual(state?.endReason, "archived")
        XCTAssertNil(state?.waiterToken)
        XCTAssertEqual(SessionCatalog.load(paths, registry: FakeRegistry(), probe: probe).first?.isLive, false,
                       "it leaves the list")

        chats.now = .open
        turn("Back again", reply: "Hi", tokens: 101_000)
        XCTAssertEqual(state?.ended, false, "your next prompt in it opens it again")
        XCTAssertNil(state?.endReason)
    }

    func testDeletingTheChatWhileItWaitsEndsIt() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        standingEvery = 0.1
        let token = try XCTUnwrap(state?.waiterToken)
        let done = expectation(description: "the hold ends")
        let runner = self.runner, id = self.id, typing = self.typing, judge = self.judge, chats = self.chats
        DispatchQueue.global().async {
            XCTAssertNil(runner.hold(sessionId: id, token: token, maxDuration: 30, poll: 0.05, typing: typing, judge: judge,
                                     chats: chats))
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(state?.waiterToken, token, "still waiting while the chat is open")
        chats.now = .deleted
        wait(for: [done], timeout: 5)
        XCTAssertEqual(state?.ended, true)
        XCTAssertEqual(state?.endReason, "deleted")
    }

    func testTheHoldLooksTheChatUpNowAndThen() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        XCTAssertNil(hold(0.6))
        XCTAssertEqual(chats.asked, 1, "once, then every standingEvery (10 s), not every poll")
    }

    func testAStoreItCantReadKeepsTheChat() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        chats.now = nil
        XCTAssertNil(hold(0.3))
        XCTAssertEqual(state?.ended, false)
    }

    func testACLIChatIsNeverLookedUp() throws {
        try configure()
        surface = .cli
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        chats.now = .archived
        XCTAssertNil(hold(0.3))
        XCTAssertEqual(chats.asked, 0, "it ends when its cursor-agent does")
        XCTAssertEqual(state?.ended, false)
    }

    // MARK: - A turn's growth

    /// A step of the current turn that added `chars` characters, with Cursor's figure at `tokens`.
    @discardableResult
    func step(tokens: Int, chars: Int) -> CursorReply {
        var i = input(.postToolUse)
        i.stepChars = chars
        return runner.handle(i, look: look(tokens: tokens))
    }

    func testInTheAppATurnsStepsCountUntilItEnds() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Read the specs")
        // The app's figure stays where the last turn ended while two 40k-character files go in.
        step(tokens: 100_000, chars: 40_000)
        XCTAssertEqual(state?.tokens, 110_000)
        XCTAssertEqual(state?.phase, .watching)
        step(tokens: 100_000, chars: 40_000)
        XCTAssertEqual(state?.tokens, 120_000)
        XCTAssertEqual(state?.phase, .asking, "Ask at 60% acts mid-turn, not once the turn is over")
        call(.stop, tokens: 119_000, status: "completed")
        XCTAssertEqual(state?.tokens, 119_000, "at the turn's end Cursor's figure is the size")
        XCTAssertNil(state?.cursorChat?.charsSince)
        XCTAssertEqual(state?.phase, .asking)
    }

    func testWhenCursorsFigureMovesMidTurnTheCountStartsFromIt() throws {
        surface = .cli
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Read the specs")
        step(tokens: 100_000, chars: 8_000)
        XCTAssertEqual(state?.tokens, 102_000)
        step(tokens: 103_000, chars: 4_000)
        XCTAssertEqual(state?.tokens, 104_000, "the CLI's figure moved with the model call: only this step is on top")
    }

    func testWaitActsMidTurnInTheApp() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 130_000)
        XCTAssertEqual(state?.phase, .asking)
        try answer(.later)
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Read the specs")
        XCTAssertEqual(state?.phase, .later)
        XCTAssertEqual(step(tokens: 130_000, chars: 60_000), .none, "145k is below Wait at 80% (160k)")
        guard case .context(let text) = step(tokens: 130_000, chars: 64_000) else {
            return XCTFail("Wait acts mid-turn at 161k, though the app's figure is still 130k")
        }
        let nonce = try XCTUnwrap(state?.sentNonce)
        XCTAssertTrue(text.hasSuffix("[\(nonce)]"), text)
        XCTAssertEqual(state?.sentVia, .step)
    }

    func testASummaryStartsTheCountAgain() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        turnNumber += 1
        call(.beforeSubmitPrompt, prompt: "Read the specs")
        step(tokens: 100_000, chars: 40_000)
        call(.preCompact, trigger: "auto", contextTokens: 110_000)
        XCTAssertNil(state?.cursorChat?.charsSince)
        XCTAssertNil(state?.cursorChat?.sizeSeen)
        step(tokens: 30_000, chars: 4_000)
        XCTAssertEqual(state?.tokens, 31_000)
        XCTAssertEqual(state?.lastCompaction?.postTokens, 30_000, "what it came to is Cursor's figure")
    }

    func testAStepsCharactersAreItsInputAndWhatTheToolGaveBack() throws {
        func parse(_ fields: [String: Any]) throws -> CursorHookInput {
            var obj: [String: Any] = ["hook_event_name": "postToolUse", "conversation_id": id]
            obj.merge(fields) { $1 }
            return try XCTUnwrap(CursorHookInput.parse(JSONSerialization.data(withJSONObject: obj)))
        }
        // A file read gives only its length (Cursor 3.30).
        let read = try parse(["tool_name": "Read", "tool_input": ["path": "/a.md"],
                              "tool_output": #"{"file_path":"/Users/demo/code/a.md","content_length":60422}"#])
        XCTAssertEqual(read.stepChars, #"{"path":"/a.md"}"#.count + 60_422)
        let output = #"{"output":"total 8\nREADME.md\n","exitCode":0}"#
        let shell = try parse(["tool_name": "Shell", "tool_input": ["command": "ls"], "tool_output": output])
        XCTAssertEqual(shell.stepChars, #"{"command":"ls"}"#.count + output.utf16.count)
        XCTAssertNil(try parse(["status": "completed"]).stepChars, "not a step")
    }

    // MARK: - Settings and marks

    func testThresholdsAreSharesOfTheChatsWindow() {
        let c = Config()
        XCTAssertTrue(c.cursorThresholds() == (120_000, 160_000))
        var s = SessionState(sessionId: id, host: .cursor, now: clock.now)
        s.cursorChat = CursorFacts(window: 200_000)
        s.cursorChat?.autoCompactPercent = 85
        let r = c.resolved(for: s)
        XCTAssertEqual(r.laterAt, 150_000, "a tenth of the window below where Cursor summarized by itself")
        XCTAssertEqual(r.askAt, 120_000)
        var odd = Config()
        odd.cursorAskPercent = 95
        odd.cursorLaterPercent = 3
        XCTAssertEqual(odd.normalized.cursorAskPercent, 79)
        XCTAssertEqual(odd.normalized.cursorLaterPercent, 84)
    }

    func testAnAutoSummaryRecordsWhereCursorSummarizesByItself() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        call(.preCompact, trigger: "auto", contextTokens: 182_000)
        XCTAssertEqual(state?.cursorChat?.autoCompactPercent, nil, "no share given: nothing recorded")
        var input = input(.preCompact, trigger: "auto", contextTokens: 182_000)
        input.contextPercent = 91.2
        _ = runner.handle(input, look: look())
        XCTAssertEqual(state?.cursorChat?.autoCompactPercent, 91)
    }

    func testStoppingWatchingAChatIsKeyedToTheChat() throws {
        try configure()
        turn("Add a settings screen", reply: "Added it.", tokens: 100_000)
        let s = try XCTUnwrap(state)
        try Mute.set(true, for: s, paths, now: clock.now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cursorMuteFile(id).path))
        XCTAssertTrue(Mute.isMuted(s, paths))
        call(.sessionEnd)
        Mute.prune(paths, probe: probe)
        XCTAssertFalse(Mute.isMuted(s, paths), "the mark ends with the chat")
    }

    func testCursorsHooksLeaveOtherToolsSessionsAlone() throws {
        try configure()
        for host in [SessionHost.claude, .codex] {
            try? FileManager.default.removeItem(at: paths.stateFile(id))
            var s = SessionState(sessionId: id, host: host, now: clock.now)
            s.tokens = 150_000
            try s.save(paths)
            let before = try Data(contentsOf: paths.stateFile(id))
            for event in CursorEvent.allCases {
                XCTAssertEqual(call(event, tokens: 190_000), .none, "\(host): \(event)")
            }
            XCTAssertEqual(try Data(contentsOf: paths.stateFile(id)), before, "\(host): the file is untouched")
        }
    }
}
