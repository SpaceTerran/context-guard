import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// Adding and removing Context Guard's hooks in Cursor's user hooks file, next to other tools' hooks.
final class CursorHookSetupTests: XCTestCase {
    /// Another tool's hooks file, as it writes it (a status hook on a few events, and one of yours).
    static let theirs = """
    {
      "hooks": {
        "beforeSubmitPrompt": [
          {
            "command": "/bin/sh -c '/Users/me/.othertool/agent-hooks/cursor-hook.sh'",
            "timeout": 10
          }
        ],
        "sessionStart": [
          {
            "command": "bash '/Users/me/.cursor/agent-state.sh' session"
          }
        ],
        "stop": [
          {
            "command": "/bin/sh -c '/Users/me/.othertool/agent-hooks/cursor-hook.sh'",
            "timeout": 10
          }
        ]
      },
      "version": 1
    }

    """

    static let ours = #"/bin/sh -c 'f=\"$HOME/.claude/hooks/context-guard/context-guard\"; if [ -x \"$f\" ]; then exec \"$f\" cursor hook; else cat >/dev/null; echo \"{}\"; fi'"#

    static func entry(_ timeout: Int, indent: String = "      ") -> String {
        """
        \(indent){
        \(indent)  "command": "\(ours)",
        \(indent)  "timeout": \(timeout)
        \(indent)}
        """
    }

    let dir = TempDir()
    func file(_ text: String?) throws -> URL {
        let url = dir.url.appendingPathComponent(".cursor/hooks.json")
        if let text {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testANewFileHasEveryEventItUses() throws {
        let url = try file(nil)
        XCTAssertEqual(try CursorHookSetup.install(hooks: url), .updated(backup: nil))
        XCTAssertEqual(try read(url), """
        {
          "version": 1,
          "hooks": {
            "beforeSubmitPrompt": [
        \(Self.entry(5))
            ],
            "postToolUse": [
        \(Self.entry(5))
            ],
            "preCompact": [
        \(Self.entry(5))
            ],
            "stop": [
        \(Self.entry(43800))
            ],
            "sessionEnd": [
        \(Self.entry(5))
            ]
          }
        }

        """)
        XCTAssertTrue(CursorHookSetup.isInstalled(["HOME": dir.url.path]))
    }

    func testOtherHooksStayAsTheyWereAndOursGoLast() throws {
        let url = try file(Self.theirs)
        let outcome = try CursorHookSetup.install(hooks: url)
        guard case .updated(let backup?) = outcome else { return XCTFail("backed up first: \(outcome)") }
        XCTAssertEqual(try read(backup), Self.theirs)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("hooks.json.context-guard-backup-"))
        XCTAssertEqual(try read(url), """
        {
          "hooks": {
            "beforeSubmitPrompt": [
              {
                "command": "/bin/sh -c '/Users/me/.othertool/agent-hooks/cursor-hook.sh'",
                "timeout": 10
              },
        \(Self.entry(5))
            ],
            "sessionStart": [
              {
                "command": "bash '/Users/me/.cursor/agent-state.sh' session"
              }
            ],
            "stop": [
              {
                "command": "/bin/sh -c '/Users/me/.othertool/agent-hooks/cursor-hook.sh'",
                "timeout": 10
              },
        \(Self.entry(43800))
            ],
            "postToolUse": [
        \(Self.entry(5))
            ],
            "preCompact": [
        \(Self.entry(5))
            ],
            "sessionEnd": [
        \(Self.entry(5))
            ]
          },
          "version": 1
        }

        """)

        // Again: one of each, nothing written.
        XCTAssertEqual(try CursorHookSetup.install(hooks: url), .unchanged)
        // Removed: the file is as it was.
        XCTAssertNotEqual(try CursorHookSetup.uninstall(hooks: url), .unchanged)
        XCTAssertEqual(try read(url), Self.theirs)
        XCTAssertFalse(CursorHookSetup.isInstalled(["HOME": dir.url.path]))
        XCTAssertEqual(try CursorHookSetup.uninstall(hooks: url), .unchanged)
    }

    func testAFileItCantReadIsLeftAlone() throws {
        let broken = try file(#"{"hooks": ["#)
        XCTAssertThrowsError(try CursorHookSetup.install(hooks: broken)) { error in
            XCTAssertEqual(error as? HookSetup.Problem, .invalidJSON(PathRules.native(broken.path)))
        }
        XCTAssertEqual(try read(broken), #"{"hooks": ["#)
        // Uninstalling never reads a file that doesn't mention Context Guard.
        XCTAssertEqual(try CursorHookSetup.uninstall(hooks: broken), .unchanged)
        XCTAssertEqual(try CursorHookSetup.uninstall(hooks: try file(nil).appendingPathExtension("missing")), .unchanged)

        let odd = try file(#"{"hooks": {"stop": {"command": "x"}}}"#)
        XCTAssertThrowsError(try CursorHookSetup.install(hooks: odd)) { error in
            XCTAssertEqual(error as? HookSetup.Problem, .unexpected(PathRules.native(odd.path), what: #""hooks"."stop" isn't a list"#))
        }
    }

    func testTheHookRunsTheInstalledProgramOrReadsTheEvent() throws {
        #if os(Windows)
        throw XCTSkip("Cursor is guarded on the Mac only")
        #endif
        // Run as Cursor runs it: the event on stdin, no program installed.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", CursorHookSetup.command]
        p.environment = ["HOME": dir.url.path]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"stop"}"#.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "{}\n")
    }
}
