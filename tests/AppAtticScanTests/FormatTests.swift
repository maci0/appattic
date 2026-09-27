import XCTest
@testable import AppAtticScan

final class FormatTests: XCTestCase {
    func testHumanSize() {
        // Sizes print the locale's decimal separator, so the fraction is
        // rebuilt from it rather than hardcoded as ".".
        let dot = localeDecimalSeparator
        XCTAssertEqual(humanSize(0), "0 B")
        XCTAssertEqual(humanSize(1023), "1023 B")
        XCTAssertEqual(humanSize(1024), "1\(dot)0 KB")
        XCTAssertEqual(humanSize(1_048_576), "1\(dot)0 MB")
        // 1048525 / 1024 = 1023.95, which %.1f would print as "1024.0 KB".
        XCTAssertEqual(humanSize(1_048_525), "1\(dot)0 MB")
        XCTAssertEqual(humanSize(1023 * 1024), "1023\(dot)0 KB")
    }


    func testAddBytesSaturates() {
        XCTAssertEqual(addBytes(10, 20), 30)
        XCTAssertEqual(addBytes(Int.max, 1), Int.max)
        XCTAssertEqual(addBytes(Int.max, Int.max), Int.max)
    }


    func testHumanDays() {
        // The unit word and its plural form come from the locale, so a label is
        // pinned as "a count with a unit", not as English text.
        for days in [0.0, 0.5, 3.0, 21.0, 45.0, 400.0] {
            let label = humanDays(days)
            XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty, "\(days)")
            XCTAssertTrue(label.contains { $0.isNumber }, "\(days) -> \(label)")
        }
    }

    func testHumanDaysNeverPrintsAZeroCount() {
        // A future or sub-day timestamp clamps to a whole hour, so the label
        // never reads as zero of anything.
        for days in [-3.0, 0.0, 0.04] {
            let label = humanDays(days)
            XCTAssertFalse(label.hasPrefix("0"), "\(days) -> \(label)")
        }
    }
}
