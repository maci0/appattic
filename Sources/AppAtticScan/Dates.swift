import Foundation
/// Truncate ISO-8601 fractional seconds so `ISO8601DateFormatter` can parse
/// GTK/GNOME timestamps that carry microseconds (`…T15:00:00.123456Z`).
func truncateISOFractionalSeconds(_ s: String, maxDigits: Int = 3) -> String {
    guard let tIndex = s.firstIndex(of: "T") else { return s }
    guard let dot = s[tIndex...].firstIndex(of: ".") else { return s }
    var digitEnd = s.index(after: dot)
    var count = 0
    // ASCII digits, the form ISO-8601 and the Qt twin in `finding.cpp` both
    // spell. `Character.isNumber` is Unicode Nd|Nl|No, so a fraction written
    // in Arabic-Indic digits would be counted here and cut mid-run, leaving a
    // mixed-script fraction the formatter then rejects outright.
    while digitEnd < s.endIndex, s[digitEnd].isASCII, s[digitEnd].isNumber {
        count += 1
        digitEnd = s.index(after: digitEnd)
    }
    if count <= maxDigits { return s }
    let keepEnd = s.index(dot, offsetBy: 1 + maxDigits)
    return String(s[..<keepEnd]) + String(s[digitEnd...])
}

/// Configured once and never mutated, so concurrent `date(from:)` is safe.
private let isoFractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoBasicFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let isoFallbackFormats = [
    "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
    "yyyy-MM-dd'T'HH:mm:ssZ",
    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    "yyyy-MM-dd HH:mm:ss Z",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm:ss.SSS",
]

/// One formatter per format, built once. `dateFormat` is never mutated after this,
/// so parallel parses do not race on shared mutable state.
private let isoFallbackFormatters: [DateFormatter] = isoFallbackFormats.map { fmt in
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.isLenient = false
    f.dateFormat = fmt
    return f
}

public func parseISODate(_ value: String?) -> Date? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    // Contiguous UTF-8 fast path. Bridged NSStrings are discontiguous, so copy
    // the bytes once rather than falling into the ~25 µs formatter path.
    if let fast = raw.utf8.withContiguousStorageIfAvailable({ isoFastParse($0) }) ?? nil {
        return fast
    }
    return raw.withCString { cstr in
        let n = strlen(cstr)
        guard n >= 19, n < 4096 else { return parseISODateViaFormatters(raw) }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: n) { buf in
            var p = cstr
            for k in 0..<n {
                buf[k] = UInt8(bitPattern: p.pointee)
                p = p.successor()
            }
            return isoFastParse(UnsafeBufferPointer(start: buf.baseAddress, count: n))
                ?? parseISODateViaFormatters(raw)
        }
    }
}

/// Direct parse of the ISO-8601 shapes the formatters above accept, by integer
/// arithmetic. `parseISODate` spent 23 µs per call building variant strings and
/// trying up to nine formatters.
///
/// Only unambiguous, well-formed input is accepted; everything else returns nil
/// so the formatter path stays authoritative: unknown widths, out-of-range
/// fields, day-overflow for the month (where the formatters may roll over or
/// reject), lowercase `t`, and offsets beyond ±14:00.
func isoFastParse(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
    let n = b.count
    guard n >= 19 else { return nil }
    guard let year = isoDigits(b, 0, 4), b[4] == 0x2D,
          let month = isoDigits(b, 5, 2), b[7] == 0x2D,
          let day = isoDigits(b, 8, 2), b[10] == 0x54,
          let hour = isoDigits(b, 11, 2), b[13] == 0x3A,
          let minute = isoDigits(b, 14, 2), b[16] == 0x3A,
          let second = isoDigits(b, 17, 2)
    else { return nil }
    guard year >= 1, month >= 1, month <= 12, hour <= 23, minute <= 59, second <= 59,
          day >= 1, day <= isoDaysInMonth(year, month)
    else { return nil }

    var i = 19
    var millis = 0
    if i < n, b[i] == 0x2E {
        i += 1
        let first = i
        while i < n, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        let digits = i - first
        guard digits >= 1 else { return nil }
        // ISO8601DateFormatter truncates to milliseconds, it does not round.
        for k in 0..<3 {
            millis = millis * 10 + (k < digits ? Int(b[first + k] - 0x30) : 0)
        }
    }

    var offset = 0
    if i < n {
        let c = b[i]
        if c == 0x5A || c == 0x7A {
            i += 1
            guard i == n else { return nil }
        } else if c == 0x2B || c == 0x2D {
            let sign = c == 0x2D ? -1 : 1
            i += 1
            guard let oh = isoDigits(b, i, 2), oh <= 14 else { return nil }
            i += 2
            var om = 0
            if i < n, b[i] == 0x3A {
                i += 1
                guard let m = isoDigits(b, i, 2) else { return nil }
                om = m
                i += 2
            } else if i < n, b[i] >= 0x30, b[i] <= 0x39 {
                guard let m = isoDigits(b, i, 2) else { return nil }
                om = m
                i += 2
            }
            guard i == n, om <= 59, oh < 14 || om == 0 else { return nil }
            offset = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
    }

    let days = isoDaysFromCivil(year, month, day)
    let epoch = days * 86400 + hour * 3600 + minute * 60 + second - offset
    let base = Double(epoch)
    return Date(timeIntervalSince1970: millis == 0 ? base : base + Double(millis) / 1000.0)
}

@inline(__always)
private func isoDigits(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ len: Int) -> Int? {
    guard i + len <= b.count else { return nil }
    var v = 0
    for k in 0..<len {
        let c = b[i + k]
        guard c >= 0x30, c <= 0x39 else { return nil }
        v = v * 10 + Int(c - 0x30)
    }
    return v
}

private func isoDaysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2:
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return leap ? 29 : 28
    case 4, 6, 9, 11:
        return 30
    default:
        return 31
    }
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01, proleptic Gregorian.
private func isoDaysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

func parseISODateViaFormatters(_ raw: String) -> Date? {
    func tryISO(_ s: String) -> Date? {
        isoFractionalFormatter.date(from: s) ?? isoBasicFormatter.date(from: s)
    }

    var variants: [String] = []
    func add(_ s: String) {
        if !s.isEmpty, !variants.contains(s) { variants.append(s) }
    }
    add(raw)
    let truncated = truncateISOFractionalSeconds(raw)
    if truncated != raw { add(truncated) }
    for base in Array(variants) {
        if base.hasSuffix("Z") || base.hasSuffix("z") {
            let stem = String(base.dropLast())
            add(stem + "+00:00")
            add(stem + "Z")
        }
        if base.hasSuffix("+00:00") {
            add(String(base.dropLast(6)) + "Z")
        }
    }

    for s in variants {
        if let d = tryISO(s) { return d }
    }

    for s in variants {
        for f in isoFallbackFormatters {
            if let d = f.date(from: s) { return d }
        }
    }
    return nil
}

/// Configured once and never mutated, so concurrent `string(from:)` is safe.
private let isoStringFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

public func isoString(_ date: Date?) -> String? {
    guard let date else { return nil }
    return isoStringFormatter.string(from: date)
}

/// Instant from a Unix epoch that may be seconds, milliseconds, or microseconds.
/// GNOME `last-seen` is seconds, but `g_get_real_time()` is microseconds; mixing
/// those units would put last-used in year 56 million and look like "used now".
public func dateFromUnixEpoch(_ raw: TimeInterval) -> Date {
    let mag = abs(raw)
    if mag > 1e14 {
        return Date(timeIntervalSince1970: raw / 1_000_000)
    }
    if mag > 1e11 {
        return Date(timeIntervalSince1970: raw / 1_000)
    }
    return Date(timeIntervalSince1970: raw)
}

/// Elapsed-time source for walk budgets and scan duration. Read through a
/// parameter so a test or a replayed run can step it instead of racing the
/// system uptime: a walk that finishes on a fast host but not on a loaded one
/// reports a different size and a different leftover status.
public typealias MonotonicFn = () -> TimeInterval

public func monotonicSeconds() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

/// Whole local calendar days from `date` to `now` (0 = same local day).
/// Use for "Today"/"Yesterday" labels. Idle thresholds keep `daysSince` (elapsed).
public func calendarDaysSince(
    _ date: Date?,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Int? {
    guard let date else { return nil }
    let from = calendar.startOfDay(for: date)
    let to = calendar.startOfDay(for: now)
    return calendar.dateComponents([.day], from: from, to: to).day
}


/// One formatter, built once. `dateFormat` is never mutated after this,
/// so parallel parses do not race on shared mutable state.
private let mdlsDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.isLenient = false
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f
}()

public func parseMdlsDate(_ value: String) -> Date? {
    var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    if v.isEmpty || v == "(null)" { return nil }
    return mdlsDateFormatter.date(from: v)
}

public func daysSince(_ date: Date?, now: Date = Date()) -> Double? {
    guard let date else { return nil }
    return max(0, now.timeIntervalSince(date) / 86400)
}

/// Day count past which a timestamp shows its date instead of a relative label.
public let relativeDayLimit = 45

/// The display pair (`TimestampFormat`) for one `Locale.current` and one
/// `TimeZone.current`.
///
/// A `DateFormatter` keeps both the locale and the zone it was built with, so a
/// pair built on the first call would print the old language and the old zone
/// for the rest of the session after the user switches either one. Building
/// both on every call is too expensive for a table that formats a row per
/// frame, so the pair is cached and replaced when either changes.
///
/// The zone is part of the key, not a detail, because both halves of
/// `string(from:now:)` have to read it: the day count and the fallback date
/// decide "today" in the same zone. A process that outlives a zone change (a
/// laptop crossing a border, a `TZ` change under a running CLI) would otherwise
/// decide "today" in the new zone and print the date in the old one, and the two
/// disagree by a day for every row near local midnight. `string(from:now:)`
/// takes the same pair for the same reason.
final class LocaleScopedTimestamps {
    private let lock = NSLock()
    private var localeID: String?
    private var zoneID: String?
    private var dateFormatter: DateFormatter?
    private var relativeClosure: ((Date, Date) -> String?)?

    /// The formatters for one locale and zone, rebuilt when either changes.
    ///
    /// The pair is a parameter and not read inside because `Locale.current` and
    /// `TimeZone.current` are get-only on Darwin and in swift-corelibs-foundation
    /// alike: nothing in a test can switch either one, so the cache key is handed
    /// in and the rebuild can be checked. Callers pass the process values, which
    /// is what the defaults read at each call.
    func current(
        locale: Locale = .current,
        zone: TimeZone = .current
    ) -> (date: DateFormatter, relativeDays: ((Date, Date) -> String?)?) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = dateFormatter,
           localeID == locale.identifier,
           zoneID == zone.identifier {
            return (cached, relativeClosure)
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = locale
        f.timeZone = zone
        #if canImport(Darwin)
        // `RelativeDateTimeFormatter`, not `DateComponentsFormatter`: the
        // recipe for a named relative day — "yesterday", "in 3 days" — is
        // `dateTimeStyle = .named`, and `UnitsStyle` has no `named` member for
        // the components formatter to take. The relative formatter has no
        // `allowedUnits` or `maximumUnitCount` either; `.named` is the style
        // that reads as the day label on its own. corelibs-foundation leaves
        // this formatter unimplemented, which is why the arm is Darwin's.
        let r = RelativeDateTimeFormatter()
        r.dateTimeStyle = .named
        r.unitsStyle = .full
        let relative: ((Date, Date) -> String?)? = { r.localizedString(for: $0, relativeTo: $1) }
        #else
        let relative: ((Date, Date) -> String?)? = nil
        #endif
        dateFormatter = f
        relativeClosure = relative
        localeID = locale.identifier
        zoneID = zone.identifier
        return (f, relative)
    }
}

/// Locale-aware timestamps for every surface that shows one.
///
/// `medium` and `named` carry the locale's own month and day names, its date
/// order, and its plural rules (Polish has five forms, Arabic six), which a
/// hardcoded `yyyy-MM-dd` plus "N days ago" cannot. Both formatters read
/// `Locale.current` on each call, so a `LC_ALL` change reaches them on the
/// next one.
public enum TimestampFormat {
    private static let scoped = LocaleScopedTimestamps()

    /// Absolute date, no time. `dateStyle` rather than `dateFormat`, so the
    /// pattern and the era come from CLDR instead of a fixed template.
    /// Internal: a public formatter would hand every target a handle to
    /// reconfigure a shared, process-wide object. Callers use `string(from:)`.
    static var date: DateFormatter { scoped.current().date }

    /// "Today", "Yesterday", "3 days ago", localized and correctly pluralized.
    ///
    /// swift-corelibs-foundation declares `DateComponentsFormatter` without
    /// implementing it, so the value is nil there and `string(from:now:)`
    /// falls back to the ASCII day unit. The type is erased into a closure so
    /// the name does not appear in this file's signatures off Darwin.
    static var relativeDays: ((Date, Date) -> String?)? { scoped.current().relativeDays }

    /// A relative label within `relativeDayLimit` days, otherwise the date.
    /// Falls back to the date whenever the age cannot be measured or is
    /// negative, so an out-of-range or future timestamp (a restored archive, a
    /// file written while the clock was ahead) never renders as an empty cell
    /// or claims to have changed today.
    ///
    /// `locale` and `zone` decide the day count as well as the printed date:
    /// both halves read the pair handed in, so a caller that pins them (a
    /// replayed run, a test) gets the same answer on every host. The defaults
    /// are the process values.
    public static func string(
        from date: Date,
        now: Date = Date(),
        locale: Locale = .current,
        zone: TimeZone = .current
    ) -> String {
        // One snapshot of the locale-scoped pair, so the date and the relative
        // label cannot come from two different locales.
        let formatters = scoped.current(locale: locale, zone: zone)
        // The day count in that same zone rather than `Calendar.current`: a
        // relative label decided in one zone beside a date printed in another
        // disagrees by a day for any timestamp near local midnight.
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = zone
        guard let days = calendarDaysSince(date, now: now, calendar: calendar),
              days >= 0, days < relativeDayLimit else {
            return formatters.date.string(from: date)
        }
        // Anchor both ends at local midnight so the interval is a whole number
        // of days, including across a daylight-saving change.
        let today = calendar.startOfDay(for: now)
        guard let then = calendar.date(byAdding: .day, value: -days, to: today) else {
            return formatters.date.string(from: date)
        }
        guard let relativeDays = formatters.relativeDays,
              let label = relativeDays(then, today) else { return "\(days) d" }
        return label
    }
}
