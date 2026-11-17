import ContextGuardCore
import ContextGuardTestSupport
@testable import ContextGuardCursor
import XCTest

final class CursorAutoJudgeTests: XCTestCase {
    /// What `cursor-agent -p --output-format json` prints (Cursor CLI 2026.11.13).
    static func printed(_ result: String, session: String, isError: Bool = false) -> String {
        json(["type": "result", "subtype": isError ? "error" : "success", "is_error": isError, "duration_ms": 4337,
              "result": result, "session_id": session, "request_id": "f1c6def7-14df-44b5-acae-95cafe313b66"]) + "\n"
    }

    static let session = "6d1f0b7a-3c52-4e98-a1f4-7b2c9e0d5a36"
    static let verdict = #"{"verdict": "ready", "reason": "Committed and pushed"}"#

    let dir = TempDir()

    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var made: [(program: URL, args: [String], env: [String: String], dir: URL, input: String)] = []
        func add(_ c: (URL, [String], [String: String], URL, String)) { lock.lock(); made.append(c); lock.unlock() }
    }

    /// A judge whose `cursor-agent` is a stand-in that leaves a chat and a transcript behind, as the
    /// real one does, then answers with `output`.
    func judge(_ output: Command.Output?, calls: Calls = Calls(), installed: Bool = true) -> CursorAutoJudge {
        let bin = dir.url.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if installed {
            try! Data("#!/bin/sh\nexit 1\n".utf8).write(to: bin.appendingPathComponent("cursor-agent"))
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("cursor-agent").path)
        }
        var j = CursorAutoJudge(environment: ["PATH": bin.path, "HOME": dir.url.path, "LANG": "en_US.UTF-8"])
        j.folder = dir.url.appendingPathComponent("tmp/context-guard-cursor-judge", isDirectory: true)
        let cursor = j.cursorDir
        j.runner = { program, args, env, wd, input in
            calls.add((program, args, env, wd, String(decoding: input, as: UTF8.self)))
            let chat = cursor.appendingPathComponent("chats/\(CursorAutoJudge.md5(wd.path))/\(Self.session)")
            try? FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: chat.appendingPathComponent("meta.json"))
            let transcript = cursor.appendingPathComponent("projects/tmp-context-guard-cursor-judge/agent-transcripts/\(Self.session)")
            try? FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
            return output
        }
        return j
    }

    func ok(_ text: String) -> Command.Output { Command.Output(status: 0, stdout: Data(text.utf8)) }

    func testAsksCursorsAutoModelReadOnlyInItsOwnFolder() throws {
        let calls = Calls()
        let j = judge(ok(Self.printed(Self.verdict, session: Self.session)), calls: calls)
        XCTAssertEqual(j.judge("Is it ready?"), .success(Self.verdict))
        let call = try XCTUnwrap(calls.made.first)
        XCTAssertEqual(call.program.lastPathComponent, "cursor-agent")
        let folder = CursorAutoJudge.realPath(j.folder)
        XCTAssertEqual(call.args, ["-p", "--model", "auto", "--mode", "ask", "--output-format", "json", "--trust", "--workspace", folder.path])
        XCTAssertEqual(call.dir, folder)
        XCTAssertEqual(call.input, "Is it ready?", "on standard input, never in the process list")
        XCTAssertFalse(call.args.contains("Is it ready?"))
        XCTAssertEqual(call.env["CONTEXT_GUARD_JUDGE"], "1", "Context Guard's hooks leave the run alone")
        XCTAssertEqual(call.env["NO_OPEN_BROWSER"], "1")
        XCTAssertEqual(call.env["LANG"], "en_US.UTF-8")
        XCTAssertTrue(FileManager.default.fileExists(atPath: j.folder.path))
    }

    func testDeletesTheJudgesChatAndTranscriptAndNothingElse() throws {
        let j = judge(ok(Self.printed(Self.verdict, session: Self.session)))
        let fm = FileManager.default
        let folder = CursorAutoJudge.realPath({ try? fm.createDirectory(at: j.folder, withIntermediateDirectories: true); return j.folder }())
        let judgeChats = j.cursorDir.appendingPathComponent("chats/\(CursorAutoJudge.md5(folder.path))")
        // Another judge's run still going, and one a stopped run left long ago.
        let running = judgeChats.appendingPathComponent("0c9e4b21-7d3a-4f60-b8e2-5a1d6c3f9e07")
        let stale = judgeChats.appendingPathComponent("a3f8d2c6-1b4e-4d97-8c05-e6b2f9a7d413")
        // Your own chats: another folder's, and a transcript of yours with the same layout.
        let yours = j.cursorDir.appendingPathComponent("chats/3b8e1f6a9c2d4e5f7a8b9c0d1e2f3a4b/5e2a9c71-4b8d-4f3e-a6c2-d9e0b1f7a845")
        let yourTranscript = j.cursorDir.appendingPathComponent("projects/Users-me-code-demo/agent-transcripts/5e2a9c71-4b8d-4f3e-a6c2-d9e0b1f7a845")
        let staleTranscript = j.cursorDir.appendingPathComponent("projects/tmp-context-guard-cursor-judge/agent-transcripts/a3f8d2c6-1b4e-4d97-8c05-e6b2f9a7d413")
        for d in [running, stale, yours, yourTranscript, staleTranscript] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)

        XCTAssertEqual(j.judge("Is it ready?"), .success(Self.verdict))
        XCTAssertFalse(fm.fileExists(atPath: judgeChats.appendingPathComponent(Self.session).path), "its own chat")
        XCTAssertFalse(fm.fileExists(atPath: j.cursorDir.appendingPathComponent("projects/tmp-context-guard-cursor-judge/agent-transcripts/\(Self.session)").path))
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "left by a stopped run")
        XCTAssertFalse(fm.fileExists(atPath: staleTranscript.path))
        XCTAssertTrue(fm.fileExists(atPath: running.path), "another run's, still going")
        XCTAssertTrue(fm.fileExists(atPath: yours.path))
        XCTAssertTrue(fm.fileExists(atPath: yourTranscript.path))
    }

    func testWithoutTheCLIOrItsSignInYouAreAsked() {
        XCTAssertEqual(judge(nil, installed: false).judge("?"),
                       .failure(CursorJudgeFailure("no Cursor CLI to judge it (cursor-agent)", asksYou: true)))
        let unsigned = Command.Output(status: 1, stdout: Data(),
                                      stderr: Data("Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.\n".utf8))
        XCTAssertEqual(judge(unsigned).judge("?"),
                       .failure(CursorJudgeFailure("the Cursor CLI isn't signed in (cursor-agent login)", asksYou: true)))
    }

    func testOtherFailuresAreTriedAgainLater() {
        XCTAssertEqual(judge(nil).judge("?"), .failure(CursorJudgeFailure("no reply in 60 seconds")))
        let broke = Command.Output(status: 1, stdout: Data(), stderr: Data("\nError: Network unreachable\n".utf8))
        XCTAssertEqual(judge(broke).judge("?"), .failure(CursorJudgeFailure("cursor-agent: Network unreachable")))
        XCTAssertEqual(judge(Command.Output(status: 2, stdout: Data())).judge("?"), .failure(CursorJudgeFailure("cursor-agent stopped (status 2)")))
        XCTAssertEqual(judge(ok(Self.printed("Rate limited", session: Self.session, isError: true))).judge("?"),
                       .failure(CursorJudgeFailure("Rate limited")))
        XCTAssertEqual(judge(ok(Self.printed("  ", session: Self.session))).judge("?"), .failure(CursorJudgeFailure("an empty reply")))
        XCTAssertEqual(judge(ok("not json\n")).judge("?"), .failure(CursorJudgeFailure("no answer in its output")))
    }

    func testReadsTheResultLine() {
        let printed = "warming up\n" + Self.printed(Self.verdict, session: Self.session)
        XCTAssertEqual(CursorAutoJudge.parse(printed), CursorAutoJudge.Answer(sessionId: Self.session, isError: false, text: Self.verdict))
        XCTAssertNil(CursorAutoJudge.parse(#"{"type":"assistant"}"#))
        XCTAssertEqual(CursorAutoJudge.md5("/private/var/folders/x/T/context-guard-cursor-judge"), "83db8449d1a249c5456d8a498d6ad637")
    }

    /// CG_LIVE_CURSOR_JUDGE=1: asks Cursor's Auto model for real, through this Mac's Cursor CLI.
    func testLiveAutoJudge() throws {
        guard ProcessInfo.processInfo.environment["CG_LIVE_CURSOR_JUDGE"] == "1" else { throw XCTSkip("no live judge") }
        let j = CursorAutoJudge()
        let prompt = JudgePrompt.make(message: "Save your work: commit, push, then say you're ready.",
                                      conversation: "assistant: Committed 1a2b3c4 and pushed to origin. Ready for compaction.",
                                      idleFor: 30, host: .cursor)
        let started = Date()
        let result = j.judge(prompt)
        print("LIVE JUDGE:", result, String(format: "%.1f s", Date().timeIntervalSince(started)))
        let reply = try XCTUnwrap(try JudgeReply.parse(result.get()))
        XCTAssertEqual(reply.verdict, .ready)
        let chats = j.cursorDir.appendingPathComponent("chats/\(CursorAutoJudge.md5(CursorAutoJudge.realPath(j.folder).path))")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: chats.path)) ?? []
        XCTAssertEqual(left, [], "the judge's chats are deleted")
    }
}
