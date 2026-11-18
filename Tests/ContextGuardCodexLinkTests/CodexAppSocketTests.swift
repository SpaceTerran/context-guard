import XCTest
@testable import ContextGuardCodexLink
import ContextGuardCore

#if !os(Windows)
final class CodexAppSocketTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCodexsFolderIsCodexHomeElseDotCodex() {
        XCTAssertEqual(CodexHome.path(["CODEX_HOME": "/work/demo/codex-home"]), "/work/demo/codex-home")
        XCTAssertEqual(CodexHome.path(["CODEX_HOME": "~/codex-home"]), NSHomeDirectory() + "/codex-home")
        XCTAssertEqual(CodexHome.path(["CODEX_HOME": ""]), FileManager.default.homeDirectoryForCurrentUser.path + "/.codex")
        XCTAssertEqual(CodexSocketConnector.defaultSocketPath(["CODEX_HOME": "/work/demo/codex-home"]),
                       "/work/demo/codex-home/app-server-control/app-server-control.sock")
    }

    func testTheRouterIsInCodexsFolderWhenThePathFits() {
        XCTAssertEqual(CodexAppSocketConnector.socketPath(codexHome: "/work/demo/.codex", uid: 501),
                       "/work/demo/.codex/ipc/ipc.sock")
        XCTAssertEqual(CodexAppSocketConnector.socketPath(codexHome: "/work/demo/.codex/", uid: 501),
                       "/work/demo/.codex/ipc/ipc.sock")
    }

    func testALongPathGoesThroughALinkInTmpNamedAfterTheFolder() {
        // 104 bytes and more don't fit a socket address on the Mac. The folder isn't there, so its
        // path is named as given: sha256("/work/demo/aaa…a/ipc").
        let home = "/work/demo/" + String(repeating: "a", count: 100)
        XCTAssertEqual(CodexAppSocketConnector.socketPath(codexHome: home, uid: 501),
                       "/tmp/codex-ipc-501/125ffdabfe7cd2140d20a293e06e225bcb5962eec409de2754e60902bbaea6c0/ipc.sock")
        // 103 bytes still fit.
        let fits = "/w/" + String(repeating: "b", count: 103 - "/w/".utf8.count - "/ipc/ipc.sock".utf8.count)
        XCTAssertEqual(CodexAppSocketConnector.socketPath(codexHome: fits, uid: 501), fits + "/ipc/ipc.sock")
    }

    func testTheLinkIsNamedAfterTheFoldersRealPath() throws {
        // The temporary folder is under /var, a link to /private/var: the app names the link after
        // where the folder really is.
        let home = dir.appendingPathComponent(String(repeating: "c", count: 90), isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        let real = try XCTUnwrap(CodexAppSocketConnector.realPath(home.appendingPathComponent("ipc").path))
        XCTAssertNotEqual(real, home.appendingPathComponent("ipc").path)
        XCTAssertEqual(CodexAppSocketConnector.socketPath(codexHome: home.path, uid: 501),
                       "/tmp/codex-ipc-501/\(Digest.hex(Digest.sha256(Data(real.utf8))))/ipc.sock")
    }

    func testEarlierAppsListenedInTheTemporaryFolder() {
        XCTAssertEqual(CodexAppSocketConnector.legacySocketPath(temporaryDirectory: "/var/folders/xy/T/", uid: 501),
                       "/var/folders/xy/T/codex-ipc/ipc-501.sock")
    }

    func testConnectsToTheRouterAndKnowsWhichProgramRunsIt() throws {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        let connector = CodexAppSocketConnector(codexHome: home.path, temporaryDirectory: dir.path)
        let listener = try SocketListener(path: connector.socketPaths[0])
        defer { listener.close() }
        let accepted = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var server: SocketStream?
        Thread {
            server = try? listener.accept()
            accepted.signal()
        }.start()

        let router = try connector.connect()
        defer { router.transport.close() }
        XCTAssertEqual(accepted.wait(timeout: .now() + 2), .success)
        // This test process is the one listening.
        XCTAssertEqual(router.hostExecutable, CodexAppSocketConnector.executable(getpid()))
        XCTAssertNotNil(router.hostExecutable)
        try router.transport.write(Data("hi".utf8))
        XCTAssertEqual(try server?.read(), Data("hi".utf8))
        server?.close()
    }

    func testTheLegacyPlaceIsTriedWhenNothingAnswersInCodexsFolder() throws {
        let connector = CodexAppSocketConnector(codexHome: dir.appendingPathComponent("home").path, temporaryDirectory: dir.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("codex-ipc"), withIntermediateDirectories: true)
        let listener = try SocketListener(path: connector.socketPaths[1])
        defer { listener.close() }
        Thread { _ = try? listener.accept() }.start()
        let router = try connector.connect()
        router.transport.close()
    }

    func testNoAppIsAnErrorEvenWithAFileLeftWhereTheSocketWas() throws {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        let connector = CodexAppSocketConnector(codexHome: home.path, temporaryDirectory: dir.path)
        XCTAssertThrowsError(try connector.connect()) {
            guard case .connect = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
        // The app leaves its socket file behind when it quits: nothing answers there.
        FileManager.default.createFile(atPath: connector.socketPaths[0], contents: nil)
        XCTAssertThrowsError(try connector.connect()) {
            guard case .connect = $0 as? CodexLinkError else { return XCTFail("\($0)") }
        }
    }
}
#endif
