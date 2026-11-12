import XCTest
@testable import ContextGuardCore
import ContextGuardTestSupport

final class TranscriptTests: XCTestCase {
    let dir = TempDir()

    func testCountsInputCacheAndOutputOfTheLastResponse() {
        let t = Transcript(dir)
        t.append(Line.context(100_000), Line.response(input: 2, cacheWrite: 986, cacheRead: 312_887, output: 262))
        XCTAssertEqual(TranscriptReader.read(path: t.path, cursor: nil).tokens, 314_137)
    }

    func testSkipsSubagentSyntheticErrorAndEmptyRecords() {
        let t = Transcript(dir)
        t.append(
            Line.context(120_000),
            Line.context(900_000).replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#),
            Line.response(input: 0, model: "<synthetic>"),
            Line.response(input: 50, error: true),
            Line.response(input: 0))
        XCTAssertEqual(TranscriptReader.read(path: t.path, cursor: nil).tokens, 120_000)
    }

    func testCompactionAfterTheLastResponseWins() {
        let t = Transcript(dir)
        t.append(Line.context(370_000), Line.compaction(pre: 370_534, post: 22_228))
        let r = TranscriptReader.read(path: t.path, cursor: nil)
        XCTAssertEqual(r.tokens, 22_228)
        XCTAssertEqual(r.compaction, .compaction(trigger: "manual", preTokens: 370_534, postTokens: 22_228))
    }

    func testResponseAfterCompactionWinsButCompactionIsStillReported() {
        let t = Transcript(dir)
        t.append(Line.context(370_000), Line.compaction(pre: 370_000, post: 22_000, trigger: "auto"), Line.context(82_332))
        let r = TranscriptReader.read(path: t.path, cursor: nil)
        XCTAssertEqual(r.tokens, 82_332)
        XCTAssertEqual(r.compaction, .compaction(trigger: "auto", preTokens: 370_000, postTokens: 22_000))
    }

    /// What compacting got the session down to: its first response after the compaction. Claude
    /// Code's `postTokens` leaves out the system prompt and tools (seen live: 6,228, then 43,227).
    func testTheFirstResponseAfterACompactionIsItsSizeAfter() {
        let t = Transcript(dir)
        t.append(Line.context(39_406), Line.compaction(pre: 39_479, post: 6_228), Line.context(43_227), Line.context(43_989))
        let r1 = TranscriptReader.read(path: t.path, cursor: nil)
        XCTAssertEqual(r1.firstTokens, 43_227)
        XCTAssertEqual(r1.tokens, 43_989)

        t.append(Line.context(44_214), Line.context(44_500))
        let r2 = TranscriptReader.read(path: t.path, cursor: r1.cursor)
        XCTAssertEqual(r2.firstTokens, 44_214, "a read without a compaction: its first response")

        t.append(Line.context(45_000), Line.compaction(pre: 45_000, post: 6_665))
        XCTAssertNil(TranscriptReader.read(path: t.path, cursor: r2.cursor).firstTokens, "no response since the compaction yet")
    }

    func testTornLastLineWaitsForTheNextRead() {
        let t = Transcript(dir)
        let first = Line.context(100_000)
        let second = Line.context(200_000)
        t.append(first)
        t.appendRaw(String(second.prefix(40)))
        let r1 = TranscriptReader.read(path: t.path, cursor: nil)
        XCTAssertEqual(r1.tokens, 100_000)
        XCTAssertEqual(r1.cursor?.offset, UInt64(first.utf8.count + 1))

        t.appendRaw(String(second.dropFirst(40)) + "\n")
        let r2 = TranscriptReader.read(path: t.path, cursor: r1.cursor)
        XCTAssertEqual(r2.tokens, 200_000)
        XCTAssertEqual(r2.cursor?.offset, t.size)
    }

    func testIncrementalReadSeesOnlyNewLines() {
        let t = Transcript(dir)
        t.append(Line.context(100_000))
        let r1 = TranscriptReader.read(path: t.path, cursor: nil)
        let unchanged = TranscriptReader.read(path: t.path, cursor: r1.cursor)
        XCTAssertNil(unchanged.tokens, "nothing new, so nothing to report")
        XCTAssertEqual(unchanged.cursor, r1.cursor)

        t.append(Line.title("Ship it"), Line.context(150_000))
        let r2 = TranscriptReader.read(path: t.path, cursor: r1.cursor)
        XCTAssertEqual(r2.tokens, 150_000)
        XCTAssertEqual(r2.title, "Ship it")
    }

    func testGiantLastLineStillFindsTheResponseBeforeIt() {
        let t = Transcript(dir)
        t.append(Line.title("Big"), Line.context(150_000), Line.user(String(repeating: "x", count: 1_200_000)))
        let r = TranscriptReader.read(path: t.path, cursor: nil)
        XCTAssertEqual(r.tokens, 150_000)
        XCTAssertEqual(r.cursor?.offset, t.size)
    }

    func testRecordTypesQuotedInsideToolOutputDontCount() {
        let t = Transcript(dir)
        let quoted = Line.context(999_000)
        t.append(Line.context(120_000), Line.user("tool output: \(quoted) and \(Line.compaction(pre: 1, post: 1))"))
        let r = TranscriptReader.read(path: t.path, cursor: nil)
        XCTAssertEqual(r.tokens, 120_000)
        XCTAssertNil(r.compaction)
    }

    func testDeliveryMarkerCountsOnlyInUserOrAttachmentRecords() {
        let t = Transcript(dir)
        t.append(Line.context(310_000), Line.response(input: 5, text: "I saw cg-abc123 earlier"))
        XCTAssertTrue(TranscriptReader.read(path: t.path, cursor: nil, markers: ["cg-abc123"]).markersSeen.isEmpty)

        t.append(Line.attachment("Message from the user (cg-abc123): compact soon"))
        XCTAssertEqual(TranscriptReader.read(path: t.path, cursor: nil, markers: ["cg-abc123"]).markersSeen, ["cg-abc123"])

        let woken = Transcript(dir, name: "woken.jsonl")
        woken.append(Line.user("<system-reminder>Stop hook blocking error from command \"Stop\": Message (cg-zzz999): hi</system-reminder>"))
        XCTAssertEqual(TranscriptReader.read(path: woken.path, cursor: nil, markers: ["cg-zzz999"]).markersSeen, ["cg-zzz999"])
    }

    func testReplacedFileIsRescannedFromTheEnd() {
        let t = Transcript(dir)
        t.append(Line.context(100_000))
        let stale = TranscriptCursor(inode: 1, offset: 5)
        XCTAssertEqual(TranscriptReader.read(path: t.path, cursor: stale).tokens, 100_000)
    }

    func testServerToolLoopUsesTheLastIteration() {
        let t = Transcript(dir)
        t.append(Line.response(input: 999_999, iterations: [
            ["type": "message", "input_tokens": 0, "cache_read_input_tokens": 50_000, "output_tokens": 0],
            ["type": "message", "input_tokens": 0, "cache_read_input_tokens": 120_000, "output_tokens": 500],
        ]))
        XCTAssertEqual(TranscriptReader.read(path: t.path, cursor: nil).tokens, 120_500)
    }

    func testMissingFileReadsAsNothing() {
        XCTAssertNil(TranscriptReader.read(path: dir.file("nope.jsonl").path, cursor: nil).tokens)
    }
}
