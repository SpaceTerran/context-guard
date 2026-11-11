import ContextGuardCore
import Foundation

/// One WebSocket frame (RFC 6455 §5.2).
public struct WebSocketFrame: Equatable, Sendable {
    public static let continuation: UInt8 = 0x0
    public static let text: UInt8 = 0x1
    public static let binary: UInt8 = 0x2
    public static let close: UInt8 = 0x8
    public static let ping: UInt8 = 0x9
    public static let pong: UInt8 = 0xA

    public var fin: Bool
    public var opcode: UInt8
    /// Unmasked.
    public var payload: Data
    /// It came masked (only clients mask).
    public var masked: Bool

    public init(fin: Bool = true, opcode: UInt8, payload: Data, masked: Bool = false) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
        self.masked = masked
    }

    public var isControl: Bool { opcode & 0x8 != 0 }

    /// The frame as sent: masked with `mask` (a client's frames always are), or unmasked if nil.
    public func encoded(mask: [UInt8]?) -> Data {
        var out = Data()
        out.append((fin ? 0x80 : 0) | (opcode & 0x0F))
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        let n = payload.count
        if n <= 125 {
            out.append(maskBit | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
            }
        }
        guard let mask else {
            out.append(payload)
            return out
        }
        precondition(mask.count == 4)
        out.append(contentsOf: mask)
        var bytes = [UInt8](payload)
        for i in bytes.indices { bytes[i] ^= mask[i & 3] }
        out.append(contentsOf: bytes)
        return out
    }

    /// The first whole frame at the start of `buffer`, and how many bytes it took. nil if it hasn't
    /// all arrived yet.
    public static func decode(_ buffer: Data, maxPayload: Int) throws -> (frame: WebSocketFrame, length: Int)? {
        let s = buffer.startIndex
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[s], b1 = buffer[s + 1]
        guard b0 & 0x70 == 0 else { throw CodexLinkError.protocolError("reserved bits set") }
        let opcode = b0 & 0x0F
        guard [continuation, text, binary, close, ping, pong].contains(opcode) else {
            throw CodexLinkError.protocolError("unknown opcode \(opcode)")
        }
        let fin = b0 & 0x80 != 0
        let masked = b1 & 0x80 != 0
        var length = UInt64(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[s + 2]) << 8 | UInt64(buffer[s + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 0..<8 { length = length << 8 | UInt64(buffer[s + 2 + i]) }
            guard length >> 63 == 0 else { throw CodexLinkError.protocolError("length out of range") }
            offset = 10
        }
        if opcode & 0x8 != 0, !fin || length > 125 {
            throw CodexLinkError.protocolError("bad control frame")
        }
        guard length <= UInt64(maxPayload) else { throw CodexLinkError.tooLarge }
        var mask: [UInt8]?
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer[(s + offset)..<(s + offset + 4)])
            offset += 4
        }
        let total = offset + Int(length)
        guard buffer.count >= total else { return nil }
        var payload = Data(buffer[(s + offset)..<(s + total)])
        if let mask {
            var bytes = [UInt8](payload)
            for i in bytes.indices { bytes[i] ^= mask[i & 3] }
            payload = Data(bytes)
        }
        return (WebSocketFrame(fin: fin, opcode: opcode, payload: payload, masked: masked), total)
    }
}

/// A WebSocket client on an already connected stream, for the Codex app server's control socket.
/// One thread reads (`receive`); any thread may send.
public final class WebSocketClient: @unchecked Sendable {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// The app server's other path, `/daemon/shutdown`, stops it. Nothing else is ever opened.
    public static let path = "/"
    /// Large enough for any reply or notification the link sees (thread lists, models, config).
    public static let maxMessage = 32 << 20
    static let maxHeader = 16 << 10

    public let stream: SocketStream
    private let writeLock = NSLock()
    private var closeSent = false
    // Reader only.
    private var buffer = Data()
    private var partial = Data()
    private var partialOpcode: UInt8?

    init(stream: SocketStream) {
        self.stream = stream
    }

    /// Opens the WebSocket: `GET /`, checks the 101 reply and its accept key.
    public static func open(_ stream: SocketStream, host: String = "localhost", timeout: TimeInterval = 5) throws -> WebSocketClient {
        var random = SystemRandomNumberGenerator()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &random) }).base64EncodedString()
        let client = WebSocketClient(stream: stream)
        stream.setTimeouts(read: timeout, write: timeout)
        try stream.write(try request(path: path, host: host, key: key))
        var head = Data()
        while true {
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                try check(response: String(decoding: head[head.startIndex..<end.lowerBound], as: UTF8.self), key: key)
                client.buffer = Data(head[end.upperBound...])
                break
            }
            guard head.count <= maxHeader else { throw CodexLinkError.handshake("the reply's headers are too long") }
            let chunk: Data
            do {
                chunk = try stream.read(max: 4096)
            } catch let error as CodexLinkError where error.isTimeout {
                throw CodexLinkError.handshake("no reply")
            }
            guard !chunk.isEmpty else { throw CodexLinkError.handshake("the connection closed") }
            head.append(chunk)
        }
        // From here reads wait as long as it takes; a stuck write still gives up.
        stream.setTimeouts(read: 0, write: 10)
        return client
    }

    static func request(path: String, host: String, key: String) throws -> Data {
        guard path == Self.path else { throw CodexLinkError.forbiddenPath(path) }
        let lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func acceptValue(for key: String) -> String {
        Data(Digest.sha1(Data((key + guid).utf8))).base64EncodedString()
    }

    static func check(response head: String, key: String) throws {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), status[1] == "101" else {
            throw CodexLinkError.handshake("status \(lines.first ?? "missing")")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["upgrade"]?.lowercased() == "websocket" else { throw CodexLinkError.handshake("no websocket upgrade") }
        guard headers["connection"]?.lowercased().split(separator: ",")
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true else {
            throw CodexLinkError.handshake("no connection upgrade")
        }
        guard headers["sec-websocket-accept"] == acceptValue(for: key) else { throw CodexLinkError.handshake("wrong accept key") }
    }

    public func send(text: String) throws {
        try send(WebSocketFrame(opcode: WebSocketFrame.text, payload: Data(text.utf8)))
    }

    func send(_ frame: WebSocketFrame) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closeSent else { throw CodexLinkError.closed("the connection is closing") }
        var random = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255, using: &random) }
        try stream.write(frame.encoded(mask: mask))
        if frame.opcode == WebSocketFrame.close { closeSent = true }
    }

    /// The next message, or nil once the connection has closed. Answers pings itself.
    public func receive() throws -> String? {
        while true {
            if let (frame, used) = try WebSocketFrame.decode(buffer, maxPayload: Self.maxMessage) {
                buffer = Data(buffer.dropFirst(used))
                if let message = try take(frame) { return message }
                if frame.opcode == WebSocketFrame.close { return nil }
                continue
            }
            let chunk = try stream.read()
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    /// A whole message once `frame` completes one.
    private func take(_ frame: WebSocketFrame) throws -> String? {
        guard !frame.masked else { throw CodexLinkError.protocolError("a masked frame from the server") }
        switch frame.opcode {
        case WebSocketFrame.ping:
            try? send(WebSocketFrame(opcode: WebSocketFrame.pong, payload: frame.payload))
            return nil
        case WebSocketFrame.pong:
            return nil
        case WebSocketFrame.close:
            // Echo its status code, then the server closes the stream.
            try? send(WebSocketFrame(opcode: WebSocketFrame.close, payload: frame.payload.prefix(2)))
            return nil
        case WebSocketFrame.text, WebSocketFrame.binary:
            guard partialOpcode == nil else { throw CodexLinkError.protocolError("a new message inside a fragmented one") }
            if frame.fin { return try string(frame.payload) }
            partialOpcode = frame.opcode
            partial = frame.payload
            return nil
        default:
            guard partialOpcode != nil else { throw CodexLinkError.protocolError("a continuation with no message") }
            guard partial.count + frame.payload.count <= Self.maxMessage else { throw CodexLinkError.tooLarge }
            partial.append(frame.payload)
            guard frame.fin else { return nil }
            let whole = partial
            partial = Data()
            partialOpcode = nil
            return try string(whole)
        }
    }

    private func string(_ data: Data) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else { throw CodexLinkError.protocolError("text that isn't UTF-8") }
        return s
    }

    /// Says goodbye and ends the stream; a blocked `receive` returns nil.
    public func close(code: UInt16 = 1000) {
        try? send(WebSocketFrame(opcode: WebSocketFrame.close, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)])))
        stream.shutdown()
    }
}
