import XCTest
@testable import UndertoneApp

final class TypedTextPolicyTests: XCTestCase {
    private let messages = "com.apple.MobileSMS"
    private let terminal = "com.apple.Terminal"
    private let mail = "com.apple.mail"

    func testLineBreaksAreAllowedOnlyInDocumentApps() {
        XCTAssertTrue(TypedTextPolicy.allowsLineBreaks(bundleID: mail))
        XCTAssertTrue(TypedTextPolicy.allowsLineBreaks(bundleID: "com.apple.Notes"))
        XCTAssertFalse(TypedTextPolicy.allowsLineBreaks(bundleID: messages))
        XCTAssertFalse(TypedTextPolicy.allowsLineBreaks(bundleID: terminal))
        XCTAssertFalse(TypedTextPolicy.allowsLineBreaks(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(TypedTextPolicy.allowsLineBreaks(bundleID: nil))
    }

    func testLineBreaksBecomeOneSpaceOutsideDocumentApps() {
        for bundleID in [messages, terminal, nil] {
            XCTAssertEqual(TypedTextPolicy.sanitized("Hello.\n\nNext line", bundleID: bundleID), "Hello. Next line")
            XCTAssertEqual(TypedTextPolicy.sanitized("Hello. \n  World", bundleID: bundleID), "Hello. World")
            XCTAssertEqual(TypedTextPolicy.sanitized("a\r\nb\rc", bundleID: bundleID), "a b c")
            XCTAssertEqual(TypedTextPolicy.sanitized("a\u{2028}b\u{2029}c\u{85}d", bundleID: bundleID), "a b c d")
            XCTAssertEqual(TypedTextPolicy.sanitized("run this\n", bundleID: bundleID), "run this ")
        }
    }

    func testStreamedChunkKeepsItsLeadingSeparator() {
        // Streamed chunks carry the whitespace before them at the front.
        XCTAssertEqual(TypedTextPolicy.sanitized("\n\nSecond paragraph", bundleID: messages), " Second paragraph")
        XCTAssertEqual(TypedTextPolicy.sanitized(" next words", bundleID: messages), " next words")
    }

    func testDocumentAppsKeepLineBreaksAsNewlines() {
        XCTAssertEqual(TypedTextPolicy.sanitized("Hi Sam,\n\nThanks.", bundleID: mail), "Hi Sam,\n\nThanks.")
        XCTAssertEqual(TypedTextPolicy.sanitized("a\r\nb\rc\u{2029}d", bundleID: mail), "a\nb\nc\nd")
    }

    func testControlCharactersNeverReachTheKeyboard() {
        for bundleID in [messages, mail, nil] {
            XCTAssertEqual(TypedTextPolicy.sanitized("a\tb", bundleID: bundleID), "a b")
            XCTAssertEqual(TypedTextPolicy.sanitized("a\u{1B}[Ab", bundleID: bundleID), "a[Ab")
            XCTAssertEqual(TypedTextPolicy.sanitized("a\u{7F}b\u{0}c\u{9B}d\u{3}e", bundleID: bundleID), "abcde")
            XCTAssertEqual(TypedTextPolicy.sanitized("\u{1B}\u{3}\u{7F}", bundleID: bundleID), "")
        }
    }

    func testOrdinaryTextIsUnchanged() {
        let text = "Café, naïve e\u{301}t 日本語 😀 👍🏽 «quoted» 3.5% done."
        for bundleID in [messages, mail, nil] {
            XCTAssertEqual(TypedTextPolicy.sanitized(text, bundleID: bundleID), text)
        }
    }

    func testEveryWordSurvives() {
        let text = "First line\r\n\n  second\tline \u{1B}third\u{2028}fourth"
        let expected = ["First", "line", "second", "line", "third", "fourth"]
        for bundleID in [messages, mail] {
            let words = TypedTextPolicy.sanitized(text, bundleID: bundleID).split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertEqual(words, expected)
        }
    }
}
