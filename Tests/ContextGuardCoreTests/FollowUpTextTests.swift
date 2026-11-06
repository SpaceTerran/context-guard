import XCTest
@testable import ContextGuardCore

/// What the menu and the notices say about a follow-up.
final class FollowUpTextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func followUp(_ stage: FollowUp.Stage, note: String? = nil, at: Date? = nil) -> FollowUp {
        var f = FollowUp(nonce: "cg-1", now: at ?? now)
        f.stage = stage
        f.note = note
        f.tokensBefore = 312_400
        f.tokensAfter = 24_100
        return f
    }

    func line(_ f: FollowUp) -> String? { FollowUpText.line(f, continueMessage: "continue now", now: now) }

    func testEachStageReadsAsASentence() {
        XCTAssertEqual(line(followUp(.checking)), "Compacts once it's done saving")
        XCTAssertEqual(line(followUp(.working, note: "Waiting on CI for the opened PR.")), "Still saving: Waiting on CI for the opened PR")
        XCTAssertEqual(line(followUp(.needsYou, note: "Asked whether to merge")), "Needs you before compacting: Asked whether to merge")
        XCTAssertEqual(line(followUp(.draft)), "Compacts once the prompt box is empty")
        XCTAssertEqual(line(followUp(.compacting)), "Compacting…")
        XCTAssertEqual(line(followUp(.continuing)), "Compacted 312k → 24k · sends “continue now” when it's idle")
        XCTAssertEqual(line(followUp(.done)), "Compacted 312k → 24k and sent “continue now”")
        XCTAssertEqual(line(followUp(.tookOver)), "Compacted 312k → 24k · you took over, so “continue now” wasn't sent")
        XCTAssertEqual(line(followUp(.stopped, note: "you stopped watching this session")), "Didn't compact: you stopped watching this session")
        XCTAssertEqual(line(followUp(.failed, note: "Haiku didn't answer (timed out)")), "Couldn't compact by itself: Haiku didn't answer (timed out)")
    }

    /// Compacting worked and only the continue message failed: it says so, not "couldn't compact".
    func testAContinueThatFailedAfterCompactingSaysItCompacted() {
        var f = followUp(.failed, note: "something is typed in the prompt box")
        f.compactedAt = now
        XCTAssertEqual(line(f), "Compacted 312k → 24k · couldn't send “continue now”: something is typed in the prompt box")
        let n = FollowUpText.notice(f, continueMessage: "continue now")
        XCTAssertEqual(n?.title, "Compacted 312k → 24k")
        XCTAssertEqual(n?.reason, "Couldn't send “continue now”: something is typed in the prompt box")
    }

    func testUnknownSizesAndMissingReasonsAreLeftOut() {
        var f = followUp(.done)
        f.tokensAfter = nil
        XCTAssertEqual(line(f), "Compacted and sent “continue now”")
        XCTAssertEqual(line(followUp(.working, note: "  ")), "Still saving")
    }

    func testAFinishedFollowUpLeavesTheMenuAfterHalfAnHour() {
        XCTAssertNotNil(line(followUp(.done, at: now.addingTimeInterval(-29 * 60))))
        XCTAssertNil(line(followUp(.done, at: now.addingTimeInterval(-31 * 60))))
        XCTAssertNotNil(line(followUp(.needsYou, at: now.addingTimeInterval(-3_600))), "one still going stays")
    }

    func testOnlyWhatYouShouldKnowRaisesANotice() {
        let raising = FollowUp.Stage.allCases.filter { FollowUpText.notice(followUp($0), continueMessage: "go") != nil }
        XCTAssertEqual(raising, [.needsYou, .compacting, .done, .tookOver, .failed])
        let done = FollowUpText.notice(followUp(.done), continueMessage: "continue now")
        XCTAssertEqual(done?.title, "Compacted 312k → 24k")
        XCTAssertEqual(done?.reason, "Then sent “continue now”")
        let needs = FollowUpText.notice(followUp(.needsYou, note: "Asked which branch."), continueMessage: "go")
        XCTAssertEqual(needs?.reason, "Asked which branch")
        let failed = FollowUpText.notice(followUp(.failed, note: "compacting didn't go through after 3 tries"), continueMessage: "go")
        XCTAssertEqual(failed?.reason, "Compacting didn't go through after 3 tries", "a line of its own starts with a capital")
        XCTAssertGreaterThan(needs?.seconds ?? 0, 8, "it waits on you, so it stays up longer")
    }

    func testEachNoticeIsColoredByWhatItMeans() {
        func tone(_ stage: FollowUp.Stage, compacted: Bool = false) -> FollowUpText.Tone? {
            var f = followUp(stage, note: "x")
            f.compactedAt = compacted ? now : nil
            return FollowUpText.notice(f, continueMessage: "go")?.tone
        }
        XCTAssertEqual(tone(.needsYou), .warning)
        XCTAssertEqual(tone(.compacting), .accent)
        XCTAssertEqual(tone(.done, compacted: true), .success)
        XCTAssertEqual(tone(.tookOver, compacted: true), .success)
        XCTAssertEqual(tone(.failed, compacted: true), .warning, "it compacted; only the continue message didn't go in")
        XCTAssertEqual(tone(.failed), .danger)
    }
}
