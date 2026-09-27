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
}
