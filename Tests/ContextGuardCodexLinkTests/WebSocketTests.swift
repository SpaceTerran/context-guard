import XCTest
@testable import ContextGuardCodexLink

final class WebSocketFrameTests: XCTestCase {
    func payload(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }) }

    func testFramesRoundTripAtEachLengthBoundary() throws {
        // The length takes 1, 3 or 9 bytes; a mask adds 4.
        let header = [0: 2, 1: 2, 125: 2, 126: 4, 127: 4, 65_535: 4, 65_536: 10, 70_000: 10]
        for (n, size) in header.sorted(by: { $0.key < $1.key }) {
            for mask in [nil, [UInt8(0x37), 0xFA, 0x21, 0x3D]] {
                let frame = WebSocketFrame(opcode: WebSocketFrame.binary, payload: payload(n))
                let bytes = frame.encoded(mask: mask)
                XCTAssertEqual(bytes.count, size + (mask == nil ? 0 : 4) + n, "length \(n)")
                let (decoded, used) = try XCTUnwrap(try WebSocketFrame.decode(bytes, maxPayload: 1 << 20), "length \(n)")
                XCTAssertEqual(used, bytes.count)
                XCTAssertEqual(decoded.payload, frame.payload, "length \(n)")
                XCTAssertEqual(decoded.opcode, WebSocketFrame.binary)
                XCTAssertTrue(decoded.fin)
                XCTAssertEqual(decoded.masked, mask != nil)
                // Anything short of the whole frame waits for more: every cut through the header,
                // and the last bytes of the payload.
                let cuts = n <= 127 ? Array(0..<bytes.count) : Array(0..<20) + Array((bytes.count - 3)..<bytes.count)
                for k in cuts {
                    XCTAssertNil(try WebSocketFrame.decode(bytes.prefix(k), maxPayload: 1 << 20), "length \(n), \(k) bytes")
                }
            }
        }
    }

    func testAMaskedPayloadIsSentScrambled() throws {
        let frame = WebSocketFrame(opcode: WebSocketFrame.text, payload: Data("hello".utf8))
        let bytes = frame.encoded(mask: [1, 2, 3, 4])
        let scrambled: [UInt8] = [0x68 ^ 1, 0x65 ^ 2, 0x6C ^ 3, 0x6C ^ 4, 0x6F ^ 1]
        XCTAssertEqual(Array(bytes), [0x81, 0x85, 1, 2, 3, 4] + scrambled)
        XCTAssertEqual(Array(frame.encoded(mask: nil)), [0x81, 0x05] + Array("hello".utf8))
    }

    func testAFrameMidBufferAndTheOneAfterIt() throws {
        let one = WebSocketFrame(fin: false, opcode: WebSocketFrame.text, payload: Data("hel".utf8))
        let two = WebSocketFrame(opcode: WebSocketFrame.continuation, payload: Data("lo".utf8))
        let all = Data([0xEE]) + one.encoded(mask: nil) + two.encoded(mask: nil)
        // A slice that doesn't start at 0, as the reader's buffer can be.
        let rest = all.dropFirst()
        let (first, used) = try XCTUnwrap(try WebSocketFrame.decode(rest, maxPayload: 100))
        XCTAssertEqual(first, one)
        XCTAssertFalse(first.fin)
        let (second, _) = try XCTUnwrap(try WebSocketFrame.decode(rest.dropFirst(used), maxPayload: 100))
        XCTAssertEqual(second, two)
    }

    func testFramesNoServerMaySend() {
        func fails(_ bytes: [UInt8], max: Int = 1 << 20, _ why: String) {
            XCTAssertThrowsError(try WebSocketFrame.decode(Data(bytes), maxPayload: max), why)
        }
        fails([0xC1, 0x00], "a reserved bit")
        fails([0x83, 0x00], "an unknown opcode")
        fails([0x09, 0x00], "a control frame in pieces")
        fails([0x89, 0x7E, 0x00, 0x7E] + [UInt8](repeating: 0, count: 126), "a control frame over 125 bytes")
        fails([0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0], "a 64-bit length with its top bit set")
        XCTAssertThrowsError(try WebSocketFrame.decode(Data([0x82, 0x0B] + [UInt8](repeating: 0, count: 11)), maxPayload: 10)) {
            XCTAssertEqual($0 as? CodexLinkError, .tooLarge)
        }
        // Too large is known from the header alone.
        XCTAssertThrowsError(try WebSocketFrame.decode(Data([0x82, 0x7F, 0, 0, 0, 1, 0, 0, 0, 0]), maxPayload: 1 << 20)) {
            XCTAssertEqual($0 as? CodexLinkError, .tooLarge)
        }
    }
}

final class WebSocketClientTests: XCTestCase {
    func testTheAcceptKeyIsTheRFCsOwnExample() {
        XCTAssertEqual(WebSocketClient.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testOnlyTheRootPathIsEverOpened() throws {
        XCTAssertThrowsError(try WebSocketClient.request(path: "/daemon/shutdown", host: "localhost", key: "k")) {
            XCTAssertEqual($0 as? CodexLinkError, .forbiddenPath("/daemon/shutdown"))
        }
        XCTAssertThrowsError(try WebSocketClient.request(path: "", host: "localhost", key: "k"))
        let request = String(decoding: try WebSocketClient.request(path: "/", host: "localhost", key: "abc=="), as: UTF8.self)
        XCTAssertEqual(request, "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: abc==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    }

    func testAMessageEachWay() throws {
        let (client, server) = try FakeServer.connected()
        XCTAssertTrue(server.request.hasPrefix("GET / HTTP/1.1\r\nHost: localhost\r\n"))
        let key = try XCTUnwrap(server.request.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") })
        XCTAssertEqual(Data(base64Encoded: String(key.dropFirst("Sec-WebSocket-Key: ".count)))?.count, 16)

        try client.send(text: #"{"id":1}"#)
        XCTAssertEqual(try server.text(), #"{"id":1}"#, "masked, as a client must")
        try server.send(text: "héllo")
        XCTAssertEqual(try client.receive(), "héllo")
    }

    func testBytesThatCameWithTheReplyAreKept() throws {
        let (a, b) = try SocketStream.pair()
        let server = FakeServer(b)
        let frame = WebSocketFrame(opcode: WebSocketFrame.text, payload: Data("first".utf8)).encoded(mask: nil)
        DispatchQueue.global().async { try? server.handshake(reply: FakeServer.accepting, extra: frame) }
        let client = try WebSocketClient.open(a, timeout: 2)
        XCTAssertEqual(try client.receive(), "first")
    }

    func testPiecesAreJoinedAndPingsAnsweredOnTheWay() throws {
        let (client, server) = try FakeServer.connected()
        try server.send(WebSocketFrame(fin: false, opcode: WebSocketFrame.text, payload: Data("hel".utf8)))
        try server.send(WebSocketFrame(opcode: WebSocketFrame.ping, payload: Data("p1".utf8)))
        try server.send(WebSocketFrame(fin: false, opcode: WebSocketFrame.continuation, payload: Data("l".utf8)))
        try server.send(WebSocketFrame(opcode: WebSocketFrame.pong, payload: Data()))
        try server.send(WebSocketFrame(opcode: WebSocketFrame.continuation, payload: Data("o".utf8)))
        XCTAssertEqual(try client.receive(), "hello")
        let pong = try XCTUnwrap(try server.frame())
        XCTAssertEqual(pong.opcode, WebSocketFrame.pong)
        XCTAssertEqual(pong.payload, Data("p1".utf8))
        XCTAssertTrue(pong.masked)
    }

    func testAMessageInsideAnotherOrAPieceOfNothingFails() throws {
        let (client, server) = try FakeServer.connected()
        try server.send(WebSocketFrame(fin: false, opcode: WebSocketFrame.text, payload: Data("a".utf8)))
        try server.send(WebSocketFrame(opcode: WebSocketFrame.text, payload: Data("b".utf8)))
        XCTAssertThrowsError(try client.receive())

        let (client2, server2) = try FakeServer.connected()
        try server2.send(WebSocketFrame(opcode: WebSocketFrame.continuation, payload: Data("a".utf8)))
        XCTAssertThrowsError(try client2.receive())
    }

    func testTheServersCloseIsEchoedAndEndsIt() throws {
        let (client, server) = try FakeServer.connected()
        try server.send(WebSocketFrame(opcode: WebSocketFrame.close, payload: Data([0x03, 0xE9, 0x62, 0x79, 0x65])))
        XCTAssertNil(try client.receive())
        let echo = try XCTUnwrap(try server.frame())
        XCTAssertEqual(echo.opcode, WebSocketFrame.close)
        XCTAssertEqual(echo.payload, Data([0x03, 0xE9]), "its status code only")
        XCTAssertThrowsError(try client.send(text: "late"), "nothing after a close")
    }

    func testClosingEndsAReceiveThatIsWaiting() throws {
        let (client, server) = try FakeServer.connected()
        let ended = expectation(description: "receive returned")
        DispatchQueue.global().async {
            XCTAssertNil(try? client.receive())
            ended.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        client.close()
        wait(for: [ended], timeout: 2)
        let bye = try XCTUnwrap(try server.frame())
        XCTAssertEqual(bye.opcode, WebSocketFrame.close)
        XCTAssertEqual(bye.payload, Data([0x03, 0xE8]))
        XCTAssertNil(try server.frame(), "then the stream ends")
    }

    func testTheServerHangingUpEndsIt() throws {
        let (client, server) = try FakeServer.connected()
        server.stream.close()
        XCTAssertNil(try client.receive())
    }

    func testAMaskedFrameFromTheServerFails() throws {
        let (client, server) = try FakeServer.connected()
        try server.send(WebSocketFrame(opcode: WebSocketFrame.text, payload: Data("x".utf8)), mask: [9, 9, 9, 9])
        XCTAssertThrowsError(try client.receive()) {
            guard case .protocolError = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
    }

    func testTextThatIsntUTF8Fails() throws {
        let (client, server) = try FakeServer.connected()
        try server.send(WebSocketFrame(opcode: WebSocketFrame.text, payload: Data([0xFF, 0xFE])))
        XCTAssertThrowsError(try client.receive())
    }

    func testRepliesThatArentAnUpgradeFail() throws {
        func refused(_ reply: @escaping @Sendable (String) -> String) -> String? {
            do {
                _ = try FakeServer.connected(reply: reply)
                return nil
            } catch CodexLinkError.handshake(let why) {
                return why
            } catch {
                return "\(error)"
            }
        }
        XCTAssertEqual(refused { _ in "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n" }, "status HTTP/1.1 403 Forbidden")
        XCTAssertEqual(refused { _ in
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        }, "wrong accept key")
        XCTAssertEqual(refused { key in
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketClient.acceptValue(for: key))\r\n\r\n"
        }, "no websocket upgrade")
        XCTAssertEqual(refused { key in
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: WebSocket\r\nconnection: keep-alive, Upgrade\r\nsec-websocket-accept: \(WebSocketClient.acceptValue(for: key))\r\n\r\n"
        }, nil, "header names and values in any case")
    }

    func testNoReplyGivesUp() throws {
        let (a, b) = try SocketStream.pair()
        let started = Date()
        XCTAssertThrowsError(try WebSocketClient.open(a, timeout: 0.3)) {
            XCTAssertEqual($0 as? CodexLinkError, .handshake("no reply"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        withExtendedLifetime(b) {}
    }

    func testAServerThatHangsUpInsteadOfReplying() throws {
        let (a, b) = try SocketStream.pair()
        DispatchQueue.global().async {
            _ = try? b.read()
            b.close()
        }
        XCTAssertThrowsError(try WebSocketClient.open(a, timeout: 2)) {
            XCTAssertEqual($0 as? CodexLinkError, .handshake("the connection closed"))
        }
    }

    func testASocketPathTooLongForTheAddress() {
        let long = "/" + String(repeating: "a", count: SocketStream.maxPathBytes)
        XCTAssertThrowsError(try SocketStream.connect(unixPath: long)) {
            XCTAssertEqual($0 as? CodexLinkError, .socketPathTooLong(long))
        }
        XCTAssertThrowsError(try SocketStream.connect(unixPath: "/nonexistent/app-server-control.sock")) {
            guard case .connect = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
    }
}
