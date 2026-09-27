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
        XCTAssertEqual(humanDays(0), "1h")
        XCTAssertEqual(humanDays(0.5), "12h")
        XCTAssertEqual(humanDays(3), "3d")
        XCTAssertEqual(humanDays(21), "3w")
    }
}
