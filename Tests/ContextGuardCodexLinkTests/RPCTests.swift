import XCTest
@testable import ContextGuardCodexLink

/// Collects what a connection reports.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CodexEvent] = []
    private let arrived = DispatchSemaphore(value: 0)

    func add(_ e: CodexEvent) {
        lock.lock()
        list.append(e)
        lock.unlock()
        arrived.signal()
    }

    var events: [CodexEvent] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    /// Waits for `count` events in all.
    func wait(for count: Int, timeout: TimeInterval = 2) -> [CodexEvent] {
        let end = Date().addingTimeInterval(timeout)
        while events.count < count, Date() < end { _ = arrived.wait(timeout: .now() + 0.05) }
        return events
    }
}

/// A JSON-RPC connection to a fake app server whose replies `answer` makes.
final class RPCPair: @unchecked Sendable {
    let rpc: RPCConnection
    let server: FakeServer
    let events = EventLog()
    private let lock = NSLock()
    private var got: [JSONValue] = []

    /// `answer` gets each message the client sent and returns the messages to send back.
    init(answer: @escaping @Sendable (JSONValue) -> [JSONValue]) throws {
        let (client, server) = try FakeServer.connected()
        self.server = server
        let events = self.events
        rpc = RPCConnection(socket: client, onEvent: { events.add($0) })
        rpc.start()
        let thread = Thread { [self] in
            while let text = try? server.text(), let message = try? JSONValue.parse(text) {
                lock.lock()
                got.append(message)
                lock.unlock()
                for reply in answer(message) { try? server.send(text: reply.text) }
            }
        }
        thread.start()
    }

    var received: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return got
    }

    static func result(for message: JSONValue, _ result: JSONValue) -> JSONValue {
        ["id": message["id"] ?? .null, "result": result]
    }
}

final class RPCTests: XCTestCase {
    func testACallGetsItsResult() throws {
        let pair = try RPCPair { m in [RPCPair.result(for: m, ["echo": m["params"] ?? .null])] }
        let result = try pair.rpc.call("thread/read", ["threadId": "t1"], timeout: 2)
        XCTAssertEqual(result["echo"]?["threadId"]?.string, "t1")
        let sent = try XCTUnwrap(pair.received.first)
        XCTAssertEqual(sent["method"]?.string, "thread/read")
        XCTAssertEqual(sent["id"]?.int, 1)
        XCTAssertNil(sent["jsonrpc"], "the app server's dialect has no jsonrpc field")
        _ = try pair.rpc.call("thread/read", ["threadId": "t2"], timeout: 2)
        XCTAssertEqual(pair.received.last?["id"]?.int, 2)
    }

    func testAnErrorIsARefusal() throws {
        let pair = try RPCPair { m in
            [["id": m["id"] ?? .null, "error": ["code": -32600, "message": "Invalid request: unknown variant `thread/queue/add`, expected one of …"]]]
        }
        XCTAssertThrowsError(try pair.rpc.call("thread/queue/add", [:], timeout: 2)) {
            let e = $0 as? CodexLinkError
            XCTAssertEqual(e?.isRefusal, true)
            XCTAssertEqual(e?.isMissingMethod, true)
            guard case .rpc(let code, _) = e else { return XCTFail("\($0)") }
            XCTAssertEqual(code, -32600)
        }
    }

    func testNoReplyInTimeIsNotARefusal() throws {
        let pair = try RPCPair { m in
            // The first is answered too late, the second at once.
            if m["id"]?.int == 1 {
                Thread.sleep(forTimeInterval: 0.4)
            }
            return [RPCPair.result(for: m, ["n": m["id"] ?? .null])]
        }
        XCTAssertThrowsError(try pair.rpc.call("thread/compact/start", [:], timeout: 0.2)) {
            XCTAssertEqual($0 as? CodexLinkError, .timeout("thread/compact/start"))
            XCTAssertEqual(($0 as? CodexLinkError)?.isRefusal, false)
        }
        // The late reply to 1 is dropped; 2 gets its own.
        XCTAssertEqual(try pair.rpc.call("thread/read", [:], timeout: 2)["n"]?.int, 2)
    }

    func testRepliesInAnyOrderReachTheirCalls() throws {
        let held = HeldReplies()
        let pair = try RPCPair { m in held.take(m) }
        let group = DispatchGroup()
        let results = Results()
        for i in 0..<8 {
            DispatchQueue.global().async(group: group) {
                let r = try? pair.rpc.call("echo", ["i": .number(Double(i))], timeout: 5)
                results.set(i, r?["i"]?.int)
            }
        }
        // All eight in, then answered last first.
        XCTAssertTrue(held.waitFor(8))
        for m in held.all.reversed() { try pair.server.send(text: RPCPair.result(for: m, ["i": m["params"]?["i"] ?? .null]).text) }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.all, Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, $0) }))
    }

    func testNotificationsAndRequestsFromTheServerAreEvents() throws {
        let pair = try RPCPair { _ in [] }
        try pair.server.send(text: #"{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"active"}}}"#)
        try pair.server.send(text: #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"t9"}}"#)
        try pair.server.send(text: "not json")
        try pair.server.send(text: #"{"method":"thread/closed","params":{"threadId":"t1"}}"#)
        let events = pair.events.wait(for: 3)
        XCTAssertEqual(events, [
            .notification(method: "thread/status/changed", params: ["threadId": "t1", "status": ["type": "active"]]),
            .request(method: "item/commandExecution/requestApproval", params: ["threadId": "t9"]),
            .notification(method: "thread/closed", params: ["threadId": "t1"]),
        ], "something unreadable is skipped")
    }

    func testANotificationHasNoId() throws {
        let pair = try RPCPair { _ in [] }
        try pair.rpc.notify("initialized", nil)
        try pair.rpc.notify("x", ["a": 1])
        let deadline = Date().addingTimeInterval(2)
        while pair.received.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(pair.received, [["method": "initialized"], ["method": "x", "params": ["a": 1]]])
    }

    func testTheServerHangingUpFailsWhatWaitsAndWhatComesAfter() throws {
        let pair = try RPCPair { _ in [] }
        let failed = expectation(description: "the waiting call failed")
        DispatchQueue.global().async {
            do {
                _ = try pair.rpc.call("thread/read", [:], timeout: 5)
                XCTFail("expected it to fail")
            } catch CodexLinkError.closed {
            } catch {
                XCTFail("\(error)")
            }
            failed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        pair.server.stream.close()
        wait(for: [failed], timeout: 2)
        guard case .closed = pair.events.wait(for: 1).last else { return XCTFail("expected .closed") }
        XCTAssertThrowsError(try pair.rpc.call("thread/read", [:], timeout: 2)) {
            guard case .closed = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
    }

    func testClosingEndsTheConnection() throws {
        let pair = try RPCPair { _ in [] }
        pair.rpc.close()
        guard case .closed = pair.events.wait(for: 1).last else { return XCTFail("expected .closed") }
        XCTAssertThrowsError(try pair.rpc.call("thread/read", [:], timeout: 1))
    }

    func testTheHandshake() throws {
        let pair = try RPCPair { m in
            m["method"]?.string == "initialize" ? [RPCPair.result(for: m, ["userAgent": "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)"])] : []
        }
        XCTAssertEqual(try pair.rpc.initialize(version: "1", timeout: 2), "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)")
        let deadline = Date().addingTimeInterval(2)
        while pair.received.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let hello = try XCTUnwrap(pair.received.first)
        XCTAssertEqual(hello["params"]?["clientInfo"]?["name"]?.string, "context_guard")
        XCTAssertEqual(hello["params"]?["capabilities"]?["experimentalApi"]?.bool, true)
        XCTAssertEqual(pair.received.last, ["method": "initialized"])
    }
}

/// Requests held until a test answers them.
final class HeldReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [JSONValue] = []

    func take(_ m: JSONValue) -> [JSONValue] {
        lock.lock()
        list.append(m)
        lock.unlock()
        return []
    }

    var all: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    func waitFor(_ n: Int) -> Bool {
        let end = Date().addingTimeInterval(5)
        while all.count < n { if Date() > end { return false }; Thread.sleep(forTimeInterval: 0.01) }
        return true
    }
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [Int: Int] = [:]

    func set(_ i: Int, _ v: Int?) {
        lock.lock(); defer { lock.unlock() }
        map[i] = v
    }

    var all: [Int: Int] {
        lock.lock(); defer { lock.unlock() }
        return map
    }
}
