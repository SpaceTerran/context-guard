import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCodexLink

final class SocketStreamTests: XCTestCase {
    func testBytesGoBothWays() throws {
        let (a, b) = try SocketStream.pair()
        try a.write(Data("ping".utf8))
        XCTAssertEqual(try b.read(), Data("ping".utf8))
        try b.write(Data("pong".utf8))
        XCTAssertEqual(try a.read(), Data("pong".utf8))
        a.close()
        XCTAssertEqual(try b.read(), Data(), "end of stream once the other end closes")
    }

    func testShutdownEndsABlockedRead() throws {
        let (a, b) = try SocketStream.pair()
        let ended = expectation(description: "the read ended")
        DispatchQueue.global().async {
            if (try? a.read()) == Data() { ended.fulfill() }
        }
        Thread.sleep(forTimeInterval: 0.2)
        a.shutdown()
        wait(for: [ended], timeout: 2)
        withExtendedLifetime(b) {}
    }

    func testAReadGivesUpAfterItsTimeout() throws {
        let (a, b) = try SocketStream.pair()
        a.setTimeouts(read: 0.2, write: 1)
        let started = Date()
        XCTAssertThrowsError(try a.read()) { XCTAssertTrue(($0 as? CodexLinkError)?.isTimeout == true, "\($0)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        withExtendedLifetime(b) {}
    }

    func testErrorsSayWhatHappened() {
        XCTAssertFalse(SocketStream.message(for: SocketStream.brokenPipe).isEmpty)
        XCTAssertFalse(CodexLinkError.connect(SocketStream.brokenPipe).description.contains("error \(SocketStream.brokenPipe)"))
    }
}

final class CodexLinkStopTests: XCTestCase {
    func testOneStopPerContextGuardFolder() {
        let a = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cg-a")
        let b = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cg-b")
        XCTAssertEqual(CodexLinkStop.eventName(for: a), CodexLinkStop.eventName(for: a))
        XCTAssertNotEqual(CodexLinkStop.eventName(for: a), CodexLinkStop.eventName(for: b))
        XCTAssertTrue(CodexLinkStop.eventName(for: a).hasPrefix("Local\\ContextGuard.CodexLink.Stop."))
    }

    #if os(Windows)
    func testTheWindowsStopIsCaseBlind() {
        XCTAssertEqual(CodexLinkStop.eventName(for: URL(fileURLWithPath: "C:\\Users\\X\\.claude\\context-guard")),
                       CodexLinkStop.eventName(for: URL(fileURLWithPath: "c:/users/x/.claude/context-guard/")))
    }

    func testARequestStopsTheLinkForThatFolder() throws {
        let dir = TempDir()
        let other = TempDir()
        XCTAssertFalse(CodexLinkStop.request(for: dir.url), "nothing running")
        let stopped = expectation(description: "stopped")
        let listener = try XCTUnwrap(CodexLinkStop.Listener(root: dir.url) { stopped.fulfill() })
        XCTAssertFalse(CodexLinkStop.request(for: other.url), "another folder's link")
        XCTAssertTrue(CodexLinkStop.request(for: dir.url))
        wait(for: [stopped], timeout: 2)
        listener.stopped()
    }
    #endif
}
