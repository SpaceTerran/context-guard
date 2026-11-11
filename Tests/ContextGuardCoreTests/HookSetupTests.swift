import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// Adding and removing Context Guard's hooks in Claude Code's settings. The expected texts are what
/// `install.sh`'s jq filters wrote before `context-guard setup` took over from them.
final class HookSetupTests: XCTestCase {
    private let mac = HookSetup.shellProgram
    private let windows = HookSetup.windowsProgram(home: #"C:\Users\a"#)

    private func settings(_ dir: TempDir, _ text: String?) throws -> URL {
        let url = dir.file("settings.json")
        if let text { try Data(text.utf8).write(to: url) }
        return url
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testItAddsOneGroupPerEventAfterTheOthersAsTheInstallerAlwaysHas() throws {
        let dir = TempDir()
        let url = try settings(dir, #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo theirs"}]}]}}"#)
        let now = Date()
        let outcome = try HookSetup.install(mac, settings: url, now: now)
        let backup = try XCTUnwrap({ if case .updated(let b) = outcome { return b } else { return nil } }())
        XCTAssertEqual(try read(backup), #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo theirs"}]}]}}"#)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.json.context-guard-backup-"))
        let command = #"f=\"$HOME/.claude/hooks/context-guard/context-guard\"; if [ -x \"$f\" ]; then CG_CLAUDE_PID=$PPID exec \"$f\" hook; else cat >/dev/null; fi"#
        func group(_ timeout: String) -> String {
            """
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "\(command)",
                        "timeout": \(timeout)
                      }
                    ]
                  }
            """
        }
        XCTAssertEqual(try read(url), """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo theirs"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(command)",
                    "timeout": 43500,
                    "asyncRewake": true,
                    "rewakeSummary": "Context Guard: save before compacting",
                    "rewakeMessage": "Stop hook message:"
                  }
                ]
              }
            ],
            "PostToolBatch": [
        \(group("5"))
            ],
            "SessionStart": [
        \(group("5"))
            ],
            "SessionEnd": [
        \(group("5"))
            ],
            "StopFailure": [
        \(group("5"))
            ]
          }
        }

        """)
    }

    func testRunningItAgainLeavesOneOfEachAndWritesNothing() throws {
        let dir = TempDir()
        let url = try settings(dir, nil)
        XCTAssertEqual(try HookSetup.install(mac, settings: url), .updated(backup: nil), "no file before: nothing to back up")
        let first = try read(url)
        XCTAssertEqual(try HookSetup.install(mac, settings: url), .unchanged)
        XCTAssertEqual(try read(url), first)
        let parsed = try OrderedJSON.parse(Data(first.utf8))
        for event in HookSetup.events {
            guard case .array(let groups)? = parsed["hooks"]?[event] else { return XCTFail(event) }
            XCTAssertEqual(groups.count, 1, event)
        }
    }

    func testOnWindowsTheHookRunsTheProgramItself() throws {
        XCTAssertEqual(windows.command, #"C:\Users\a\.claude\hooks\context-guard\context-guard.exe"#)
        XCTAssertEqual(HookSetup.windowsProgram(home: "C:/Users/a/").command, windows.command, "either separator, trailing or not")
        let dir = TempDir()
        let url = try settings(dir, "{}")
        try HookSetup.install(windows, settings: url)
        let text = try read(url)
        XCTAssertTrue(text.contains(#""command": "C:\\Users\\a\\.claude\\hooks\\context-guard\\context-guard.exe","#))
        XCTAssertTrue(text.contains("\"args\": [\n              \"hook\"\n            ],\n            \"timeout\": 5"), text)
        XCTAssertTrue(HookInstall.isInstalled(Paths(root: dir.file("cg"), claudeDir: dir.url)), "the app finds it")
        // Installing the other kind replaces it rather than adding a second.
        try HookSetup.install(mac, settings: url)
        XCTAssertFalse(try read(url).contains("context-guard.exe"))
    }

    func testRemovingLeavesEveryOtherHookAndSetting() throws {
        let dir = TempDir()
        let url = try settings(dir, """
        {"hooks": {
          "Stop": [{"hooks": [{"command": "echo theirs"}, {"command": "f=\\"$HOME/.claude/hooks/context-guard/context-guard\\"; exec \\"$f\\" hook"}]},
                   {"matcher": "*", "hooks": [{"command": "C:\\\\Users\\\\a\\\\.claude\\\\hooks\\\\context-guard\\\\context-guard.exe", "args": ["hook"]}]}],
          "PreToolUse": [{"matcher": "Bash", "hooks": [{"command": "guard.sh"}]}],
          "SessionStart": [{"hooks": []}],
          "Notification": []
        }, "after": 1}
        """)
        XCTAssertNotEqual(try HookSetup.uninstall(settings: url), .unchanged)
        XCTAssertEqual(try read(url), """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo theirs"
                  }
                ]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "command": "guard.sh"
                  }
                ]
              }
            ],
            "SessionStart": [
              {
                "hooks": []
              }
            ]
          },
          "after": 1
        }

        """, "a group that held only ours goes, and so does an event left empty, as before")
    }

    func testRemovingWithNothingToRemoveLeavesTheFileAsItIs() throws {
        let dir = TempDir()
        let text = "{\n    \"hooks\": {\"Stop\": []},\n    \"a\": 1e3\n}"
        let url = try settings(dir, text)
        XCTAssertEqual(try HookSetup.uninstall(settings: url), .unchanged)
        XCTAssertEqual(try read(url), text)
        XCTAssertEqual(try HookSetup.uninstall(settings: dir.file("missing.json")), .unchanged)
        let broken = try settings(dir, #"{"a": 1,"#)
        XCTAssertEqual(try HookSetup.uninstall(settings: broken), .unchanged, "a broken file that never mentions it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted(), ["settings.json"], "no backups")
    }

    func testABrokenFileIsRefusedAndLeftAlone() throws {
        let dir = TempDir()
        for (text, problem) in [(#"{"a": 1,"#, "isn't valid JSON"), ("[1]", "it isn't a JSON object"),
                                (#"{"hooks": 3}"#, #""hooks" isn't an object"#), (#"{"hooks": {"Stop": {"x": 1}}}"#, #""hooks"."Stop" isn't a list"#)] {
            let url = try settings(dir, text)
            XCTAssertThrowsError(try HookSetup.install(mac, settings: url), text) { error in
                XCTAssertTrue("\(error)".contains(problem), "\(error)")
                XCTAssertTrue("\(error)".hasSuffix("fix it and run this again"), "\(error)")
            }
            XCTAssertEqual(try read(url), text)
        }
        let url = try settings(dir, #"{"hooks": {"Stop": [{"hooks": [{"command": "hooks/context-guard/context-guard"}]}]},"#)
        XCTAssertThrowsError(try HookSetup.uninstall(settings: url), "it mentions the program, so it's read, and it's broken")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted(), ["settings.json"], "no backups")
    }

    func testAByteOrderMarkStays() throws {
        let dir = TempDir()
        let url = dir.file("settings.json")
        try Data([0xEF, 0xBB, 0xBF] + Array(#"{"a": 1}"#.utf8)).write(to: url)
        try HookSetup.install(windows, settings: url)
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(4)), [0xEF, 0xBB, 0xBF, UInt8(ascii: "{")])
    }

    #if !os(Windows)
    func testTheFileKeepsItsPermissions() throws {
        let dir = TempDir()
        let url = try settings(dir, "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let outcome = try HookSetup.install(mac, settings: url)
        func mode(_ u: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        XCTAssertEqual(try mode(url), 0o600)
        if case .updated(let backup?) = outcome { XCTAssertEqual(try mode(backup), 0o600) } else { XCTFail("\(outcome)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.hasPrefix(".") }, [], "no temporary file left")
    }
    #endif

    func testTheHookCommandNamesClaudeCodesProcessOrClaudeCodeDoes() {
        XCTAssertEqual(HookRunner.claudePid(["CG_CLAUDE_PID": "41", "CLAUDE_PID": "42"]), 41, "the Mac's shell line says which")
        XCTAssertEqual(HookRunner.claudePid(["CLAUDE_PID": "42"]), 42, "Windows: Claude Code says")
        XCTAssertEqual(HookRunner.claudePid(["CG_CLAUDE_PID": "", "CLAUDE_PID": "42"]), 42)
        XCTAssertNil(HookRunner.claudePid([:]))
        XCTAssertNil(HookRunner.claudePid(["CLAUDE_PID": "x"]))
    }

    func testTheSettingsAreInTheHomeFolder() {
        #if os(Windows)
        let url = HookSetup.settingsFile(["USERPROFILE": #"C:\Users\a"#])
        XCTAssertEqual(PathRules.native(url.path).lowercased(), #"c:\users\a\.claude\settings.json"#)
        XCTAssertEqual(HookSetup.program(["USERPROFILE": #"C:\Users\a"#]), windows)
        #else
        XCTAssertEqual(HookSetup.settingsFile(["HOME": "/Users/a"]).path, "/Users/a/.claude/settings.json")
        XCTAssertEqual(HookSetup.program(["HOME": "/Users/a"]), mac)
        #endif
    }
}
