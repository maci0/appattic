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

/// Decimal separator of the current locale, read once. `String(format:)` pays
/// for locale setup on every call (~1.2 µs); the separator is a single lookup.
let localeDecimalSeparator: String = {
    let f = NumberFormatter()
    f.locale = .current
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    return f.decimalSeparator ?? "."
}()

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
/// least 1h, so a future or fractional value never prints `0h`), days below
/// 14, weeks below 60 days, months below 1.5 years, then years. The output unit
/// changes silently with the input, so a caller comparing formatted strings
/// across a threshold gets a different unit, not a different number.
public func humanDays(_ days: Double) -> String {
    if days < 1 {
        return "\(max(Int(days * 24), 1))h"
    }
    if days < 60 {
        return days >= 14 ? "\(Int(days / 7))w" : "\(Int(days))d"
    }
    if days < 365 * 1.5 {
        return "\(Int(days / 30))mo"
    }
    return oneDecimal(days / 365) + "y"
}
