@testable import ContextGuardCore
import XCTest

/// The expected texts are what `jq .` (1.7.1) printed for the same input.
final class OrderedJSONTests: XCTestCase {
    private func jq(_ text: String) throws -> String {
        try OrderedJSON.parse(Data(text.utf8)).jqText
    }

    func testItPrintsAsJqDoesAndKeepsTheKeysInOrder() throws {
        XCTAssertEqual(try jq(#"{"z":1,"a":[],"m":{},"b":[1,[2,[]],{"a":{}}],"t":true,"f":false,"n":null}"#), """
        {
          "z": 1,
          "a": [],
          "m": {},
          "b": [
            1,
            [
              2,
              []
            ],
            {
              "a": {}
            }
          ],
          "t": true,
          "f": false,
          "n": null
        }

        """)
        XCTAssertEqual(try jq(#""top""#), "\"top\"\n")
        XCTAssertEqual(try jq("  [ ]  "), "[]\n")
    }

    func testAKeyGivenTwiceKeepsItsFirstPlaceAndLastValue() throws {
        XCTAssertEqual(try jq(#"{"dup":1,"w":2,"dup":3}"#), "{\n  \"dup\": 3,\n  \"w\": 2\n}\n")
    }

    func testNumbersComeOutAsJqWritesThem() {
        let cases: [(String, String)] = [
            ("1.10", "1.10"), ("1e2", "1E+2"), ("100000000000000000001", "100000000000000000001"), ("-0", "-0"),
            ("1.0", "1.0"), ("1E+2", "1E+2"), ("0.1e-5", "0.000001"), ("12345678901234567890123", "12345678901234567890123"),
            ("3.141592653589793238", "3.141592653589793238"), ("-1.5e300", "-1.5E+300"), ("1e400", "1E+400"),
            ("10e1", "1.0E+2"), ("123e-2", "1.23"), ("123e-10", "1.23E-8"), ("0e5", "0E+5"), ("0.0e-9", "0E-10"),
            ("5e-7", "5E-7"), ("12e-8", "1.2E-7"), ("-0e0", "-0"), ("1.5e3", "1.5E+3"), ("0.001e3", "1"),
            ("100e-2", "1.00"), ("9e-7", "9E-7"), ("1e-6", "0.000001"), ("1.23e-4", "0.000123"), ("4.5E-1", "0.45"),
            ("7e0", "7"), ("70e-1", "7.0"), ("0.00", "0.00"), ("1e+0", "1"), ("2E-0", "2"), ("0", "0"), ("43500", "43500"),
            ("0.10", "0.10"),
        ]
        for (literal, printed) in cases {
            XCTAssertEqual(OrderedJSON.jqNumber(literal), printed, literal)
        }
    }

    func testStringsAreEscapedAsJqDoes() throws {
        let input = #""q\" b\\ s\/ \b\f\n\r\t \u0001 \u001f \u007f é é   😀 日本""#
        let printed = #""q\" b\\ s/ \b\f\n\r\t \u0001 \u001f \u007f é é "# + "\u{2028}" + #" 😀 日本""# + "\n"
        XCTAssertEqual(try jq(input), printed)
        XCTAssertEqual(try OrderedJSON.parse(Data(printed.utf8)).jqText, printed, "it reads back what it prints")
    }

    func testABadDocumentIsRefused() {
        for bad in [#"{"a": 1,"#, "[1,2] x", #""\ud800 x \udc00""#, #""\udc00""#, "01", "1.", "-", #"{"a" 1}"#, "\"a\u{01}\"",
                    #""unterminated"#, "tru", "{,}", "[1,]", "", String(repeating: "[", count: 600) + String(repeating: "]", count: 600)] {
            XCTAssertThrowsError(try OrderedJSON.parse(Data(bad.utf8)), bad.prefix(20).description)
        }
    }

    func testAByteOrderMarkIsSkipped() throws {
        XCTAssertEqual(try OrderedJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array(#"{"a":1}"#.utf8))), .object([.init("a", .number("1"))]))
    }

    func testSettingAMemberKeepsItsPlaceOrAddsItAtTheEnd() {
        var o = OrderedJSON.object([.init("a", .number("1")), .init("b", .number("2"))])
        o.set("a", .string("x"))
        o.set("c", .null)
        XCTAssertEqual(o, .object([.init("a", .string("x")), .init("b", .number("2")), .init("c", .null)]))
        XCTAssertEqual(o["b"], .number("2"))
        XCTAssertNil(o["missing"])
        var a = OrderedJSON.array([])
        a.set("x", .null)
        XCTAssertEqual(a, .array([]), "only objects have members")
    }
}
