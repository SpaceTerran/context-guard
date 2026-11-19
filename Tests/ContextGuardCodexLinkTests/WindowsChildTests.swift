#if os(Windows)
import ContextGuardCore
import ContextGuardTestSupport
import Foundation
import WinSDK
import XCTest
@testable import ContextGuardCodexLink

/// The Codex app's own Codex on Windows: started with no console window, its standard input and
/// output piped to the link.
final class WindowsChildTests: XCTestCase {
    let dir = TempDir()
    let system = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\"#
    let env = ProcessInfo.processInfo.environment

    /// A line the child wrote, without the `\r` Windows programs end lines with.
    func line(_ c: StdioChannel) throws -> String? {
        try c.receive().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func waitFor(_ what: String, timeout: TimeInterval = 5, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func testCommandLinesSplitBackIntoTheirArguments() {
        // The first is the program, which Windows reads without escapes: a path, quoted when it has spaces.
        let cases: [[String]] = [
            [#"C:\Program Files\OpenAI\codex.exe"#, "app-server"],
            ["codex.exe", "", "two words", "tab\there", #"C:\a folder\"#, #"C:\no-space\"#, #"two\\"#],
            ["codex.exe", #""quoted""#, #"say "hi" now"#, #"a\"b"#, #"a\\"b"#, #"\\server\share\"#],
        ]
        for args in cases {
            XCTAssertEqual(WindowsPaths.splitCommandLine(WindowsChild.commandLine(args)), args, WindowsChild.commandLine(args))
        }
        XCTAssertEqual(WindowsChild.quoted("plain"), "plain")
        XCTAssertEqual(WindowsChild.quoted(""), #""""#)
        XCTAssertEqual(WindowsChild.quoted(#"C:\a folder\"#), #""C:\a folder\\""#)
    }

    func testTheEnvironmentIsSortedWithoutCaseAndEndsTwice() {
        let block = WindowsChild.environmentBlock(["b": "2", "A": "1", "Path": #"C:\x"#, "=C:": "hidden", "": "none"])
        XCTAssertEqual(String(decoding: block, as: UTF16.self), "A=1\0b=2\0Path=C:\\x\0\0")
        XCTAssertEqual(WindowsChild.environmentBlock([:]), [0, 0])
    }

    func testTheChildGetsItsEnvironmentAndFolder() throws {
        var env = self.env
        env["CG_TEST"] = "from the link"
        let c = try StdioChannel.start(executable: system + "cmd.exe", arguments: ["/d", "/c", "echo %CG_TEST%&& cd"],
                                       environment: env, directory: dir.url)
        XCTAssertEqual(try line(c), "from the link")
        let folder = try XCTUnwrap(try line(c))
        XCTAssertEqual(PathRules.key(WindowsPaths.resolved(folder)), PathRules.key(WindowsPaths.resolved(dir.url.path)))
        XCTAssertNil(try c.receive(), "its output ends when it does")
        c.release()
    }

    func testLinesGoInAndItEndsWithItsInput() throws {
        // sort answers once its input has ended.
        let c = try StdioChannel.start(executable: system + "sort.exe", arguments: [], environment: env, directory: dir.url)
        try c.send(text: #"{"id":2}"#)
        try c.send(text: #"{"id":1}"#)
        c.end()
        XCTAssertEqual(try line(c), #"{"id":1}"#)
        XCTAssertEqual(try line(c), #"{"id":2}"#)
        XCTAssertNil(try c.receive())
        XCTAssertThrowsError(try c.send(text: "{}")) {
            XCTAssertEqual($0 as? CodexLinkError, .closed("the app server has stopped"))
        }
        c.release()
    }

    func testAChildIsStoppedWhenAsked() throws {
        // Waits for a line that never comes.
        let child = try WindowsChild.start(executable: system + "cmd.exe", arguments: ["/d", "/c", "set /p x="],
                                           environment: env, directory: PathRules.native(dir.url.path))
        XCTAssertTrue(child.isRunning)
        child.terminate()
        waitFor("it stopped") { !child.isRunning }
        XCTAssertEqual(child.output.availableData, Data(), "its output ends with it")
    }

    func testAProgramThatIsNotThereSaysSo() {
        XCTAssertThrowsError(try StdioChannel.start(executable: PathRules.native(dir.file("nothing.exe").path), arguments: [],
                                                    environment: env, directory: dir.url)) {
            guard case .unavailable(let why)? = $0 as? CodexLinkError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("nothing.exe"), why)
        }
    }
}
#endif
