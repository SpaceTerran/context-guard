import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

/// Reading Claude Code's registry status with the mod's turn record: mid-turn, or between turns
/// with or without work left running in the background.
final class ActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_100)
    let start = ProcessStart(seconds: 1_790_000_000, microseconds: 500_000)

    func activity(_ status: String?, turn: TurnRecord? = nil, agents: Int = 0) -> SessionActivity {
        SessionActivity.of(RegistryEntry(pid: 1, status: status), turn: turn, processStart: start, agents: agents, now: now)
    }

    func ended(_ secondsAgo: TimeInterval) -> TurnRecord { TurnRecord(active: false, at: now.addingTimeInterval(-secondsAgo)) }

    func testTheRegistrysOwnWords() {
        XCTAssertEqual(activity("idle"), .idle)
        XCTAssertEqual(activity("shell", agents: 1), .background(BackgroundWork(agents: 1, shells: true)))
        XCTAssertEqual(activity("waiting", turn: ended(60)), .busy, "a permission prompt or dialog is part of a turn")
        XCTAssertEqual(activity("something-newer", turn: ended(60)), .busy, "what it can't read, it doesn't wake")
    }

    func testAClaudeCodeThatWritesNoStatusCountsAsIdle() {
        XCTAssertEqual(activity(nil), .idle)
        XCTAssertEqual(SessionActivity.of(nil, turn: nil, processStart: start, now: now), .idle)
    }

    func testBusyIsATurnUnlessTheTurnRecordSaysItEnded() {
        XCTAssertEqual(activity("busy"), .busy, "no record: a mod from before turn records, or none")
        XCTAssertEqual(activity("busy", turn: TurnRecord(active: true, at: now.addingTimeInterval(-600))), .busy)
        XCTAssertEqual(activity("busy", turn: ended(60), agents: 2), .background(BackgroundWork(agents: 2)))
        XCTAssertEqual(activity("busy", turn: ended(60)), .background(BackgroundWork()),
                       "work the mod can't count (a workflow, a teammate) still holds")
    }

    func testATurnThatJustEndedHasToSettleFirst() {
        XCTAssertEqual(activity("busy", turn: ended(1)), .busy)
        XCTAssertEqual(activity("busy", turn: ended(2)), .background(BackgroundWork()))
    }

    func testARecordFromAnEarlierRunOfTheSessionDoesNotCount() {
        let before = TurnRecord(active: false, at: Date(timeIntervalSince1970: 1_789_999_999))
        XCTAssertEqual(activity("busy", turn: before), .busy)
        // The state file keeps whole seconds: a turn that ended in the process's first second counts.
        let sameSecond = TurnRecord(active: false, at: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(activity("busy", turn: sameSecond), .background(BackgroundWork()))
    }

    func testOnlyAMidTurnSessionIsUnsafeToWake() {
        XCTAssertTrue(SessionActivity.idle.isBetweenTurns)
        XCTAssertTrue(SessionActivity.background(BackgroundWork(agents: 1)).isBetweenTurns)
        XCTAssertFalse(SessionActivity.busy.isBetweenTurns)
        XCTAssertEqual(SessionActivity.background(BackgroundWork(shells: true)).background, BackgroundWork(shells: true))
        XCTAssertNil(SessionActivity.idle.background)
    }

    func testTheTurnRecordHasAFileOfItsOwn() throws {
        let dir = TempDir()
        let paths = Paths(root: dir.file("home"), claudeDir: dir.file("claude"))
        XCTAssertNil(TurnRecord.load("s1", paths))
        let record = TurnRecord(active: true, at: now)
        try record.save(for: "s1", paths)
        XCTAssertEqual(TurnRecord.load("s1", paths), record)
        XCTAssertEqual(paths.turnFile("s1").deletingLastPathComponent(), paths.turnsDir)
    }
}
