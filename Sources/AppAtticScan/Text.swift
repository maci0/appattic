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

extension String {
    /// POSIX case fold, the same mapping as the free function. The method form
    /// is the one call sites use, since the fold is nearly always applied to the
    /// string in hand and reads better as a suffix.
    public func posixLowercased() -> String { AppAtticScan.posixLowercased(self) }
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

/// Text a terminal reads as a command rather than as characters.
///
/// A name reaches a report from the filesystem, a package listing, or the
/// scan cache, so a directory an unprivileged process can name is a channel
/// into whatever terminal runs `appattic`. `ESC [ 2 J` clears the screen and
/// `ESC ] 0 ;` retitles the window, so one leftover row can hide the rows
/// under it or rename the shell. `stripBidiControls` covers the reordering
/// scalars; these are the ones a terminal executes.
///
/// Every C0 control, DEL, and C1 control becomes U+FFFD, the same marker
/// `decodeUTF8` puts on a byte that is not text. Tab is a C0 control and goes
/// too: inside a table cell it moves the cursor and the columns stop lining
/// up. Printable ASCII, the common case, returns as-is.
public func terminalSafe(_ s: String) -> String {
    if s.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return s }
    let replacement: Unicode.Scalar = "\u{FFFD}"
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
            out.append(replacement)
        } else {
            out.append(scalar)
        }
    }
    return String(out)
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
    0xFFE0...0xFFE6, 0x1B000...0x1B2FF, 0x1F004...0x1F004, 0x1F0CF...0x1F0CF,
    0x1F170...0x1F171, 0x1F17E...0x1F17F, 0x1F18E...0x1F18E, 0x1F191...0x1F19A,
    0x1F1E6...0x1F1FF,
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

/// Control scalars in a filesystem name neutralised, for text on its way to a
/// terminal. SGR colour sequences are kept, so an already-painted cell keeps
/// its colour.
///
/// A Linux filename may contain any byte but NUL, so a leftover directory
/// called `Some\nApp` or a symlink named `x<ESC>]0;pwned<BEL>` arrives at the
/// report verbatim. A newline breaks the row across two physical lines, and
/// `displayWidth` counts both scalars as zero columns, so the second line
/// lands under an unrelated column. An escape sequence is not drawn at all:
/// the terminal executes it, which repaints the title bar or hides a row the
/// user is about to tick. `shellComment` already flattens this set of scalars
/// for the generated script; this is the same rule for the rendered table.
public func sanitizeForTerminal(_ s: String) -> String {
    // Pure-ASCII printables with no ESC are the common case and return as-is.
    var needsPass = false
    // `0xC2` leads every C1 control in UTF-8, so it has to trip the pass for
    // the `0x80...0x9F` arm below to ever be reached.
    for c in s.utf8 where c < 0x20 || c == 0x7F || c == 0xC2 {
        needsPass = true
        break
    }
    guard needsPass else { return s }

    var out = String.UnicodeScalarView()
    var it = s.unicodeScalars.makeIterator()
    while let scalar = it.next() {
        let v = scalar.value
        if v == 0x1B {
            // `ESC [ params m` is SGR, the one sequence the renderer emits and
            // the only one that cannot change the screen beyond colour.
            var look = it
            if look.next() == "[", let first = look.next(), first.value >= 0x30, first.value <= 0x3F {
                var ok = true
                var param = first
                while param.value != "m" {
                    guard let next = look.next(), next.value >= 0x20, next.value <= 0x3F else { ok = false; break }
                    param = next
                }
                if ok {
                    out.append(scalar)
                    out.append("[")
                    out.append(first)
                    while param.value != "m" {
                        out.append(param)
                        guard let next = look.next() else { break }
                        param = next
                    }
                    out.append(param)
                    it = look
                    continue
                }
            }
            out.append(" ")
            continue
        }
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
            out.append(" ")
        } else {
            out.append(scalar)
        }
    }
    return String(out)
}
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
