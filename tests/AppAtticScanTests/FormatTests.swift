import Foundation
import XCTest
@testable import AppAtticScan

final class FormatTests: XCTestCase {
    /// The decimal separator, read from a formatter built here rather than
    /// from `localeDecimalSeparator`. That value is cached per locale, and
    /// `humanSize` renders through the same cache, so comparing one against
    /// the other checks only that the two agree with themselves: a separator
    /// cached from an earlier locale would pass. This is the independent read
    /// the cache has to agree with.
    private func expectedDecimalSeparator() -> String {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.decimalSeparator ?? "."
    }

    /// The count as the current locale writes it. `humanDays` renders through
    /// `DateComponentsFormatter`, which localizes the digits too, so an
    /// ASCII literal like "12" is an assertion about the machine running the
    /// suite rather than about the code.
    private func expectedCount(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    func testHumanSize() {
        // Sizes print the locale's decimal separator, so the fraction is
        // rebuilt from it rather than hardcoded as ".".
        let dot = expectedDecimalSeparator()
        XCTAssertEqual(localeDecimalSeparator, dot)
        XCTAssertEqual(humanSize(0), "0 B")
        XCTAssertEqual(humanSize(1023), "1023 B")
        XCTAssertEqual(humanSize(1024), "1\(dot)0 KB")
        XCTAssertEqual(humanSize(1_048_576), "1\(dot)0 MB")
        // 1048525 / 1024 = 1023.95, which %.1f would print as "1024.0 KB".
        XCTAssertEqual(humanSize(1_048_525), "1\(dot)0 MB")
        XCTAssertEqual(humanSize(1023 * 1024), "1023\(dot)0 KB")
    }

    func testLocaleCount() {
        // A count carries the locale's grouping, so 1234567 reads "1.234.567"
        // in German and "1,234,567" in English. The expectation comes from a
        // formatter built for the same locale rather than from a literal, so
        // the check holds on a machine whose locale is neither of those.
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        XCTAssertEqual(localeCount(1234567), f.string(from: NSNumber(value: 1234567)))
        XCTAssertEqual(localeCount(-1234), f.string(from: NSNumber(value: -1234)))
        XCTAssertEqual(localeCount(0), f.string(from: NSNumber(value: 0)))
        // Below the grouping threshold the value is its own digits, which is
        // what every count in a small report prints.
        XCTAssertEqual(localeCount(2), "2")
    }

    func testAddBytesSaturates() {
        XCTAssertEqual(addBytes(10, 20), 30)
        XCTAssertEqual(addBytes(Int.max, 1), Int.max)
        XCTAssertEqual(addBytes(Int.max, Int.max), Int.max)
    }

    func testMulBytesSaturates() {
        // Feeds every allocated-size and free-space total (blocks x bytes per
        // block), where an overflow that wrapped instead of saturating would
        // report a wrong disk size rather than an obviously huge one.
        XCTAssertEqual(mulBytes(0, 512), 0)
        XCTAssertEqual(mulBytes(8, 512), 4096)
        XCTAssertEqual(mulBytes(Int.max, 1), Int.max)
        XCTAssertEqual(mulBytes(Int.max, 2), Int.max)
        XCTAssertEqual(mulBytes(2, Int.max), Int.max)
        XCTAssertEqual(mulBytes(512, 8), 4096)
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
        XCTAssertTrue(hour.hasPrefix(expectedCount(12)), "0.5d -> \(hour)")
        XCTAssertTrue(day.hasPrefix(expectedCount(3)), "3d -> \(day)")
        XCTAssertTrue(week.hasPrefix(expectedCount(2)), "20d -> \(week)")
        XCTAssertTrue(month.hasPrefix(expectedCount(1)), "45d -> \(month)")
        XCTAssertTrue(year.hasPrefix(expectedCount(1)), "400d -> \(year)")
        let buckets = [hour, day, week, month, year]
        XCTAssertEqual(Set(buckets).count, buckets.count, "unit buckets collapsed: \(buckets)")
    }

    func testHumanDaysNeverPrintsAZeroCount() {
        // A future or sub-day timestamp clamps to a whole hour, so the label
        // never reads as zero of anything.
        let clamped = [-3.0, 0.0, 0.04].map { humanDays($0) }
        for label in clamped {
            XCTAssertTrue(label.hasPrefix(expectedCount(1)), "clamped label -> \(label)")
        }
        XCTAssertEqual(Set(clamped).count, 1, "negative, zero, and sub-day must all clamp alike")
        // 28 days is the first month, and 28 / 30 truncates to zero months.
        for label in [humanDays(28.0), humanDays(28.9)] {
            XCTAssertTrue(label.hasPrefix(expectedCount(1)), "month floor -> \(label)")
        }
    }
}
