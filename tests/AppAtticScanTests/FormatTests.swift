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
        // The unit word and its plural form come from the locale, so a bucket is
        // pinned by the count it renders and by staying distinct from the
        // neighbouring buckets. A `/7` month, a 200-day app printed as "0 years",
        // or two buckets collapsing onto one word all break this.
        let hour = humanDays(0.5)     // 12 h
        let day = humanDays(3.0)      // 3 d
        let week = humanDays(20.0)    // 2 wk
        let month = humanDays(45.0)   // 1 mo
        let year = humanDays(400.0)   // 1 yr
        XCTAssertTrue(hour.hasPrefix("12"), "0.5d -> \(hour)")
        XCTAssertTrue(day.hasPrefix("3"), "3d -> \(day)")
        XCTAssertTrue(week.hasPrefix("2"), "20d -> \(week)")
        XCTAssertTrue(month.hasPrefix("1"), "45d -> \(month)")
        XCTAssertTrue(year.hasPrefix("1"), "400d -> \(year)")
        let buckets = [hour, day, week, month, year]
        XCTAssertEqual(Set(buckets).count, buckets.count, "unit buckets collapsed: \(buckets)")
    }

    func testHumanDaysNeverPrintsAZeroCount() {
        // A future or sub-day timestamp clamps to a whole hour, so the label
        // never reads as zero of anything.
        let clamped = [-3.0, 0.0, 0.04].map { humanDays($0) }
        for label in clamped {
            XCTAssertTrue(label.hasPrefix("1"), "clamped label -> \(label)")
        }
        XCTAssertEqual(Set(clamped).count, 1, "negative, zero, and sub-day must all clamp alike")
    }
}
