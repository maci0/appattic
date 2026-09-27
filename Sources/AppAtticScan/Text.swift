import Foundation
/// UTF-8 decode. Invalid bytes become U+FFFD. A leading BOM is not content.
public func decodeUTF8(_ data: Data) -> String {
    var text = String(decoding: data, as: UTF8.self)
    if text.hasPrefix("\u{FEFF}") {
        text.removeFirst()
    }
    return text
}

/// Case fold pinned to the POSIX locale, so a Turkish user locale cannot change
/// an identity key. `String.lowercased()` already uses the Unicode default
/// mapping, so the wrapper exists for the ASCII speed, not for the semantics.
///
/// ASCII fast path: byte fold (~30 ns) instead of the Locale/ICU pass
/// (~1.5 µs). Only non-ASCII input takes the slow path, where POSIX and
/// Turkish mappings can actually differ.
public func posixLowercased(_ s: String) -> String {
    // ASCII check first: works on small/non-contiguous strings too, where
    // `withContiguousStorageIfAvailable` gives up and would force the slow path.
    guard s.utf8.contains(where: { $0 >= 0x80 }) else {
        let n = s.utf8.count
        guard n > 0 else { return "" }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: n) { buf in
            var k = 0
            for c in s.utf8 {
                buf[k] = (c >= 0x41 && c <= 0x5A) ? c &+ 32 : c
                k += 1
            }
            return String(decoding: UnsafeBufferPointer(start: buf.baseAddress, count: n), as: UTF8.self)
        }
    }
    return s.lowercased(with: Locale(identifier: "en_US_POSIX"))
}

/// `posixLowercased` plus one canonical form, for comparing text a person
/// typed against text read off the disk.
///
/// The fold alone is not enough: macOS reports filenames in NFD while a
/// keyboard, a paste, and a `.desktop` entry give NFC, and "Café" and
/// "Cafe" + U+0301 are different `String`s, so `posixLowercased("café")
/// .contains(posixLowercased("Cafe" + U+0301))` is false. Every search box and
/// the `--category` filter compare exactly that way, and a user typing an
/// accented name sees the one matching row disappear. NFC is the form the
/// project's identity keys already use (`pathIdentityKey`).
///
/// Diacritics are *not* folded away: "cafe" still does not match "Café". That
/// is a product decision, not a normalization bug, and `norm` is where a
/// caller that wants it goes.
public func posixFolded(_ s: String) -> String {
    let low = posixLowercased(s)
    // ASCII cannot carry a combining mark, so the canonical pass is a no-op
    // there and the common case pays only the check.
    return low.utf8.contains(where: { $0 >= 0x80 }) ? low.precomposedStringWithCanonicalMapping : low
}

/// Read a file as UTF-8. Invalid sequences become U+FFFD, matching `runCommand`.
public func readUTF8File(_ path: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return decodeUTF8(data)
}

/// East Asian Wide and Fullwidth blocks, which a terminal draws two columns
/// wide. Ambiguous-width scalars (Latin-1 letters, box drawing) stay one column
/// so the tables do not depend on the terminal's locale setting.
private let wideColumnRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
    0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
    0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
    0xFFE0...0xFFE6, 0x1B000...0x1B2FF, 0x1F004, 0x1F0CF, 0x1F170...0x1F171,
    0x1F17E...0x1F17F, 0x1F18E, 0x1F191...0x1F19A, 0x1F1E6...0x1F1FF,
    0x1F200...0x1F2FF, 0x1F300...0x1F64F, 0x1F650...0x1F67F, 0x1F680...0x1F6FF,
    0x1F7E0...0x1F7FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF,
    0x20000...0x2FFFD, 0x30000...0x3FFFD,
]

/// Emoji skin-tone modifiers, `Sk` in CLDR but rendered on the preceding
/// base glyph rather than in a cell of their own: a terminal draws "👍🏽" as the
/// single wide cell of the base. They are not `General_Category = Mn`, so the
/// category check in `scalarIsZeroWidth` misses them.
private let emojiModifierRange: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF

private func scalarIsZeroWidth(_ s: Unicode.Scalar) -> Bool {
    if emojiModifierRange.contains(s.value) { return true }
    switch s.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format, .control, .unassigned,
         .lineSeparator, .paragraphSeparator:
        return true
    default:
        return false
    }
}

/// Terminal columns a string occupies. `String.count` counts grapheme
/// clusters, so a CJK name from the filesystem pads to the wrong width and
/// shifts every later column. One cluster is one glyph: a combining mark, a ZWJ
/// sequence, or a skin-tone modifier rides on its base scalar's width instead
/// of adding columns.
public func displayWidth(_ s: String) -> Int {
    var width = 0
    for cluster in s {
        for scalar in cluster.unicodeScalars where !scalarIsZeroWidth(scalar) {
            width += wideColumnRanges.contains { $0.contains(scalar.value) } ? 2 : 1
            break
        }
    }
    return width
}

/// ASCII substring search without bridging to CFStringFind (`String.contains`
/// costs ~1 µs via ICU + retain churn; this is ~20 ns). Exact: the fast path
/// runs only when BOTH sides are fully ASCII (ICU literal search is byte-exact
/// there); any non-ASCII byte anywhere takes the bridged slow path, including
/// combining-mark edges where ICU and byte search can disagree.
public func asciiContains(_ haystack: String, _ needle: String) -> Bool {
    // Degenerate case delegates: empty-needle differs by platform (stdlib true,
    // corelibs-Foundation false). All real callers pass literals.
    guard !needle.isEmpty else { return haystack.contains(needle) }
    let r = haystack.utf8.withContiguousStorageIfAvailable { h -> Int in
        needle.utf8.withContiguousStorageIfAvailable { n -> Int in
            for k in 0..<n.count {
                if n[k] >= 0x80 { return -1 }
            }
            for k in 0..<h.count {
                if h[k] >= 0x80 { return -1 }
            }
            if n.count == 1 {
                return h.contains(n[0]) ? 1 : 0
            }
            guard h.count >= n.count else { return 0 }
            var i = 0
            while i + n.count <= h.count {
                var k = 0
                while k < n.count, h[i + k] == n[k] { k += 1 }
                if k == n.count { return 1 }
                i += 1
            }
            return 0
        } ?? -1
    } ?? -1
    if r >= 0 { return r == 1 }
    return haystack.contains(needle)
}

/// Single-ASCII-byte membership. `String.contains` routes through ICU
/// (`CFStringFind`, ~1 µs); even the generic `UTF8View.contains` closure costs
/// ~100 ns in retain churn. Hand-rolled contiguous scan: ~10 ns.
@inline(__always)
public func asciiHasByte(_ s: String, _ b: UInt8) -> Bool {
    s.utf8.withContiguousStorageIfAvailable { u -> Bool in
        var i = 0
        while i < u.count {
            if u[i] == b { return true }
            i += 1
        }
        return false
    } ?? s.utf8.contains(b)
}

/// Collated order (`localizedStandardCompare`, so "Über" sorts with the Latin
/// names rather than after every ASCII one) with a byte-order tie-break on a
/// unique key.
///
/// `sort` is not stable, so a comparator that calls two records equal leaves
/// their final order up to the input order, and a directory walk hands over
/// whatever order the filesystem listed. Ties therefore reorder between runs
/// on the same machine, which breaks replaying a scan from a recorded input.
public func collatedBefore(_ lhs: String, _ rhs: String, tieBreak lhsKey: String, _ rhsKey: String) -> Bool {
    switch lhs.localizedStandardCompare(rhs) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhsKey < rhsKey
    }
}
