@testable import ContextGuardCursor
import XCTest

final class CursorAppTypingTests: XCTestCase {
    func pick(_ places: [String], namesakes: Int?) -> String? {
        CursorAppTyping.Session.pick(places, namesakes: { namesakes })
    }

    func testTypesOnlyWhereTheChatSurelyIs() {
        XCTAssertNil(pick([], namesakes: 0), "not open")
        XCTAssertEqual(pick(["panel"], namesakes: 0), "panel")
        XCTAssertEqual(pick(["panel", "tab"], namesakes: 0), "panel", "one chat open twice")

        XCTAssertNil(pick(["tab"], namesakes: 1), "it could be the other chat by that name")
        XCTAssertNil(pick(["panel", "tab"], namesakes: 2))

        XCTAssertEqual(pick(["panel"], namesakes: nil), "panel", "no list to count in: one place is the chat")
        XCTAssertNil(pick(["panel", "tab"], namesakes: nil), "no list to count in: two could be two chats")
    }

    func testCountsOtherChatsOnlyWhenTheChatShows() {
        var counted = 0
        XCTAssertNil(CursorAppTyping.Session.pick([String](), namesakes: { counted += 1; return 0 }))
        XCTAssertEqual(counted, 0)
    }
}
