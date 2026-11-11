import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

final class EngineTests: XCTestCase {
    let config = Config()
    let now = Date()

    func answer(_ s: SessionState, _ action: Answer.Action, source: Answer.Source = .popup, cycle: Int? = nil) -> Answer {
        Answer(cycle: cycle ?? s.cycle, action: action, source: source, at: now)
    }

    func testAsksOnceAGuardedSessionReachesTheThreshold() {
        var s = SessionState.guarded(299_999)
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .watching)
        s.tokens = 300_000
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .asking)
        XCTAssertEqual(s.cycle, 1)
        XCTAssertEqual(s.askedTokens, 300_000)
    }

    func testUnguardedSessionsAreOnlyTracked() {
        var s = SessionState.guarded(400_000)
        s.guarded = false
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .watching)
        s.phase = .queued
        XCTAssertNil(Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-x", now: now))
    }

    func testOffDoesNotAskAndOnAgainDoes() {
        var s = SessionState.guarded(320_000)
        var off = config
        off.enabled = false
        Engine.advance(&s, config: off, now: now)
        XCTAssertEqual(s.phase, .watching)
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testYesSendsOnceWithTheMessageAndTag() {
        var s = SessionState.guarded(310_000)
        Engine.advance(&s, config: config, now: now)
        Engine.apply(answer(s, .yes), to: &s)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.sendReason, .yes)
        let text = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-1234", now: now)
        XCTAssertEqual(text, "Context Guard (a Claude Code hook the user installed to watch context size) is relaying a message the user chose to send: they clicked Yes on its popup when this session reached 310k tokens. Their message: \u{201C}\(Config.defaultMessage)\u{201D} [cg-1234]")
        XCTAssertEqual(s.phase, .sent)
        XCTAssertEqual(s.sentVia, .step)
        XCTAssertNil(Engine.claimDelivery(&s, via: .wake, config: config, nonce: "cg-5678", now: now))
    }

    func testWaitSendsAutomaticallyAtTheLaterThreshold() {
        var s = SessionState.guarded(310_000)
        Engine.advance(&s, config: config, now: now)
        Engine.apply(answer(s, .later), to: &s)
        XCTAssertEqual(s.phase, .later)
        s.tokens = 499_999
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .later)
        s.tokens = 500_000
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.sendReason, .later)
    }

    func testWaitAnsweredAfterTheLaterThresholdSendsRightAway() {
        var s = SessionState.guarded(310_000)
        Engine.advance(&s, config: config, now: now)
        s.tokens = 520_000
        Engine.apply(answer(s, .later), to: &s)
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .queued)
    }

    func testAnswersForAnOldCycleOrAlreadyAppliedAreIgnored() {
        var s = SessionState.guarded(310_000, phase: .asking, cycle: 3)
        Engine.apply(answer(s, .yes, cycle: 2), to: &s)
        XCTAssertEqual(s.phase, .asking)

        let a = answer(s, .later)
        Engine.apply(a, to: &s)
        XCTAssertEqual(s.phase, .later)
        s.phase = .asking
        Engine.apply(a, to: &s)
        XCTAssertEqual(s.phase, .asking, "the same answer applies once")
    }

    func testNotNowStopsAskingUntilCompaction() {
        var s = SessionState.guarded(520_000, phase: .asking, cycle: 1)
        Engine.apply(answer(s, .skip), to: &s)
        XCTAssertEqual(s.phase, .skipped)
        s.tokens = 600_000
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .skipped)

        Engine.compacted(&s, trigger: "manual", preTokens: 600_000, postTokens: 30_000, now: now)
        XCTAssertEqual(s.phase, .watching)
        s.tokens = 305_000
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .asking)
        XCTAssertEqual(s.cycle, 2)
    }

    func testCompactionRecordsWhatItInterrupted() {
        var s = SessionState.guarded(450_000, phase: .later, cycle: 1)
        var r = TranscriptReading()
        r.latest = .compaction(trigger: "auto", preTokens: 453_000, postTokens: 25_000)
        r.compaction = r.latest
        Engine.observe(&s, r, config: config, now: now)
        XCTAssertEqual(s.phase, .watching)
        XCTAssertEqual(s.tokens, 25_000)
        XCTAssertEqual(s.lastCompaction?.trigger, "auto")
        XCTAssertEqual(s.lastCompaction?.preTokens, 453_000)
        XCTAssertEqual(s.lastCompaction?.interruptedPhase, .later)
    }

    func testCompactionAfterTheSaveMessageInterruptsNothing() {
        var s = SessionState.guarded(320_000, phase: .sent, cycle: 1)
        Engine.compacted(&s, trigger: "manual", preTokens: nil, postTokens: 20_000, now: now)
        XCTAssertNil(s.lastCompaction?.interruptedPhase)
        XCTAssertEqual(s.lastCompaction?.preTokens, 320_000)
    }

    func testSmallDipsDontReArmButALargeDropDoes() {
        var s = SessionState.guarded(320_000, phase: .sent, cycle: 1)
        Engine.observe(&s, .tokens(260_000), config: config, now: now)
        XCTAssertEqual(s.phase, .sent, "idle tool-result clearing shrinks context a little")
        Engine.observe(&s, .tokens(140_000), config: config, now: now)
        XCTAssertEqual(s.phase, .watching)
    }

    func testPassingTheLaterThresholdWhileOffAsksAgainInsteadOfSending() {
        var s = SessionState.guarded(510_000, phase: .later, cycle: 1)
        var off = config
        off.enabled = false
        Engine.advance(&s, config: off, now: now)
        XCTAssertEqual(s.phase, .asking)
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testAYesGivenStillGoesOutWhileOff() {
        var s = SessionState.guarded(310_000, phase: .asking, cycle: 1)
        var off = config
        off.enabled = false
        Engine.apply(answer(s, .yes), to: &s)
        Engine.advance(&s, config: off, now: now)
        XCTAssertNotNil(Engine.claimDelivery(&s, via: .wake, config: off, nonce: "cg-1", now: now))
    }

    func testDeliveryIsConfirmedByItsTagInTheTranscript() {
        var s = SessionState.guarded(310_000, phase: .queued, cycle: 1)
        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-abc", now: now)
        var r = TranscriptReading()
        r.markersSeen = ["cg-other"]
        Engine.observe(&s, r, config: config, now: now)
        XCTAssertNil(s.confirmedAt)
        r.markersSeen = ["cg-abc"]
        Engine.observe(&s, r, config: config, now: now)
        XCTAssertNotNil(s.confirmedAt)
    }

    func testAnUnconfirmedSendIsQueuedOnceMoreAfterTwoStops() {
        var s = SessionState.guarded(310_000, phase: .queued, cycle: 1)
        s.sendReason = .yes
        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-1", now: now)
        Engine.noteStop(&s)
        XCTAssertEqual(s.phase, .sent)
        Engine.noteStop(&s)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.sendReason, .yes)

        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-2", now: now)
        Engine.noteStop(&s)
        Engine.noteStop(&s)
        XCTAssertEqual(s.phase, .sent, "only one retry")
    }

    func testAManualSendBelowTheThresholdStillAsksAtTheThreshold() {
        var s = SessionState.guarded(150_000)
        Engine.apply(answer(s, .yes, source: .menu), to: &s)
        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-1", now: now)
        s.tokens = 305_000
        Engine.advance(&s, config: config, now: now)
        XCTAssertEqual(s.phase, .asking)
    }

    func testCompactNowFarBelowTheThresholdIsNotTakenForAReset() {
        // Compact Now at 40k, with the question at 300k: nothing fell, so nothing starts over.
        var s = SessionState.guarded(40_000)
        Engine.apply(answer(s, .yes, source: .menu), to: &s)
        Engine.observe(&s, .tokens(40_000), config: config, now: now)
        XCTAssertEqual(s.phase, .queued)
        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-1", now: now)
        var r = TranscriptReading.tokens(41_000)
        r.markersSeen = ["cg-1"]
        Engine.observe(&s, r, config: config, now: now)
        XCTAssertEqual(s.phase, .sent)
        XCTAssertEqual(s.sendReason, .manual)
        XCTAssertNotNil(s.confirmedAt, "it showed up")
        Engine.observe(&s, .tokens(30_000), config: config, now: now)
        XCTAssertEqual(s.phase, .sent, "a small dip")
        Engine.observe(&s, .tokens(19_000), config: config, now: now)
        XCTAssertEqual(s.phase, .watching, "under half of where it was sent: a rewind, so it starts over")
    }

    func testCompactNowWhileAskingIsStillCompactNow() {
        var s = SessionState.guarded(310_000, phase: .asking, cycle: 1)
        Engine.apply(answer(s, .yes, source: .menu), to: &s)
        XCTAssertEqual(s.sendReason, .manual, "so it compacts even if Context Guard is turned off")
        var popup = SessionState.guarded(310_000, phase: .asking, cycle: 1)
        Engine.apply(answer(popup, .yes), to: &popup)
        XCTAssertEqual(popup.sendReason, .yes)
    }

    func testYesWhileASendIsInFlightIsNotRepeated() {
        var s = SessionState.guarded(310_000, phase: .asking, cycle: 1)
        Engine.apply(answer(s, .yes), to: &s)
        _ = Engine.claimDelivery(&s, via: .step, config: config, nonce: "cg-1", now: now)
        Engine.apply(answer(s, .yes, source: .menu), to: &s)
        XCTAssertEqual(s.phase, .sent)
        XCTAssertEqual(s.sentNonce, "cg-1")
    }

    func testConfigNormalizesBadValues() {
        let c = Config(enabled: true, askAt: 0, laterAt: 10, message: "  ").normalized
        XCTAssertEqual(c.askAt, 1_000)
        XCTAssertEqual(c.laterAt, 101_000)
        XCTAssertEqual(c.message, Config.defaultMessage)
    }

    /// Settings says "Saved" only when the file reads back with the change in it.
    func testSavingSettingsReadsThemBack() throws {
        let dir = TempDir()
        let paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        var c = Config()
        c.message = "Save your work.\nThen reply Ready."
        c.continueMessage = "  "
        // A time with a fraction of a second: the file keeps whole seconds, which still counts as saved.
        c.setEnabled(true, now: Date(timeIntervalSince1970: 1_790_000_000.75))
        XCTAssertNil(c.saveConfirmed(paths))
        let back = Config.load(paths)
        XCTAssertEqual(back.message, "Save your work.\nThen reply Ready.")
        XCTAssertEqual(back.continueMessage, Config.defaultContinueMessage, "an empty message saves as the default")
    }

    func testSavingSettingsSaysWhyItCouldNot() throws {
        let dir = TempDir()
        let paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        XCTAssertNil(Config().saveConfirmed(paths))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.root.path) }
        var c = Config()
        c.continueMessage = "go on"
        let problem = try XCTUnwrap(c.saveConfirmed(paths))
        XCTAssertFalse(problem.isEmpty)
        XCTAssertEqual(Config.load(paths).continueMessage, Config.defaultContinueMessage, "the file is unchanged")
    }

    func testConfigWithMissingKeysUsesDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"enabled":false,"askAt":"oops"}"#.utf8))
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.askAt, Config.defaultAskAt)
        XCTAssertEqual(c.laterAt, Config.defaultLaterAt)
    }

    func testTokenFormatting() {
        XCTAssertEqual(Format.tokens(950), "950")
        XCTAssertEqual(Format.tokens(299_999), "299k")
        XCTAssertEqual(Format.tokens(302_517), "302k")
        XCTAssertEqual(Format.tokens(1_000_000), "1M")
        XCTAssertEqual(Format.tokens(1_250_000), "1.2M")
    }

    func testSessionIdsMustBeSafeFileNames() {
        XCTAssertTrue(Paths.isValidSessionID("3f2a9c1e-7b4d-4e8a-9c6f-0d1e2b3a4c5d"))
        XCTAssertFalse(Paths.isValidSessionID("../../etc"))
        XCTAssertFalse(Paths.isValidSessionID(""))
        XCTAssertFalse(Paths.isValidSessionID("é"))
    }
}
