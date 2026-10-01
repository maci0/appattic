import Foundation
/// Saturating sum for non-negative byte totals. Overflow becomes Int.max.
public func addBytes(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
}

/// Saturating product for non-negative byte totals. Overflow becomes Int.max.
public func mulBytes(_ a: Int, _ b: Int) -> Int {
    let (product, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? Int.max : product
}

/// Decimal separator of `Locale.current`. `String(format:)` pays for locale
/// setup on every call (~1.2 µs), so the separator is cached, but only against
/// the locale it was read from: a `NumberFormatter` keeps the locale it was
/// built with, so a value read once at startup would keep the old separator
/// for the rest of the session after the user switches language.
private let decimalSeparatorLock = NSLock()
private var cachedDecimalSeparator: (locale: String, separator: String)?

var localeDecimalSeparator: String {
    decimalSeparatorLock.lock()
    defer { decimalSeparatorLock.unlock() }
    let id = Locale.current.identifier
    if let cached = cachedDecimalSeparator, cached.locale == id { return cached.separator }
    let f = NumberFormatter()
    f.locale = .current
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    let separator = f.decimalSeparator ?? "."
    cachedDecimalSeparator = (id, separator)
    return separator
}

/// Cached against the locale it was built from, for the reason
/// `localeDecimalSeparator` above gives, and used under the same lock since a
/// `NumberFormatter` is not safe to drive from two threads at once.
private let countFormatterLock = NSLock()
private var cachedCountFormatter: (locale: String, formatter: NumberFormatter)?

/// A whole count in `Locale.current`'s own grouping. `"\(n)"` interpolates
/// without reading the locale, so a German report prints "1234 items" where
/// "1.234 Elemente" belongs, and every locale gets ASCII digits regardless of
/// what its own number formatting uses. The Qt shell has the same helper
/// under the same name, so both windows label one scan the same way.
public func localeCount(_ n: Int) -> String {
    countFormatterLock.lock()
    defer { countFormatterLock.unlock() }
    let id = Locale.current.identifier
    let formatter: NumberFormatter
    if let cached = cachedCountFormatter, cached.locale == id {
        formatter = cached.formatter
    } else {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        cachedCountFormatter = (id, f)
        formatter = f
    }
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// One decimal place without `String(format:)` (~1.2 µs/call from locale +
/// varargs overhead). Rounds half away from zero, where `%.1f` rounds half to
/// even, so the two differ on an exact tie and agree everywhere else.
func oneDecimal(_ n: Double) -> String {
    let neg = n < 0
    let tenths = Int((abs(n) * 10).rounded())
    return (neg ? "-" : "") + "\(tenths / 10)\(localeDecimalSeparator)\(tenths % 10)"
}

/// Binary-unit size, one decimal above KB. Bytes print as an exact integer.
/// A negative count is a size nobody measured, not a size below zero, so it
/// reads as "unknown": the same word the Qt `humanSize` twin prints for the
/// same value. The unit loop below would otherwise print "-1.9 MB" for it, and
/// `abs` there would make the sign survive every division.
public func humanSize(_ bytes: Int) -> String {
    if bytes < 0 { return "unknown" }
    // Past the largest unit the loop stops, so the unit list has to reach the
    // size `Int.max` saturates at (8 EiB), not stop at PB and print 8192 PB.
    let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
    var n = Double(bytes)
    var unit = 0
    while unit < units.count - 1 {
        if abs(n) < 1024 {
            // %.1f can round 1023.95 to 1024.0; bump the unit instead of printing "1024.0 KB".
            if (abs(n) * 10).rounded() / 10 >= 1024 {
                n /= 1024
                unit += 1
                continue
            }
            if unit == 0 { return "\(bytes) B" }
            return oneDecimal(n) + " " + units[unit]
        }
        n /= 1024
        unit += 1
    }
    return oneDecimal(n) + " " + units[unit]
}

/// Whole-day age, with the unit chosen by magnitude: hours below 1 day (at
/// least 1h, so a future or fractional value never prints a zero count), days
/// below 14, weeks below 28 days, months below a year, then years. Every
/// bucket keeps at least one of its unit. The unit changes silently with the
/// input, so a caller comparing formatted strings across a threshold gets a
/// different unit, not a different number.
///
/// The count and the unit word are the locale's: Polish has four plural forms
/// for a week, Arabic six for a day, and neither can come out of a `"\(n)d"`
/// built from an `if`. Years are whole, because a plural-aware formatter takes
/// an integer count.
public func humanDays(_ days: Double) -> String {
    if days < 1 {
        return duration(.hour, max(Int(days * 24), 1))
    }
    if days < 28 {
        return days >= 14 ? duration(.weekOfMonth, Int(days / 7)) : duration(.day, Int(days))
    }
    if days < 365 {
        // `Int` truncates, so the 28 to 29 days that enter this branch divide
        // to zero and printed as "0 mo". At least 1 month, the same floor the
        // hour branch above keeps.
        return duration(.month, max(Int(days / 30), 1))
    }
    return duration(.year, Int((days / 365).rounded()))
}

/// One formatter per unit, built once and never mutated, so parallel calls are
/// safe. `DateComponents` carries the count, so a month stays a month instead
/// of being reconciled against a fixed number of days.
///
/// swift-corelibs-foundation declares `DateComponentsFormatter` but leaves it
/// unimplemented, so the table is empty there and `duration` below takes its
/// ASCII fallback for every unit. The formatter type is erased into a closure so
/// it does not appear in this file's signatures off Darwin.
private let durationFormatters: [Calendar.Component: (DateComponents) -> String?] = {
    #if canImport(Darwin)
    var formatters: [Calendar.Component: (DateComponents) -> String?] = [:]
    // Each unit with the calendar unit that names it: `allowedUnits` is an
    // `NSCalendar.Unit`, and there is no `DateComponentsFormatter.Units` for the
    // loop to build an empty set of. The pairs also give the array its type, so
    // the literal does not leave the element type to be decided by the loop
    // body.
    //
    // The week is `weekOfMonth`, not `weekOfYear`. `allowedUnits` accepts only
    // year, month, weekOfMonth, day, hour, minute and second; any other bit
    // raises NSInternalInconsistencyException from the setter, so a fortnight
    // would abort the process instead of rendering. `DateComponents` carries
    // the same unit below, so the count is the field the formatter reads.
    let units: [(component: Calendar.Component, allowed: NSCalendar.Unit)] = [
        (.hour, .hour), (.day, .day), (.weekOfMonth, .weekOfMonth), (.month, .month), (.year, .year),
    ]
    for unit in units {
        let f = DateComponentsFormatter()
        f.allowedUnits = unit.allowed
        f.unitsStyle = .abbreviated
        formatters[unit.component] = { f.string(from: $0) }
    }
    return formatters
    #else
    return [:]
    #endif
}()

/// Abbreviations for a locale that has no data for the unit, so a missing CLDR
/// entry costs the reader the localized word and not the whole label.
private let asciiDurationUnits: [Calendar.Component: String] = [
    .hour: "h", .day: "d", .weekOfMonth: "w", .month: "mo", .year: "y",
]

private func duration(_ unit: Calendar.Component, _ count: Int) -> String {
    var components = DateComponents()
    components.setValue(count, for: unit)
    if let text = durationFormatters[unit]?(components) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
    }
    return "\(count) \(asciiDurationUnits[unit] ?? "")"
}
