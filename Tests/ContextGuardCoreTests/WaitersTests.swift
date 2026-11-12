import XCTest
@testable import ContextGuardCore

/// `context-guard hook --stop`, which the installers run before removing Context Guard.
final class WaitersTests: HookTestCase {
    var me: Int32 { ProcessInfo.processInfo.processIdentifier }

    func testReleaseEndsTheWaiterAndNothingIsSentAfter() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        XCTAssertEqual(state?.phase, .asking)
        let result = startWaiter(token: token)

        let running = Waiters.release(paths, probe: probe)
        XCTAssertEqual(running, [Waiters.Running(sessionId: sid, pid: me, start: ProcessStart(seconds: 1, microseconds: 1))])
        // A yes now would have been sent by the waiter; it's gone, so nothing is.
        try answer(.yes)
        let out = try XCTUnwrap(result.wait(5))
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertNil(out.text)
        XCTAssertNil(state?.waiterToken)
        XCTAssertEqual(state?.phase, .asking, "the answer is left for the next hook, if Context Guard comes back")
        XCTAssertNil(state?.appliedAnswerId)
    }

    func testTheNextTurnAfterAReleaseStartsAWaiterAgain() {
        transcript.append(Line.context(310_000))
        guard case .wait(let first) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        _ = Waiters.release(paths, probe: probe)
        guard case .wait(let second) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(state?.waiterToken, second)
    }

    func testNothingWaitingReleasesNothing() throws {
        XCTAssertEqual(Waiters.release(paths, probe: probe), [], "no sessions folder yet")
        transcript.append(Line.context(310_000))
        guard case .wait = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        probe.set(me, nil)
        XCTAssertEqual(Waiters.release(paths, probe: probe), [], "its waiter isn't running")
        XCTAssertNil(state?.waiterToken, "but its token is cleared")
    }

    func testABusyLockLeavesTheWaiterAndReportsIt() throws {
        transcript.append(Line.context(310_000))
        guard case .wait(let token) = runner.handle(event("Stop")) else { return XCTFail("expected a waiter") }
        let lock = try XCTUnwrap(FileLock.acquire(paths.lockFile(sid), timeout: 1))
        defer { lock.release() }
        XCTAssertEqual(Waiters.release(paths, probe: probe, lockTimeout: 0.1).map(\.pid), [me])
        XCTAssertEqual(state?.waiterToken, token)
    }

    func testWaitReturnsTheOnesStillRunning() {
        let waiter = Waiters.Running(sessionId: sid, pid: claude, start: start)
        XCTAssertEqual(Waiters.wait(for: [waiter], timeout: 0.2, poll: 0.05, probe: probe), [waiter])
        probe.set(claude, nil)
        XCTAssertEqual(Waiters.wait(for: [waiter], timeout: 5, poll: 0.05, probe: probe), [])
        XCTAssertEqual(Waiters.wait(for: [], timeout: 5, probe: probe), [])
    }
}
