import Foundation
@testable import ContextGuardCodexLink

/// The app server's end of a socket pair: answers the WebSocket handshake, then sends and reads
/// frames the way a server does (its own unmasked, the client's masked).
final class FakeServer: @unchecked Sendable {
    let stream: SocketStream
    private var buffer = Data()
    /// The handshake request it got.
    private(set) var request = ""

    init(_ stream: SocketStream) {
        self.stream = stream
        stream.setTimeouts(read: 5, write: 5)
    }

    /// A client and server, the handshake done (the server's reply made by `reply`).
    static func connected(reply: @escaping @Sendable (_ key: String) -> String = FakeServer.accepting) throws -> (WebSocketClient, FakeServer) {
        let (a, b) = try SocketStream.pair()
        let server = FakeServer(b)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? server.handshake(reply: reply)
            done.signal()
        }
        defer { done.wait() }
        return (try WebSocketClient.open(a, timeout: 2), server)
    }

    @Sendable static func accepting(_ key: String) -> String {
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocketClient.acceptValue(for: key))\r\n\r\n"
    }

    func handshake(reply: (String) -> String, extra: Data = Data()) throws {
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try stream.read()
            guard !chunk.isEmpty else { throw CodexLinkError.closed("client went away") }
            buffer.append(chunk)
        }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!
        request = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        let key = request.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
            .map { String($0.dropFirst("sec-websocket-key:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        try stream.write(Data(reply(key).utf8) + extra)
    }

    func send(_ frame: WebSocketFrame, mask: [UInt8]? = nil) throws {
        try stream.write(frame.encoded(mask: mask))
    }

    func send(text: String) throws {
        try send(WebSocketFrame(opcode: WebSocketFrame.text, payload: Data(text.utf8)))
    }

    /// The client's next frame. nil once it hung up.
    func frame() throws -> WebSocketFrame? {
        while true {
            if let (frame, used) = try WebSocketFrame.decode(buffer, maxPayload: 1 << 24) {
                buffer = Data(buffer.dropFirst(used))
                return frame
            }
            let chunk = try stream.read()
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    /// The client's next message as text, after checking it came masked.
    func text() throws -> String? {
        guard let f = try frame() else { return nil }
        guard f.masked, f.opcode == WebSocketFrame.text else { throw CodexLinkError.protocolError("expected a masked text frame") }
        return String(decoding: f.payload, as: UTF8.self)
    }
}
