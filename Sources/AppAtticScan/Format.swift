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

/// `NumberFormatter`s for `Locale.current`, each cached against the locale it
/// was built from: a formatter keeps the locale it was built with, so one built
/// once at startup would keep the old digits and separator for the rest of the
/// session after the user switches language. Building one costs about 20 µs,
/// and `humanSize` formats every row of a disk tree and a scan report, so a
/// fresh formatter per call dominated the function.
///
/// A `NumberFormatter` is not safe to drive from two threads at once, so every
/// read of either cache, and every use of the formatter it holds, happens under
/// `localeNumberFormatLock`.
private let localeNumberFormatLock = NSLock()
private var cachedDecimalFormatter: (locale: String, formatter: NumberFormatter)?
private var cachedCountFormatter: (locale: String, formatter: NumberFormatter)?

/// The one-decimal formatter for `Locale.current`, with grouping off. The
/// caller holds `localeNumberFormatLock`.
private func localeDecimalNumberFormatter() -> NumberFormatter {
    let id = Locale.current.identifier
    if let cached = cachedDecimalFormatter, cached.locale == id { return cached.formatter }
    let f = NumberFormatter()
    f.locale = .current
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    f.maximumFractionDigits = 1
    f.minimumFractionDigits = 1
    cachedDecimalFormatter = (id, f)
    return f
}

/// Decimal separator of `Locale.current`: the locale's separator of record for
/// the tests, which build their own formatter to check the labels against.
var localeDecimalSeparator: String {
    localeNumberFormatLock.lock()
    defer { localeNumberFormatLock.unlock() }
    return localeDecimalNumberFormatter().decimalSeparator ?? "."
}

/// A whole count in `Locale.current`'s own grouping. `"\(n)"` interpolates
/// without reading the locale, so a German report prints "1234 items" where
/// "1.234 Elemente" belongs, and every locale gets ASCII digits regardless of
/// what its own number formatting uses. The Qt shell has the same helper
/// under the same name, so both windows label one scan the same way.
public func localeCount(_ n: Int) -> String {
    localeNumberFormatLock.lock()
    defer { localeNumberFormatLock.unlock() }
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

/// One decimal place in the locale's own digits, separator and sign.
///
/// The digits and the minus were interpolated as ASCII, so an Arabic or Farsi
/// window read "1.5 MB" in Latin digits (and, in Farsi, a hyphen where the
/// locale writes U+2212) while the `localeCount` whole part of the same label
/// came out localized. The `fixed1` twin in the Qt shell formats through
/// `QLocale` and keeps no ASCII literals at all, and this is what makes the two
/// windows label one value the same way.
///
/// Grouping is off: a size prints one mantissa and a unit, and a "1.024,0" in
/// a column the table sorts on reads as a different number than the one it is.
func oneDecimal(_ n: Double) -> String {
    localeNumberFormatLock.lock()
    defer { localeNumberFormatLock.unlock() }
    return localeDecimalNumberFormatter().string(from: NSNumber(value: n)) ?? "\(n)"
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
            // `localeCount`, not `"\(bytes)"`: the byte unit is the one every
            // locale groups ("1.023 B" in German, "1٬٠٢٣ B" in Arabic), and
            // the Qt `humanSize` twin prints the same helper for the same
            // value, so an ungrouped count here made the two windows disagree
            // about one scan.
            if unit == 0 { return localeCount(bytes) + " B" }
            return oneDecimal(n) + " " + units[unit]
        }
        n /= 1024
        unit += 1
    }
    return oneDecimal(n) + " " + units[unit]
}

/// A sum that may include rows whose size was not measured.
/// No rows: "0 B". Rows and none measured: "unknown". Mixed: the measured
/// sum plus " partial". All measured: the sum.
public func measuredBytesLabel(bytes: Int, sized: Int, unsized: Int) -> String {
    if sized == 0 && unsized == 0 { return humanSize(0) }
    if sized == 0 { return "unknown" }
    if unsized > 0 { return humanSize(bytes) + " partial" }
    return humanSize(bytes)
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

/// Opacity of the amber location text on an unselected shadow leftover.
/// The review tone already sits on the 4.5:1 floor against white. Scaling it
/// toward the list fill drops the location under that floor.
public func shadowLocationOpacity() -> Double { 1 }

/// Instrument value before the first result of a scan. The slot stays, and it
/// reads as in progress rather than as a measured zero.
public func overviewInstrumentValue(scanningWithoutResults: Bool, finished: String) -> String {
    scanningWithoutResults ? "…" : finished
}

/// Empty-list copy while a scan has not produced a result yet. Nil once there
/// is a result, so the page's own finished empty copy is what shows.
public func dashboardPendingCopy(scanning: Bool, hasResults: Bool, progress: String) -> (title: String, detail: String)? {
    guard scanning, !hasResults else { return nil }
    let detail = progress.isEmpty ? "Scanning…" : progress
    return ("Scanning", detail)
}

/// Finished empty copy when a package check failed. The Outdated page, the
/// Packages page, and an overview that would otherwise say nothing is there
/// use this. Stale and leftovers are a different measurement.
public func dashboardIncompleteCopy() -> (title: String, detail: String) {
    ("Scan incomplete", "A package check failed, so this list is not a complete answer.")
}

/// One version slot. Empty and missing both stay on screen as `unknown`.
public func versionSlotText(_ version: String?) -> String {
    guard let version, !version.isEmpty else { return "unknown" }
    return version
}

/// Outdated row text. One missing side stays `unknown`. Both missing collapse
/// to that word. An untrusted tap is not a version pair.
public func outdatedVersionText(current: String?, latest: String?, untrusted: Bool) -> String {
    if untrusted { return "untrusted tap" }
    if versionSlotText(current) == "unknown", versionSlotText(latest) == "unknown" {
        return "unknown"
    }
    return "\(versionSlotText(current)) → \(versionSlotText(latest))"
}

/// Phase line for a scan toolbar. Phase 0 is the text alone, so a line that
/// has not entered the phase list does not grow a counter.
public func scanProgressLine(phase: Int, total: Int, text: String) -> String {
    if phase <= 0 || total <= 0 { return text }
    return "\(text) (\(phase)/\(total))"
}

/// Fraction for the compact scan bar. Nil when the line has no trailing N/M.
public func scanProgressFraction(line: String) -> Double? {
    guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return nil }
    let bodyStart = line.index(after: open)
    let bodyEnd = line.index(before: line.endIndex)
    guard bodyStart < bodyEnd else { return nil }
    let parts = line[bodyStart..<bodyEnd].split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let n = Int(parts[0]), let total = Int(parts[1]), total > 0, n >= 0 else {
        return nil
    }
    return Double(n) / Double(total)
}

/// Update confirm. The named managers are the ones in the selection. Three or
/// more stay generic so the title does not invent a pair the selection does not have.
public func updateConfirmTitle(count: Int, managers: [String]) -> String {
    var seen = Set<String>()
    var labels: [String] = []
    for manager in managers {
        let label = manager.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty || seen.contains(label) { continue }
        seen.insert(label)
        labels.append(label)
    }
    labels.sort()
    if labels.count >= 3 {
        return "Update \(count) packages?"
    }
    let noun = count == 1 ? "package" : "packages"
    if labels.isEmpty {
        return "Update \(count) \(noun)?"
    }
    if labels.count == 1 {
        return "Update \(count) \(labels[0]) \(noun)?"
    }
    return "Update \(count) \(labels[0]) or \(labels[1]) \(noun)?"
}

/// Toolbar count. A scan with no result yet has not measured zero rows.
public func visibleRowCount(scanning: Bool, hasResults: Bool, count: Int, one: String, many: String) -> String {
    if scanning && !hasResults { return "…" }
    if count == 1 { return "1 \(one)" }
    return "\(count) \(many)"
}

private func duration(_ unit: Calendar.Component, _ count: Int) -> String {
    var components = DateComponents()
    components.setValue(count, for: unit)
    if let text = durationFormatters[unit]?(components) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
    }
    // `localeCount`, not `"\(count)"`: this path is the one that runs on
    // swift-corelibs-foundation, where the formatter table above is empty, so
    // every count on Linux came out in ASCII digits while the sizes beside it
    // came out in the locale's own.
    return "\(localeCount(count)) \(asciiDurationUnits[unit] ?? "")"
}
