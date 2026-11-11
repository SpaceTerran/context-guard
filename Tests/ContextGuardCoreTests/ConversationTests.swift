import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

/// The conversation after a save message, as Haiku reads it.
final class ConversationTests: XCTestCase {
    let dir = TempDir()

    func read(_ t: Transcript, from: UInt64? = 0, after marker: String? = "cg-n", limit: Int = 40_000) throws -> Conversation {
        try XCTUnwrap(ConversationReader.read(path: t.path, from: from, after: marker, limit: limit))
    }

    func testOnlyWhatCameAfterTheSaveMessageCounts() throws {
        let t = Transcript(dir)
        t.append(Line.response(text: "Earlier work"), Line.wake("Their message: save [cg-n]"))
        t.append(Line.toolUse("Bash", ["command": "git push origin main", "description": "Push"], text: "Pushing now."))
        t.append(Line.toolResult("To github.com:x/y.git\n   abc..def  main -> main"))
        t.append(Line.response(text: "Pushed and saved. Ready for compaction."))
        let c = try read(t)
        XCTAssertEqual(c.after, "cg-n")
        XCTAssertFalse(c.text.contains("Earlier work"))
        XCTAssertEqual(c.text, """
        Claude: Pushing now.

        Claude used Bash: git push origin main

        Tool result: To github.com:x/y.git
           abc..def  main -> main

        Claude: Pushed and saved. Ready for compaction.
        """)
        XCTAssertEqual(c.mark, t.size, "ends at the last line")
        XCTAssertEqual(c.userPrompts, 0)
    }

    func testBookkeepingLinesDontMoveTheMark() throws {
        let t = Transcript(dir)
        t.append(Line.wake("[cg-n]"), Line.response(text: "Done."))
        let mark = try read(t).mark
        t.append(Line.bookkeeping(), Line.title("A title"), Line.attachment("hook output"))
        XCTAssertEqual(try read(t).mark, mark)
        t.append(Line.prompt("one more thing"))
        XCTAssertGreaterThan(try read(t).mark, mark)
    }

    func testYourPromptsAndCommandsAreCountedButPluginPromptsAreNot() throws {
        let t = Transcript(dir)
        t.append(Line.attachment("[cg-n]"), Line.prompt("which branch? main"), Line.command("/model"),
                 Line.user("/compact"), Line.pluginPrompt("continue now"), Line.compactSummary())
        let c = try read(t)
        XCTAssertEqual(c.userPrompts, 3)
        XCTAssertTrue(c.text.contains("User ran /compact"))
        XCTAssertTrue(c.text.contains("User: which branch? main"))
        XCTAssertTrue(c.text.contains("User ran /model"))
        XCTAssertTrue(c.text.contains("Prompt from a plugin: continue now"))
        XCTAssertFalse(c.text.contains("being continued"))
    }

    func testBackgroundEventsAreSummarized() throws {
        let t = Transcript(dir)
        t.append(Line.attachment("[cg-n]"), Line.wake("CI finished"))
        XCTAssertEqual(try read(t).text, "Background task event: Context Guard: save before compacting")
    }

    func testLongToolOutputIsCutAndTheOldestEntriesGoFirst() throws {
        let t = Transcript(dir)
        t.append(Line.attachment("[cg-n]"))
        t.append(Line.toolResult(String(repeating: "x", count: 5_000), error: true))
        let one = try read(t).text
        XCTAssertTrue(one.hasPrefix("Tool error: xxx"))
        XCTAssertTrue(one.hasSuffix(" […cut]"))
        XCTAssertLessThan(one.count, 2_100)

        for i in 0..<10 { t.append(Line.response(text: "step \(i) " + String(repeating: "y", count: 300))) }
        // Each step is 315 characters, so three fit in 1,000; the tool error and steps 0-6 go.
        let fitted = try read(t, limit: 1_000).text
        XCTAssertTrue(fitted.hasPrefix("[8 earlier entries left out]\n\nClaude: step 7"), fitted)
        XCTAssertTrue(fitted.hasSuffix(String(repeating: "y", count: 300)))
        XCTAssertFalse(fitted.contains("step 6"))
    }

    func testSubagentLinesAreLeftOut() throws {
        let t = Transcript(dir)
        t.append(Line.attachment("[cg-n]"), Line.response(sidechain: true, text: "subagent chatter"), Line.response(text: "main"))
        XCTAssertEqual(try read(t).text, "Claude: main")
    }

    func testWithoutTheSaveMessageItIsEverythingRead() throws {
        let t = Transcript(dir)
        t.append(Line.response(text: "a"), Line.response(text: "b"))
        let c = try read(t)
        XCTAssertNil(c.after)
        XCTAssertEqual(c.text, "Claude: a\n\nClaude: b")
    }

    func testAStartingPointPastTheEndFallsBackToTheEnd() throws {
        let t = Transcript(dir)
        t.append(Line.attachment("[cg-n]"), Line.response(text: "ready"))
        let c = try read(t, from: 10_000_000)
        XCTAssertEqual(c.after, "cg-n")
        XCTAssertEqual(c.text, "Claude: ready")
    }

    func testAPartLineStillBeingWrittenWaits() throws {
        let t = Transcript(dir)
        t.append(Line.attachment("[cg-n]"), Line.response(text: "first"))
        let mark = try read(t).mark
        t.appendRaw(String(Line.response(text: "second").prefix(40)))
        XCTAssertEqual(try read(t).mark, mark)
    }

    func testTheJudgePromptQuotesTheMessageAndTheConversation() {
        let p = JudgePrompt.make(message: "Save everything.", conversation: "Claude: saved", idleFor: 30)
        XCTAssertTrue(p.contains("<message>\nSave everything.\n</message>"))
        XCTAssertTrue(p.contains("<session>\nClaude: saved\n</session>"))
        XCTAssertFalse(p.contains("It has been idle"))
        XCTAssertTrue(p.contains("declined or ignored the message"), "a session that ignored the save message hasn't saved anything")
        XCTAssertTrue(JudgePrompt.make(message: "m", conversation: "c", idleFor: 125).contains("It has been idle for 2 minutes."))
    }
}
