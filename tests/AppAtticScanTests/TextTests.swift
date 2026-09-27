import XCTest
@testable import AppAtticScan

final class TextTests: XCTestCase {
    func testReadUTF8FileReplacesInvalidBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utf8-\(UUID().uuidString).txt")
        try Data([0x41, 0xFF, 0x42]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(readUTF8File(url.path), "A\u{FFFD}B")
        XCTAssertNil(readUTF8File(url.appendingPathComponent("missing").path))
    }


    func testDecodeUTF8StripsLeadingBOM() {
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(contentsOf: "ID=debian\n".utf8)
        XCTAssertEqual(decodeUTF8(bom), "ID=debian\n")
        XCTAssertEqual(decodeUTF8(Data("ID=debian\n".utf8)), "ID=debian\n")
        XCTAssertEqual(decodeUTF8(Data([0xEF, 0xBB, 0xBF])), "")
    }


    func testPosixLowercasedDoesNotUseTurkishI() {
        // Deliberately not compared against Foundation's tr_TR casing: that is
        // ICU data, and the jammy container has answered both "ıına" (correct)
        // and "iina" for it across runs, which made this test flaky. What the
        // helper promises is that it lowercases ASCII and asks no locale.
        XCTAssertEqual(posixLowercased("IINA"), "iina")
        XCTAssertEqual(posixLowercased("I"), "i")
        XCTAssertEqual(posixLowercased("Straße"), "straße")
    }


    func testDisplayWidthCountsTerminalColumns() {
        XCTAssertEqual(displayWidth(""), 0)
        XCTAssertEqual(displayWidth("abc"), 3)
        // Combining acute rides on the e, so this is one column, not two.
        XCTAssertEqual(displayWidth("Cafe\u{0301}"), 4)
        XCTAssertEqual(displayWidth("Café"), 4)
        XCTAssertEqual(displayWidth("日本語"), 6)
        XCTAssertEqual(displayWidth("한국어"), 6)
        XCTAssertEqual(displayWidth("👩‍👩‍👧"), 2)
    }


    func testCollatedBeforeOrdersByName() {
        XCTAssertTrue(collatedBefore("Alpha", "Beta", tieBreak: "/a", "/b"))
        XCTAssertFalse(collatedBefore("Beta", "Alpha", tieBreak: "/b", "/a"))
    }


    func testCollatedBeforeBreaksTiesOnTheUniqueKey() {
        // Same name, so the record order comes down to the tie-break rather
        // than to whatever order the filesystem listed the directory in.
        XCTAssertTrue(collatedBefore("Zoom", "Zoom", tieBreak: "/Applications/Zoom.app", "/Users/x/Zoom.app"))
        XCTAssertFalse(collatedBefore("Zoom", "Zoom", tieBreak: "/Users/x/Zoom.app", "/Applications/Zoom.app"))
    }
}
