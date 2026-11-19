#if os(Windows)
import ContextGuardCore
import Foundation
import WinSDK
import XCTest
@testable import ContextGuardCodexLink

/// The Codex app's router on Windows, faked: a pipe this process serves, one instance, read and
/// written in plain I/O from the test.
final class TestPipeServer {
    let name = #"\\.\pipe\context-guard-test-"# + UUID().uuidString
    private var handle: HANDLE?

    init(instances: Int = 1) throws {
        let h = name.withCString(encodedAs: UTF16.self) {
            CreateNamedPipeW($0, DWORD(PIPE_ACCESS_DUPLEX), DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT),
                             DWORD(instances), 65_536, 65_536, 0, nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { throw CodexLinkError.connect(Int32(bitPattern: GetLastError())) }
        handle = h
    }

    /// Once a client has opened it.
    func accept() {
        guard let handle, !ConnectNamedPipe(handle, nil) else { return }
        XCTAssertEqual(GetLastError(), DWORD(ERROR_PIPE_CONNECTED))
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)
        var wrote: DWORD = 0
        XCTAssertTrue(WriteFile(handle, &bytes, DWORD(bytes.count), &wrote, nil))
        XCTAssertEqual(Int(wrote), bytes.count)
    }

    func read(_ count: Int) -> String {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: count)
        while out.count < count {
            var got: DWORD = 0
            guard ReadFile(handle, &buffer, DWORD(count - out.count), &got, nil), got > 0 else { break }
            out += buffer.prefix(Int(got))
        }
        return String(decoding: out, as: UTF8.self)
    }

    func close() {
        guard let h = handle else { return }
        handle = nil
        DisconnectNamedPipe(h)
        CloseHandle(h)
    }

    deinit { close() }
}

/// A value one thread sets and another reads.
final class Handoff<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

final class NamedPipeStreamTests: XCTestCase {
    func connected() throws -> (TestPipeServer, NamedPipeStream) {
        let server = try TestPipeServer()
        let client = try NamedPipeStream.connect(server.name)
        server.accept()
        return (server, client)
    }

    /// Reads on a thread of its own, as the connection's reader does.
    func readInBackground(_ client: NamedPipeStream) -> (done: DispatchSemaphore, result: Handoff<Result<Data, Error>>) {
        let done = DispatchSemaphore(value: 0)
        let result = Handoff<Result<Data, Error>>()
        Thread {
            result.value = Result { try client.read() }
            done.signal()
        }.start()
        return (done, result)
    }

    func testBytesGoBothWays() throws {
        let (server, client) = try connected()
        try client.write(Data("hello".utf8))
        XCTAssertEqual(server.read(5), "hello")
        server.write("world")
        XCTAssertEqual(String(decoding: try client.read(), as: UTF8.self), "world")
        client.close()
    }

    func testAReadWaitingForTheRouterDoesntHoldUpAWrite() throws {
        let (server, client) = try connected()
        let reading = readInBackground(client)
        Thread.sleep(forTimeInterval: 0.2)
        let wrote = DispatchSemaphore(value: 0)
        Thread {
            try? client.write(Data("ping".utf8))
            wrote.signal()
        }.start()
        XCTAssertEqual(wrote.wait(timeout: .now() + 5), .success, "the write went through while the read waited")
        XCTAssertEqual(server.read(4), "ping")
        server.write("pong")
        XCTAssertEqual(reading.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try reading.result.value?.get(), Data("pong".utf8))
        client.close()
    }

    func testShutdownEndsAWaitingReadAndFurtherWrites() throws {
        // The router stays: only the shutdown ends the read.
        let (server, client) = try connected()
        defer { withExtendedLifetime(server) {} }
        let reading = readInBackground(client)
        Thread.sleep(forTimeInterval: 0.2)
        client.shutdown()
        XCTAssertEqual(reading.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try reading.result.value?.get(), Data(), "reads as the end of the stream")
        XCTAssertThrowsError(try client.write(Data("late".utf8)))
        XCTAssertEqual(try client.read(), Data())
        client.close()
        client.close()
    }

    func testTheRouterClosingEndsTheStream() throws {
        let (server, client) = try connected()
        let reading = readInBackground(client)
        server.close()
        XCTAssertEqual(reading.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try reading.result.value?.get(), Data())
        XCTAssertThrowsError(try client.write(Data("gone".utf8)))
        client.close()
    }

    func testNobodyServingThePipe() {
        XCTAssertThrowsError(try NamedPipeStream.connect(#"\\.\pipe\context-guard-test-none-"# + UUID().uuidString)) {
            XCTAssertEqual($0 as? CodexLinkError, .connect(Int32(ERROR_FILE_NOT_FOUND)))
        }
    }

    func testEveryInstanceTakenIsWaitedForAWhile() throws {
        let (server, first) = try connected()
        let started = Date()
        XCTAssertThrowsError(try NamedPipeStream.connect(server.name, wait: 0.3)) {
            XCTAssertEqual($0 as? CodexLinkError, .connect(Int32(ERROR_PIPE_BUSY)))
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        first.close()
    }

    func testTheServerIsThisProcessAndYours() throws {
        // Asked while the router still serves the pipe.
        let (server, client) = try connected()
        defer { withExtendedLifetime(server) {} }
        let me = GetCurrentProcessId()
        XCTAssertEqual(client.serverProcessId, UInt32(me))
        XCTAssertTrue(WindowsProcess.isYours(UInt32(me)))
        XCTAssertFalse(WindowsProcess.isYours(0))
        let program = try XCTUnwrap(WindowsProcess.executable(UInt32(me)))
        XCTAssertTrue(program.lowercased().hasSuffix(".exe"), program)
        XCTAssertTrue(FileManager.default.fileExists(atPath: program))
        client.close()
    }

    func testTheConnectorJoinsARouterOfYours() throws {
        let server = try TestPipeServer()
        let router = try CodexAppPipeConnector(pipe: server.name).connect()
        server.accept()
        XCTAssertEqual(router.hostExecutable, WindowsProcess.executable(UInt32(GetCurrentProcessId())))
        try router.transport.write(Data("hi".utf8))
        XCTAssertEqual(server.read(2), "hi")
        router.transport.close()
    }

    func testTheConnectorWithNoApp() {
        XCTAssertThrowsError(try CodexAppPipeConnector(pipe: #"\\.\pipe\context-guard-test-none-"# + UUID().uuidString).connect())
        XCTAssertEqual(CodexAppPipeConnector().pipe, #"\\.\pipe\codex-ipc"#)
    }

    func testTheInstalledAppIsLookedUpWithoutFailing() {
        // The CI machine has no Codex app; a family nobody has gives nothing either way.
        XCTAssertNil(WindowsProcess.packageFolder(family: "ContextGuard.NoSuchPackage_0000000000000"))
    }
}
#endif
