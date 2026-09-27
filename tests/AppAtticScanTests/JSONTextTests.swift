import Foundation
import XCTest
@testable import AppAtticScan

/// The scan both JSON readers run before the decoder, so a control character
/// inside a string is reported as invalid JSON instead of aborting the process
/// from the decoder's `try!` unwrap. A `Data` literal rather than a Swift
/// string, because a Swift string cannot hold the invalid UTF-8 spelling.
final class JSONTextTests: XCTestCase {
    func testControlCharactersBetweenTokensAreLegal() {
        // Whitespace outside a string is part of the format: pretty-printed
        // JSON is what a settings file usually is.
        XCTAssertTrue(jsonHasNoControlCharacterInString(Data("{\n  \"a\":\t1\r\n}".utf8)))
        XCTAssertTrue(jsonHasNoControlCharacterInString(Data("[]".utf8)))
        XCTAssertTrue(jsonHasNoControlCharacterInString(Data("".utf8)))
    }

    func testControlCharactersInsideAStringAreRejected() {
        XCTAssertFalse(jsonHasNoControlCharacterInString(Data("{\"a\":\"x\ny\"}".utf8)))
        XCTAssertFalse(jsonHasNoControlCharacterInString(Data("{\"a\nb\":\"x\"}".utf8)))
        XCTAssertFalse(jsonHasNoControlCharacterInString(Data("{\"a\":\"x\u{0}y\"}".utf8)))
        XCTAssertFalse(jsonHasNoControlCharacterInString(Data("{\"a\":\"x\u{1F}y\"}".utf8)))
    }

    func testEscapesAreFollowedRatherThanCounted() {
        // `\"` does not end the string, so the newline behind it is still
        // inside one.
        XCTAssertFalse(jsonHasNoControlCharacterInString(Data("{\"a\":\"x\\\"\ny\"}".utf8)))
        // `\\` is one escaped backslash, so the `n` after it is an ordinary
        // letter and the string stays on one line.
        XCTAssertTrue(jsonHasNoControlCharacterInString(Data("{\"a\":\"x\\\\ny\"}".utf8)))
        // An escaped newline is the legal spelling of the same character.
        XCTAssertTrue(jsonHasNoControlCharacterInString(Data("{\"a\":\"x\\ny\"}".utf8)))
    }

    func testInvalidUTF8InAStringIsLeftToTheDecoder() {
        // Not this scan's business: the bytes carry no control character, and
        // `JSONSerialization`, which runs first, is what reports them.
        XCTAssertTrue(jsonHasNoControlCharacterInString(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D])))
    }
}
