#if canImport(CryptoKit)
import CryptoKit
#endif
import XCTest
@testable import ContextGuardCore

final class DigestTests: XCTestCase {
    // FIPS 180 examples and NIST's long-message vectors.
    let abc = "abc"
    let two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    let four = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
    let million = String(repeating: "a", count: 1_000_000)

    func sha1(_ s: String) -> String { Digest.hex(Digest.sha1(Data(s.utf8))) }
    func sha256(_ s: String) -> String { Digest.hex(Digest.sha256(Data(s.utf8))) }

    func testSHA1KnownAnswers() {
        XCTAssertEqual(sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(sha1(abc), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(sha1(two), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(sha1(four), "a49b2446a02c645bf419f995b67091253a04a259")
        XCTAssertEqual(sha1(million), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    func testSHA256KnownAnswers() {
        XCTAssertEqual(sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256(abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha256(two), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(sha256(four), "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
        XCTAssertEqual(sha256(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testHex() {
        XCTAssertEqual(Digest.hex([0x00, 0x0F, 0xA0, 0xFF]), "000fa0ff")
        XCTAssertEqual(Digest.hex([]), "")
    }

    #if canImport(CryptoKit)
    /// Every length around the padding boundaries (55, 56, 63, 64 bytes and their multiples), against
    /// the system's own implementation.
    func testEveryLengthMatchesCryptoKit() {
        var generator = SystemRandomNumberGenerator()
        for length in 0...300 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            XCTAssertEqual(Digest.sha1(data), Array(Insecure.SHA1.hash(data: data)), "SHA-1 of \(length) bytes")
            XCTAssertEqual(Digest.sha256(data), Array(SHA256.hash(data: data)), "SHA-256 of \(length) bytes")
        }
    }
    #endif
}
