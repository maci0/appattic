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

/// One decimal place without `String(format:)` (~1.2 µs/call from locale +
/// varargs overhead). Rounds half away from zero the way `%.1f` prints.
func oneDecimal(_ n: Double) -> String {
    let neg = n < 0
    let tenths = Int((abs(n) * 10).rounded())
    return (neg ? "-" : "") + "\(tenths / 10)\(localeDecimalSeparator)\(tenths % 10)"
}

/// Binary-unit size, one decimal above KB. Bytes print as an exact integer.
public func humanSize(_ bytes: Int) -> String {
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
/// below 14, weeks below 60 days, months below 1.5 years, then years. The unit
/// changes silently with the input, so a caller comparing formatted strings
/// across a threshold gets a different unit, not a different number.
///
/// The count and the unit word are the locale's: Polish has four plural forms
/// for a week, Arabic six for a day, and neither can come out of a `"\(n)d"`
/// built from an `if`. Years are whole, because a plural-aware formatter takes
/// an integer count.
public func humanDays(_ days: Double) -> String {
    if days < 1 {
        return duration(.hour, max(Int(days * 24), 1))
    }
    if days < 60 {
        return days >= 14 ? duration(.weekOfYear, Int(days / 7)) : duration(.day, Int(days))
    }
    if days < 365 * 1.5 {
        return duration(.month, Int(days / 30))
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
    for unit in [.hour, .day, .weekOfYear, .month, .year] {
        let f = DateComponentsFormatter()
        var allowed: DateComponentsFormatter.Units = []
        allowed.insert(unit)
        f.allowedUnits = allowed
        f.unitsStyle = .abbreviated
        formatters[unit] = { f.string(from: $0) }
    }
    return formatters
    #else
    return [:]
    #endif
}()

/// Abbreviations for a locale that has no data for the unit, so a missing CLDR
/// entry costs the reader the localized word and not the whole label.
private let asciiDurationUnits: [Calendar.Component: String] = [
    .hour: "h", .day: "d", .weekOfYear: "w", .month: "mo", .year: "y",
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
