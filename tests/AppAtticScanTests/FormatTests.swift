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

    /// One decimal place as the current locale writes it, grouping off. The
    /// size fraction is formatted through a locale-aware formatter now, so the
    /// expectation has to be one too: a hand-built "1.0" would only hold on a
    /// machine whose locale uses an ASCII dot and Latin digits.
    private func expectedOneDecimal(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func testHumanSize() {
        // Sizes print the locale's decimal separator, so the fraction is
        // rebuilt from it rather than hardcoded as ".". 1023 bytes is past the
        // grouping threshold in most locales, so the byte case is the grouped
        // count rather than a literal: under a German or English locale it
        // reads "1.023 B" / "1,023 B", and an ungrouped assertion there would
        // be a claim about the C locale the suite is pinned to, not about the
        // code.
        let dot = expectedDecimalSeparator()
        XCTAssertEqual(localeDecimalSeparator, dot)
        XCTAssertEqual(humanSize(0), "0 B")
        XCTAssertEqual(humanSize(1023), localeCount(1023) + " B")
        XCTAssertEqual(humanSize(1024), "1\(dot)0 KB")
        XCTAssertEqual(humanSize(1_048_576), "1\(dot)0 MB")
        // 1048525 / 1024 = 1023.95, which %.1f would print as "1024.0 KB".
        XCTAssertEqual(humanSize(1_048_525), "1\(dot)0 MB")
        XCTAssertEqual(humanSize(1023 * 1024), "1023\(dot)0 KB")
    }

    func testHumanSizeFractionUsesTheLocaleDigits() {
        // The fraction used to be interpolated as ASCII while the whole part
        // beside it came out localized, so an Arabic window read "1.0 MB" in
        // Latin digits next to a count in Arabic-Indic ones. The expectation
        // comes from a formatter built for the same locale, so the check holds
        // on a machine whose locale is not Latin-digit.
        XCTAssertEqual(humanSize(1_048_576), expectedOneDecimal(1.0) + " MB")
        XCTAssertEqual(humanSize(1023 * 1024), expectedOneDecimal(1023.0) + " KB")
    }

    func testHumanSizeByteCaseIsGroupedLikeEveryOtherCount() {
        // The byte unit is the one every locale groups ("1.023 B" in German,
        // "1,023 B" in English, "١٬٠٢٣ B" in Arabic), and the Qt `humanSize`
        // twin prints the same grouped count for the same value, so an
        // ungrouped byte count here made the two windows disagree about one
        // scan. 1023 is past the grouping threshold in most locales and under
        // it in a few (Polish), so the expectation is the grouped count read
        // back from a formatter rather than a literal that is only true in the
        // C locale the suite is pinned to.
        XCTAssertEqual(humanSize(0), localeCount(0) + " B")
        XCTAssertEqual(humanSize(1023), localeCount(1023) + " B")
        // Below the threshold the value is its own digits, which is the check
        // that grouping did not leak into the low range on a locale that does
        // not group there.
        if localeCount(999) == "999" {
            XCTAssertEqual(humanSize(999), "999 B")
        }
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

    func testHumanSizeNeverPrintsANegativeSize() {
        // `size_bytes` comes off the JSON a scan writes and any other tool (or
        // hand) can edit, and nothing on the way in clamps its sign. A negative
        // one is a size nobody measured, and the loop divides by 1024 with
        // `abs`, so the sign used to survive every step and the row read
        // "-1.9 MB" while the Qt window printed "unknown" for the same value.
        XCTAssertEqual(humanSize(-1), "unknown")
        XCTAssertEqual(humanSize(-1023), "unknown")
        XCTAssertEqual(humanSize(-5000), "unknown")
        XCTAssertEqual(humanSize(-2_000_000), "unknown")
        XCTAssertEqual(humanSize(Int.min), "unknown")
        // Nothing below zero reaches the unit loop, so no size carries a sign.
        for size in [-1, -1_048_576, Int.min] {
            XCTAssertFalse(humanSize(size).contains("-"), "\(size) -> \(humanSize(size))")
        }
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
