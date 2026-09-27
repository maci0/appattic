import XCTest
@testable import AppAtticScan

final class DatesTests: XCTestCase {
    func testParseMdlsDate() throws {
        XCTAssertNil(parseMdlsDate("(null)"))
        XCTAssertNil(parseMdlsDate(""))
        let parsed = try XCTUnwrap(parseMdlsDate("2026-08-15 00:56:17 +0000"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(cal.component(.year, from: parsed), 2026)
        XCTAssertEqual(cal.component(.month, from: parsed), 8)
        XCTAssertEqual(cal.component(.day, from: parsed), 15)
        XCTAssertEqual(cal.component(.hour, from: parsed), 0)
        XCTAssertEqual(cal.component(.minute, from: parsed), 56)
        XCTAssertEqual(cal.component(.second, from: parsed), 17)
    }

    /// The process-wide date formatters are shared objects, and Foundation's
    /// `date(from:)` / `string(from:)` mutate internal parse state, so the
    /// parallel mdls and ISO paths that `pmap` drives have to be safe. This
    /// hammers both formatters plus the ISO fallback list from 16 workers: an
    /// unsynchronized shared formatter drops or mangles parses under that load.
    func testDateParsingAndFormattingSurviveParallelPmapWorkers() {
        let n = 96
        let results = pmap(Array(0..<n), workers: 16) { i -> (Date?, Date?, String?) in
            let seconds = i * 7
            let mdls = parseMdlsDate(
                String(format: "2026-08-15 00:00:%02d +0000", seconds % 60)
            )
            // Space instead of "T": the integer fast path rejects it, so this
            // lands on the shared DateFormatter fallback list.
            let iso = parseISODate(
                String(format: "2026-08-15 00:00:%02d +0000", seconds % 60)
            )
            return (mdls, iso, isoString(mdls))
        }
        XCTAssertEqual(results.count, n)
        for i in 0..<n {
            let seconds = i * 7 % 60
            let mdls = try? XCTUnwrap(results[i].0, "mdls parse dropped at \(i)")
            let iso = try? XCTUnwrap(results[i].1, "ISO fallback parse dropped at \(i)")
            XCTAssertEqual(
                mdls.map { $0.timeIntervalSince1970.rounded() },
                iso.map { $0.timeIntervalSince1970.rounded() },
                "mdls and ISO disagree at \(i)"
            )
            XCTAssertNotNil(results[i].2, "isoString returned nil at \(i)")
        }
    }

    func testParseISODateAcceptsZAndOffset() throws {
        let z = try XCTUnwrap(parseISODate("2026-08-17T12:30:00Z"))
        let offset = try XCTUnwrap(parseISODate("2026-08-17T12:30:00+00:00"))
        XCTAssertEqual(z.timeIntervalSince1970, offset.timeIntervalSince1970, accuracy: 0.5)
        let round = try XCTUnwrap(parseISODate(isoString(z)))
        XCTAssertEqual(round.timeIntervalSince1970, z.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParseISODateFractionalMicrosecondsFromXBEL() throws {
        let micro = try XCTUnwrap(parseISODate("2026-04-01T15:00:00.123456Z"))
        let whole = try XCTUnwrap(parseISODate("2026-04-01T15:00:00Z"))
        XCTAssertEqual(micro.timeIntervalSince(whole), 0.123, accuracy: 0.001)
        XCTAssertNotNil(parseISODate("2026-04-01T15:00:00.000000Z"))
        XCTAssertNotNil(parseISODate("2026-04-01T15:00:00.123456+00:00"))
    }

    func testParseISODateTimezoneLessIsUTC() throws {
        let naive = try XCTUnwrap(parseISODate("2026-04-01T15:00:00"))
        let z = try XCTUnwrap(parseISODate("2026-04-01T15:00:00Z"))
        XCTAssertEqual(naive.timeIntervalSince1970, z.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParseISODateOffsetIsInstantNotWallClock() throws {
        let paris = try XCTUnwrap(parseISODate("2026-08-17T14:30:00+02:00"))
        let z = try XCTUnwrap(parseISODate("2026-08-17T12:30:00Z"))
        XCTAssertEqual(paris.timeIntervalSince1970, z.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParseISODateRejectsImpossibleCivilDate() {
        XCTAssertNil(parseISODate("2026-02-31T15:00:00"))
        XCTAssertNil(parseMdlsDate("2026-02-31 15:00:00 +0000"))
    }

    func testParseISODateUtcInstantIsPreviousLocalDayInNewYork() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dt = try XCTUnwrap(parseISODate("2026-03-08T04:30:00Z"))
        XCTAssertEqual(cal.component(.year, from: dt), 2026)
        XCTAssertEqual(cal.component(.month, from: dt), 3)
        XCTAssertEqual(cal.component(.day, from: dt), 7)
        XCTAssertEqual(cal.component(.hour, from: dt), 23)
    }

    func testDateFromUnixEpochScalesMillisAndMicros() {
        let seconds: TimeInterval = 1_717_200_000
        XCTAssertEqual(dateFromUnixEpoch(seconds).timeIntervalSince1970, seconds, accuracy: 0.5)
        XCTAssertEqual(dateFromUnixEpoch(seconds * 1_000).timeIntervalSince1970, seconds, accuracy: 0.5)
        XCTAssertEqual(dateFromUnixEpoch(seconds * 1_000_000).timeIntervalSince1970, seconds, accuracy: 0.5)
    }

    func testDaysSinceNil() {
        XCTAssertNil(daysSince(nil))
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        XCTAssertEqual(daysSince(now.addingTimeInterval(-3 * 86400), now: now), 3.0)
    }

    func testDaysSinceIsElapsedHoursNotCalendarDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twelveHours = now.addingTimeInterval(-12 * 3600)
        XCTAssertEqual(daysSince(twelveHours, now: now)!, 0.5, accuracy: 0.0001)
        XCTAssertNil(calendarDaysSince(nil))
    }

    func testCalendarDaysSinceSpringForwardIsYesterdayNotToday() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.timeZone = tz
        c.year = 2026; c.month = 3; c.day = 7; c.hour = 23; c.minute = 30
        let saturday = try XCTUnwrap(cal.date(from: c))
        c.day = 8; c.hour = 22; c.minute = 30
        let sunday = try XCTUnwrap(cal.date(from: c))
        XCTAssertLessThan(sunday.timeIntervalSince(saturday) / 86400, 1)
        XCTAssertEqual(calendarDaysSince(saturday, now: sunday, calendar: cal), 1)
    }

    func testCalendarDaysSinceFallBackSameDayStaysToday() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.timeZone = tz
        c.year = 2026; c.month = 11; c.day = 1; c.hour = 0; c.minute = 0
        let morning = try XCTUnwrap(cal.date(from: c))
        c.hour = 23; c.minute = 30
        let evening = try XCTUnwrap(cal.date(from: c))
        XCTAssertGreaterThan(evening.timeIntervalSince(morning) / 86400, 1)
        XCTAssertEqual(calendarDaysSince(morning, now: evening, calendar: cal), 0)
    }

    /// A recent timestamp gets a relative label, never the absolute date.
    /// Anchored in the current calendar so the assertion holds whatever TZ the
    /// test runs under.
    func testTimestampFormatUsesARelativeLabelWithinTheWindow() throws {
        let cal = Calendar.current
        let now = Date()
        var labels: [String] = []
        for daysAgo in [0, 1, 3, relativeDayLimit - 1] {
            let then = try XCTUnwrap(cal.date(byAdding: .day, value: -daysAgo, to: now))
            let label = TimestampFormat.string(from: then, now: now)
            XCTAssertFalse(label.isEmpty, "\(daysAgo) days ago")
            XCTAssertNotEqual(label, TimestampFormat.date.string(from: then), "\(daysAgo) days ago")
            XCTAssertEqual(
                TimestampFormat.string(from: then, now: now), label,
                "\(daysAgo) days ago is not stable across calls"
            )
            labels.append(label)
        }
        // Each age reads differently; a relative formatter stuck on one string
        // would leave every assertion above green.
        XCTAssertEqual(
            Set(labels).count, labels.count,
            "relative labels collapsed: \(labels)"
        )
    }

    /// The last relative day is `relativeDayLimit - 1`; the day after it is the
    /// first absolute one. Both sides of that exact edge are pinned, so moving
    /// the limit does not silently gain or lose a day of the window.
    func testTimestampFormatFlipsToTheDateExactlyAtTheRelativeLimit() throws {
        let cal = Calendar.current
        let now = Date()

        let lastRelative = try XCTUnwrap(
            cal.date(byAdding: .day, value: -(relativeDayLimit - 1), to: now)
        )
        XCTAssertNotEqual(
            TimestampFormat.string(from: lastRelative, now: now),
            TimestampFormat.date.string(from: lastRelative)
        )

        let firstAbsolute = try XCTUnwrap(
            cal.date(byAdding: .day, value: -relativeDayLimit, to: now)
        )
        XCTAssertEqual(
            TimestampFormat.string(from: firstAbsolute, now: now),
            TimestampFormat.date.string(from: firstAbsolute)
        )
    }

    /// Past the relative window the absolute date is shown, and it comes from
    /// the locale's own date style rather than a hardcoded `yyyy-MM-dd`.
    func testTimestampFormatFallsBackToDatePastTheRelativeWindow() throws {
        let cal = Calendar.current
        let now = Date()
        let old = try XCTUnwrap(cal.date(byAdding: .day, value: -(relativeDayLimit + 10), to: now))
        XCTAssertEqual(TimestampFormat.string(from: old, now: now), TimestampFormat.date.string(from: old))
    }

    /// A timestamp past now (a restored archive, a file written while the clock
    /// was ahead) has no relative form: it shows its date, inside the window.
    func testTimestampFormatFallsBackToDateForAFutureTimestamp() throws {
        let cal = Calendar.current
        let now = Date()
        let ahead = try XCTUnwrap(cal.date(byAdding: .day, value: 3, to: now))
        XCTAssertEqual(calendarDaysSince(ahead, now: now), -3)
        XCTAssertEqual(TimestampFormat.string(from: ahead, now: now), TimestampFormat.date.string(from: ahead))
    }

    /// A language switch reaches the display formatters without a restart.
    /// `DateFormatter` keeps the locale it was built with, so a formatter held
    /// from the first call answers in the old language for the rest of the
    /// session: German reads "25.02.2026", English "Feb 25, 2026".
    ///
    /// Darwin only: swift-corelibs-foundation declares `Locale.current`
    /// get-only, so there is no way to switch it and nothing to assert.
    #if canImport(Darwin)
    func testTimestampFormatFollowsALocaleChange() {
        let saved = Locale.current
        defer { Locale.current = saved }
        let instant = Date(timeIntervalSince1970: 1_772_000_000)
        Locale.current = Locale(identifier: "en_US")
        let english = TimestampFormat.date.string(from: instant)
        Locale.current = Locale(identifier: "de_DE")
        let german = TimestampFormat.date.string(from: instant)
        XCTAssertNotEqual(english, german, "the date formatter kept the old locale")
    }
    #endif
}
