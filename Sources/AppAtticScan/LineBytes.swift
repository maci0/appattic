// UTF-8 line primitives shared by the parsers in `Outdated.swift` and
// `Packages.swift`. Both walk `text.utf8` by hand: `Character.isWhitespace` on
// String indices costs ~2 µs/line (grapheme/Unicode overhead), byte compares
// run ~20 ns/line. Zero allocations except the result Strings.

@inline(__always) func bWS(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C || b == 0x0B
}

@inline(__always) func bDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

@inline(__always) func bAlphaNum(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

/// Byte range of the trimmed line inside `text.utf8`.
@inline(__always) func trimRange(_ u: UnsafeBufferPointer<UInt8>) -> (Int, Int) {
    var s = 0
    var e = u.count
    while s < e, bWS(u[s]) { s += 1 }
    while e > s, bWS(u[e - 1]) { e -= 1 }
    return (s, e)
}

/// Trimmed bounds of `u[ls..<e]`.
@inline(__always) func trimBounds(_ u: UnsafeBufferPointer<UInt8>, _ e: Int, ls: Int) -> (Int, Int) {
    var s = ls
    var end = e
    while s < end, bWS(u[s]) { s += 1 }
    while end > s, bWS(u[end - 1]) { end -= 1 }
    return (s, end)
}

/// Token bounds `[start, end)` from `i`, skipping leading whitespace.
@inline(__always) func tokBounds(_ u: UnsafeBufferPointer<UInt8>, _ e: Int, _ i: inout Int) -> (Int, Int)? {
    while i < e, bWS(u[i]) { i += 1 }
    guard i < e else { return nil }
    let s = i
    while i < e, !bWS(u[i]) { i += 1 }
    return (s, i)
}

/// Substring for UTF-8 byte bounds. The inputs we parse are ASCII-delimited
/// slices; names may carry non-ASCII bytes but bounds always land on token
/// edges so this never splits a scalar.
@inline(__always) func tokSub(_ line: Substring, _ u: UnsafeBufferPointer<UInt8>, _ b: (Int, Int)) -> Substring {
    let start = line.utf8.index(line.utf8.startIndex, offsetBy: b.0)
    let end = line.utf8.index(start, offsetBy: b.1 - b.0)
    return line[start..<end]
}
