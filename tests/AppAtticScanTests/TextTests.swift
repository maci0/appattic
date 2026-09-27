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


    func testPosixFoldedCollapsesNFCAndNFD() {
        // The failing input: macOS reports "Café" as "Cafe" + U+0301, a
        // keyboard gives the precomposed form, and a bare case fold leaves the
        // two as different strings.
        let nfc = "Café"
        let nfd = "Cafe\u{0301}"
        // The two are the same String — Swift compares canonically — and
        // different bytes, which is what the fold has to bring together.
        XCTAssertEqual(nfc, nfd)
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertEqual(posixFolded(nfc), posixFolded(nfd))
        XCTAssertEqual(posixFolded(nfd), "café")
        XCTAssertTrue(posixFolded(nfd).contains(posixFolded("CAFÉ")))
        // The query arrives NFC and the name off the disk arrives NFD.
        XCTAssertTrue(posixFolded(nfd).contains(posixFolded(nfc)))
    }


    func testPosixFoldedKeepsDiacriticsAndAsciiFastPath() {
        // Normalization, not folding: "cafe" is not "Café". A caller that wants
        // the accent-insensitive match uses `norm`.
        XCTAssertFalse(posixFolded("Café").contains("cafe"))
        XCTAssertEqual(posixFolded(""), "")
        XCTAssertEqual(posixFolded("IINA"), "iina")
        // A precomposed string with no combining mark is already NFC.
        XCTAssertEqual(posixFolded("Straße"), "straße")
        // A script with no case and no composition comes back unchanged.
        XCTAssertEqual(posixFolded("日本語"), "日本語")
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
        // A skin-tone modifier rides on the base glyph instead of taking a
        // cell of its own, so the pair is the width of the base alone.
        XCTAssertEqual(displayWidth("👍🏽"), 2)
    }

    func testSanitizeForTerminalNeutralizesControlsButKeepsColor() {
        // A Linux filename may hold any byte but NUL, so both of these reach
        // the report as one cell.
        XCTAssertEqual(sanitizeForTerminal("Some\nApp"), "Some App")
        // The ESC and the BEL are the controls; the `]0;pwned` between them
        // is text the terminal only acts on behind the escape it lost.
        XCTAssertEqual(sanitizeForTerminal("x\u{1b}]0;pwned\u{7}"), "x ]0;pwned ")
        XCTAssertEqual(sanitizeForTerminal("a\tb"), "a b")
        // C1 controls arrive as the two UTF-8 bytes 0xC2 0x9B.
        XCTAssertEqual(sanitizeForTerminal("a\u{0085}b"), "a b")
        // What it must not touch.
        XCTAssertEqual(sanitizeForTerminal("plain/name"), "plain/name")
        XCTAssertEqual(sanitizeForTerminal("Café 日本語 👩‍👩‍👧"), "Café 日本語 👩‍👩‍👧")
        XCTAssertEqual(sanitizeForTerminal(""), "")
        // SGR is the one sequence the renderer emits, so colour survives.
        XCTAssertEqual(sanitizeForTerminal("\u{1b}[31mREMOVE\u{1b}[0m"), "\u{1b}[31mREMOVE\u{1b}[0m")
        // A truncated or non-SGR escape is not a colour code and is dropped
        // whole, so the terminal never executes it.
        XCTAssertEqual(sanitizeForTerminal("\u{1b}[38;5;1mx"), "\u{1b}[38;5;1mx")
        XCTAssertEqual(sanitizeForTerminal("\u{1b}[38;5;1"), " [38;5;1")
    }


    func testTerminalSafeReplacesControlCharacters() {
        // A directory name is text a terminal executes: ESC [ 2 J clears the
        // report the row is printed in, ESC ] 0 ; retitles the window.
        XCTAssertEqual(terminalSafe("gone\u{1B}[2Japp"), "gone\u{FFFD}[2Japp")
        XCTAssertEqual(terminalSafe("a\u{0}b\u{7F}c"), "a\u{FFFD}b\u{FFFD}c")
        // Tab is a C0 control: inside a table cell it moves the cursor and the
        // columns stop lining up.
        XCTAssertEqual(terminalSafe("a\tb"), "a\u{FFFD}b")
        // C1 controls, the 8-bit half an emulated terminal also acts on.
        XCTAssertEqual(terminalSafe("a\u{9B}c"), "a\u{FFFD}c")
    }

    func testTerminalSafeLeavesTextAndNamesAlone() {
        XCTAssertEqual(terminalSafe("Firefox"), "Firefox")
        XCTAssertEqual(terminalSafe("/home/u/Library/Caches"), "/home/u/Library/Caches")
        // The bidi scalars `stripBidiControls` removes are not controls, so
        // they survive here and are that function's business.
        XCTAssertEqual(terminalSafe("Cafe\u{202E}f"), "Cafe\u{202E}f")
        XCTAssertEqual(terminalSafe("日本語"), "日本語")
        XCTAssertEqual(terminalSafe(""), "")
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
