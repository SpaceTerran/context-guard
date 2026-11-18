import XCTest
@testable import ContextGuardCodexLink

final class CodexAppIPCTests: XCTestCase {
    // MARK: - Frames

    func testAFrameIsItsLittleEndianLengthThenItsJSON() throws {
        let frame = CodexAppIPC.frame(["a": 1])
        XCTAssertEqual(Array(frame.prefix(4)), [7, 0, 0, 0])
        XCTAssertEqual(String(decoding: frame.dropFirst(4), as: UTF8.self), #"{"a":1}"#)
    }

    func testFramesAreReadAsTheyArriveWhateverTheChunks() throws {
        var bytes = CodexAppIPC.frame(["n": 1])
        bytes.append(CodexAppIPC.frame(["n": 2]))
        bytes.append(CodexAppIPC.frame(["n": 3]))
        var reader = CodexAppFrameReader()
        var got: [JSONValue] = []
        // One byte at a time, then the rest in one go.
        for b in bytes.prefix(9) { got += try reader.append(Data([b])) }
        XCTAssertEqual(got, [])
        got += try reader.append(bytes.dropFirst(9))
        XCTAssertEqual(got, [["n": 1], ["n": 2], ["n": 3]])
    }

    func testAFrameThatIsNotJSONIsSkipped() throws {
        var bytes = Data([3, 0, 0, 0])
        bytes.append(Data("{{{".utf8))
        bytes.append(CodexAppIPC.frame(["ok": true]))
        var reader = CodexAppFrameReader()
        XCTAssertEqual(try reader.append(bytes), [["ok": true]])
    }

    func testAFrameOverTheLimitEndsTheReading() {
        var reader = CodexAppFrameReader()
        XCTAssertThrowsError(try reader.append(Data([0x01, 0x00, 0x00, 0x10]))) {
            XCTAssertEqual($0 as? CodexLinkError, .tooLarge)
        }
    }

    // MARK: - Messages (shapes as the Codex app 26.1111 sends them)

    func testResponsesCarryTheResultOrWhyNot() {
        XCTAssertEqual(CodexAppMessage(["type": "response", "requestId": "r1", "resultType": "success",
                                        "method": "initialize", "result": ["clientId": "c1"]]),
                       .response(requestId: "r1", result: .success(["clientId": "c1"])))
        XCTAssertEqual(CodexAppMessage(["type": "response", "requestId": "r2", "resultType": "error",
                                        "error": "no-client-found"]),
                       .response(requestId: "r2", result: .failure(.noOwner)))
        XCTAssertEqual(CodexAppMessage(["type": "response", "requestId": "r3", "resultType": "error",
                                        "error": "request-version-mismatch"]),
                       .response(requestId: "r3", result: .failure(.versionMismatch)))
        XCTAssertEqual(CodexAppMessage(["type": "response", "requestId": "r4", "resultType": "error",
                                        "error": "Cannot read properties of null (reading 'id')"]),
                       .response(requestId: "r4", result: .failure(.failed("Cannot read properties of null (reading 'id')"))))
    }

    func testBroadcastsAndDiscoveryRequests() {
        let b = CodexAppMessage([
            "type": "broadcast", "method": "thread-archived", "sourceClientId": "owner", "version": 2,
            "params": ["hostId": "local", "conversationId": "t1", "cwd": "/work/demo"],
        ])
        guard case .broadcast(let archived) = b else { return XCTFail("\(b)") }
        XCTAssertEqual(archived.method, "thread-archived")
        XCTAssertEqual(archived.conversationId, "t1")
        XCTAssertNil(archived.targets)
        XCTAssertFalse(archived.isUnknownVersion)

        let targeted = CodexAppMessage([
            "type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "owner", "version": 14,
            "targetClientIds": ["me"], "params": ["conversationId": "t1"],
        ])
        guard case .broadcast(let state) = targeted else { return XCTFail("\(targeted)") }
        XCTAssertEqual(state.targets, ["me"])
        XCTAssertTrue(state.isUnknownVersion, "13 is the version known")

        XCTAssertEqual(CodexAppMessage(["type": "client-discovery-request", "requestId": "d1", "request": [:]]),
                       .discoveryRequest(requestId: "d1"))
        XCTAssertEqual(CodexAppMessage(["type": "something-new"]), .other)
    }

    func testRequestsAreAddressedAndVersioned() {
        let r = CodexAppIPC.request(id: "r1", from: "me", .startTurn, params: ["x": 1], to: "owner", timeout: 10)
        XCTAssertEqual(r, ["type": "request", "requestId": "r1", "sourceClientId": "me", "version": 2,
                           "method": "thread-follower-start-turn", "params": ["x": 1], "timeoutMs": 10000,
                           "targetClientId": "owner"])
        XCTAssertNil(CodexAppIPC.request(id: "r2", from: "me", .ownerDiscovery, params: [:])["targetClientId"])
        XCTAssertEqual(CodexAppIPC.broadcast(from: "me", .followingChanged, params: CodexAppRequests.following("t1", true)),
                       ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "me",
                        "version": 1, "params": ["conversationId": "t1", "hostId": "local", "following": true]])
        XCTAssertEqual(CodexAppIPC.cannotHandle("d1"),
                       ["type": "client-discovery-response", "requestId": "d1", "response": ["canHandle": false]])
    }

    /// The params the spikes sent and the app carried out (S2, Mac and Windows).
    func testFollowerRequestParams() {
        XCTAssertEqual(CodexAppRequests.startTurn("t1", text: "Go on."), [
            "conversationId": "t1",
            "turnStart": ["request": ["threadId": "t1", "input": [["type": "text", "text": "Go on.", "text_elements": []]]],
                          "context": [:]],
        ])
        // The owner reads restoreMessage.id, .cwd and .context.workspaceRoots: null makes it throw.
        XCTAssertEqual(CodexAppRequests.steerTurn("t1", messageId: "m1", text: "Save now.", cwd: "/work/demo"), [
            "conversationId": "t1", "clientUserMessageId": "m1",
            "input": [["type": "text", "text": "Save now.", "text_elements": []]],
            "restoreMessage": ["id": "m1", "text": "Save now.", "cwd": "/work/demo",
                               "context": ["workspaceRoots": ["/work/demo"]]],
        ])
        XCTAssertEqual(CodexAppRequests.compact("t1"), ["conversationId": "t1"])
        XCTAssertEqual(CodexAppRequests.ownerDiscovery("t1"), ["hostId": "local", "conversationId": "t1"])
    }

    // MARK: - A followed chat's state

    static func snapshot(revision: Int, status: JSONValue = ["type": "idle"], tokens: Int = 18804) -> JSONValue {
        ["type": "snapshot", "revision": .number(Double(revision)), "conversationState": [
            "id": "t1", "title": "Demo chat", "cwd": "/work/demo", "latestModel": "gpt-6.2-sol", "source": "vscode",
            "threadSource": "user", "historyMode": "paginated", "threadRuntimeStatus": status,
            "latestTokenUsageInfo": ["total": ["totalTokens": 40000],
                                     "last": ["totalTokens": .number(Double(tokens)), "inputTokens": 18000],
                                     "modelContextWindow": 475000],
            "turnHistory": ["history": ["entitiesByKey": [:], "islands": []]],
        ]]
    }

    static func patches(_ base: Int, _ revision: Int, _ list: [JSONValue]) -> JSONValue {
        ["type": "patches", "baseRevision": .number(Double(base)), "revision": .number(Double(revision)),
         "patches": .array(list)]
    }

    func testASnapshotGivesSizeWindowStatusAndNames() {
        var s = CodexAppThreadState()
        XCTAssertFalse(s.isCurrent)
        XCTAssertEqual(s.apply(Self.snapshot(revision: 1)), .applied)
        XCTAssertTrue(s.isCurrent)
        XCTAssertEqual(s.status, "idle")
        XCTAssertEqual(s.tokens, 18804)
        XCTAssertEqual(s.window, 475000)
        XCTAssertEqual(s.title, "Demo chat")
        XCTAssertEqual(s.cwd, "/work/demo")
        XCTAssertEqual(s.model, "gpt-6.2-sol")
        XCTAssertEqual(s.source, "vscode")
        XCTAssertNil(s.fields["turnHistory"], "the turns aren't kept")
    }

    /// The order the Mac spike saw around a compaction: active, the usage, idle.
    func testPatchesMoveItAlong() {
        var s = CodexAppThreadState()
        _ = s.apply(Self.snapshot(revision: 1))
        XCTAssertEqual(s.apply(Self.patches(1, 3, [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "active", "activeFlags": []]],
            ["op": "add", "path": ["turnHistory", "history", "islands", 0], "value": ["entries": []]],
        ])), .applied)
        XCTAssertEqual(s.status, "active")
        XCTAssertEqual(s.apply(Self.patches(3, 7, [
            ["op": "replace", "path": ["latestTokenUsageInfo"],
             "value": ["last": ["totalTokens": 24334], "modelContextWindow": 475000]],
        ])), .applied)
        XCTAssertEqual(s.tokens, 24334)
        XCTAssertEqual(s.apply(Self.patches(7, 9, [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]],
            ["op": "replace", "path": ["latestTokenUsageInfo", "last", "totalTokens"], "value": 20113],
            ["op": "add", "path": ["threadRuntimeStatus", "activeFlags"], "value": ["waitingOnApproval"]],
        ])), .applied)
        XCTAssertEqual(s.status, "idle")
        XCTAssertEqual(s.tokens, 20113)
        XCTAssertEqual(s.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(s.revision, 9)
    }

    func testAMissedPatchDropsTheStateUntilTheNextSnapshot() {
        var s = CodexAppThreadState()
        _ = s.apply(Self.snapshot(revision: 1))
        XCTAssertEqual(s.apply(Self.patches(2, 3, [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "active"]],
        ])), .outOfStep)
        XCTAssertFalse(s.isCurrent)
        XCTAssertNil(s.status)
        XCTAssertNil(s.tokens)
        // Nothing is applied until a snapshot.
        XCTAssertEqual(s.apply(Self.patches(3, 4, [])), .outOfStep)
        XCTAssertEqual(s.apply(Self.snapshot(revision: 5, status: ["type": "active", "activeFlags": []])), .applied)
        XCTAssertEqual(s.status, "active")
    }

    func testAPatchThatDoesNotFitDropsTheState() {
        var s = CodexAppThreadState()
        _ = s.apply(Self.snapshot(revision: 1))
        XCTAssertEqual(s.apply(Self.patches(1, 2, [
            ["op": "replace", "path": ["latestTokenUsageInfo", "nowhere", "totalTokens"], "value": 1],
        ])), .outOfStep)
        XCTAssertFalse(s.isCurrent)
    }

    func testOtherChangesAreIgnored() {
        var s = CodexAppThreadState()
        XCTAssertEqual(s.apply(["type": "something-new"]), .ignored)
        XCTAssertEqual(s.apply(["type": "snapshot"]), .ignored)
    }

    func path(_ keys: JSONValue...) -> ArraySlice<JSONValue> { ArraySlice(keys) }

    func testPatchOperationsOnArraysAndObjects() {
        let a: JSONValue = ["xs": [1, 2, 3]]
        XCTAssertEqual(CodexAppThreadState.patch(a, "add", path("xs", 1), 9), ["xs": [1, 9, 2, 3]])
        XCTAssertEqual(CodexAppThreadState.patch(a, "add", path("xs", "-"), 9), ["xs": [1, 2, 3, 9]])
        XCTAssertEqual(CodexAppThreadState.patch(a, "replace", path("xs", 2), 9), ["xs": [1, 2, 9]])
        XCTAssertEqual(CodexAppThreadState.patch(a, "remove", path("xs", 0), nil), ["xs": [2, 3]])
        XCTAssertEqual(CodexAppThreadState.patch(a, "replace", path("xs", "length"), 1), ["xs": [1]])
        XCTAssertNil(CodexAppThreadState.patch(a, "replace", path("xs", 3), 9))
        XCTAssertNil(CodexAppThreadState.patch(a, "add", path("xs", 5), 9))
        XCTAssertEqual(CodexAppThreadState.patch(a, "remove", path("xs"), nil), [:])
        XCTAssertNil(CodexAppThreadState.patch(a, "move", path("xs"), nil))
    }

    // MARK: - The connection, against a fake router

    func testItJoinsAsksAndAnswersDiscoveryWithNo() throws {
        let router = try FakeRouter { message, router in
            switch message["method"]?.string {
            case "initialize":
                XCTAssertEqual(message["sourceClientId"]?.string, "initializing-client")
                XCTAssertEqual(message["params"]?["clientType"]?.string, "context-guard")
                router.reply(message, .success(["clientId": "cg-1"]))
            case "thread-owner-discovery":
                XCTAssertEqual(message["sourceClientId"]?.string, "cg-1")
                // Someone else's request, routed through discovery first.
                router.send(["type": "client-discovery-request", "requestId": "d1", "request": ["method": "x"]])
                router.reply(message, .failure("no-client-found"))
            case "thread-follower-compact-thread":
                XCTAssertEqual(message["targetClientId"]?.string, "owner-1")
                XCTAssertEqual(message["version"]?.int, 1)
                router.reply(message, .success(["ok": true]))
            default:
                break
            }
        }
        let events = AppEventLog()
        let connection = CodexAppConnection(transport: router.client, onEvent: { events.add($0) })
        XCTAssertEqual(try connection.start(timeout: 2), "cg-1")
        XCTAssertEqual(connection.clientId, "cg-1")

        XCTAssertThrowsError(try connection.request(.ownerDiscovery, params: CodexAppRequests.ownerDiscovery("t1"), timeout: 2)) {
            XCTAssertEqual($0 as? CodexAppError, .noOwner)
        }
        XCTAssertEqual(try connection.request(.compactThread, params: CodexAppRequests.compact("t1"), to: "owner-1", timeout: 2),
                       ["ok": true])
        XCTAssertTrue(router.waitFor { $0["type"]?.string == "client-discovery-response" && $0["requestId"]?.string == "d1"
                && $0["response"]?["canHandle"]?.bool == false })

        try connection.broadcast(.followingChanged, params: CodexAppRequests.following("t1", true))
        XCTAssertTrue(router.waitFor { $0["type"]?.string == "broadcast" && $0["sourceClientId"]?.string == "cg-1"
                && $0["params"]?["following"]?.bool == true })

        router.send(["type": "broadcast", "method": "thread-archived", "sourceClientId": "owner-1", "version": 2,
                     "params": ["hostId": "local", "conversationId": "t1", "cwd": "/work/demo"]])
        let got = events.wait(for: 1)
        guard case .broadcast(let b)? = got.first else { return XCTFail("\(got)") }
        XCTAssertEqual(b.method, "thread-archived")

        // The app quits: whatever is waiting fails, and the connection says it closed.
        router.close()
        XCTAssertEqual(events.wait(for: 2).count, 2)
        guard case .closed? = events.events.last else { return XCTFail("\(events.events)") }
        XCTAssertThrowsError(try connection.request(.compactThread, params: [:], timeout: 1)) {
            guard case .closed? = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
    }

    func testARequestNobodyAnswersTimesOut() throws {
        let router = try FakeRouter { message, router in
            if message["method"]?.string == "initialize" { router.reply(message, .success(["clientId": "cg-1"])) }
        }
        let connection = CodexAppConnection(transport: router.client, onEvent: { _ in })
        try connection.start(timeout: 2)
        let started = Date()
        XCTAssertThrowsError(try connection.request(.compactThread, params: [:], timeout: 0.2)) {
            XCTAssertEqual($0 as? CodexLinkError, .timeout("thread-follower-compact-thread"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        connection.close()
    }
}

/// Collects what an app connection reports.
final class AppEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CodexAppEvent] = []
    private let arrived = DispatchSemaphore(value: 0)

    func add(_ e: CodexAppEvent) {
        lock.lock()
        list.append(e)
        lock.unlock()
        arrived.signal()
    }

    var events: [CodexAppEvent] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    func wait(for count: Int, timeout: TimeInterval = 2) -> [CodexAppEvent] {
        let end = Date().addingTimeInterval(timeout)
        while events.count < count, Date() < end { _ = arrived.wait(timeout: .now() + 0.05) }
        return events
    }
}

/// The app's router, faked over a socket pair: `answer` gets each message Context Guard sends.
final class FakeRouter: @unchecked Sendable {
    let client: SocketStream
    private let server: SocketStream
    private let lock = NSLock()
    private var got: [JSONValue] = []

    init(answer: @escaping @Sendable (JSONValue, FakeRouter) -> Void) throws {
        let (client, server) = try SocketStream.pair()
        self.client = client
        self.server = server
        let thread = Thread { [self] in
            var reader = CodexAppFrameReader()
            while let data = try? server.read(), !data.isEmpty, let messages = try? reader.append(data) {
                for m in messages {
                    lock.lock()
                    got.append(m)
                    lock.unlock()
                    answer(m, self)
                }
            }
        }
        thread.start()
    }

    func send(_ message: JSONValue) {
        try? server.write(CodexAppIPC.frame(message))
    }

    func reply(_ request: JSONValue, _ result: Result<JSONValue, FakeRouterError>) {
        var r: [String: JSONValue] = ["type": "response", "requestId": request["requestId"] ?? .null,
                                      "method": request["method"] ?? .null, "handledByClientId": "owner-1"]
        switch result {
        case .success(let value):
            r["resultType"] = "success"
            r["result"] = value
        case .failure(let e):
            r["resultType"] = "error"
            r["error"] = .string(e.text)
        }
        send(.object(r))
    }

    var received: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return got
    }

    func waitFor(_ match: (JSONValue) -> Bool, timeout: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if received.contains(where: match) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    func close() {
        server.shutdown()
    }
}

struct FakeRouterError: Error, ExpressibleByStringLiteral {
    let text: String
    init(stringLiteral value: String) { text = value }
}
