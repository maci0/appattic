import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public let appAtticVersion = "1.3.1"

public enum PlatformOverride {
    nonisolated(unsafe) public static var linux: Bool?
    public static var isLinux: Bool {
        if let linux { return linux }
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }
    public static var isDarwin: Bool { !isLinux }
}

/// Headers from `dnf repoquery` / `dnf list --upgrades` / `dnf check-update`.
public func isDnfListingNoise(_ line: String) -> Bool {
    isDnfListingNoise(line[...])
}

func isDnfListingNoise(_ line: Substring) -> Bool {
    // Operates on raw UTF-8: the hot dnf loop never materialises a String for
    // noise lines (lowercased() alone costs ~1 µs/line).
    line.utf8.withContiguousStorageIfAvailable { u -> Bool in
        var s = 0
        let e = u.count
        while s < e, u[s] == 0x20 || u[s] == 0x09 { s += 1 }
        func hasPrefix(_ p: [UInt8]) -> Bool {
            guard e - s >= p.count else { return false }
            for k in 0..<p.count {
                var c = u[s + k]
                if c >= 0x41, c <= 0x5A { c &+= 32 }
                guard c == p[k] else { return false }
            }
            return true
        }
        return hasPrefix([0x6C, 0x61, 0x73, 0x74, 0x20, 0x6D, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61]) // last metadata
            || hasPrefix([0x70, 0x61, 0x63, 0x6B, 0x61, 0x67, 0x65, 0x73]) // packages
            || hasPrefix([0x66, 0x69, 0x6E, 0x64, 0x69, 0x6E, 0x67]) // finding
            || hasPrefix([0x61, 0x76, 0x61, 0x69, 0x6C, 0x61, 0x62, 0x6C, 0x65, 0x20, 0x75, 0x70, 0x67, 0x72, 0x61, 0x64, 0x65]) // available upgrade
            || hasPrefix([0x6F, 0x62, 0x73, 0x6F, 0x6C, 0x65, 0x74, 0x69, 0x6E, 0x67]) // obsoleting
    } ?? false
}

public func parseOsRelease(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    // Byte scan: `trimmingCharacters` + `firstIndex(of:)` per line cost ~26 µs
    // for a 12-line os-release. Keys/values are ASCII; only the two result
    // Strings allocate.
    //
    // Split on raw LF/CR bytes, not `split(separator: "\n")`: Swift treats
    // "\r\n" as one grapheme cluster, so that never splits a CRLF file.
    let bytes = Array(text.utf8)
    let n = bytes.count
    func emit(_ s: Int, _ e: Int) {
        var (a, b) = (s, e)
        while a < b, bytes[a] == 0x20 || bytes[a] == 0x09 { a += 1 }
        while b > a, bytes[b - 1] == 0x20 || bytes[b - 1] == 0x09 { b -= 1 }
        guard a < b, bytes[a] != 0x23 /* # */ else { return }
        var eq = a
        while eq < b, bytes[eq] != 0x3D /* = */ { eq += 1 }
        guard eq < b else { return }
        var (vs, ve) = (eq + 1, b)
        while vs < ve, bytes[vs] == 0x20 || bytes[vs] == 0x09 { vs += 1 }
        while ve > vs, bytes[ve - 1] == 0x20 || bytes[ve - 1] == 0x09 { ve -= 1 }
        if ve - vs >= 2 {
            let f = bytes[vs]
            let l = bytes[ve - 1]
            if (f == 0x22 && l == 0x22) || (f == 0x27 && l == 0x27) { vs += 1; ve -= 1 }
        }
        out[String(decoding: bytes[a..<eq], as: UTF8.self)] =
            String(decoding: bytes[vs..<ve], as: UTF8.self)
    }
    var i = 0
    while i < n {
        var j = i
        while j < n, bytes[j] != 0x0A, bytes[j] != 0x0D { j += 1 }
        emit(i, j)
        // One CRLF (or run of breaks) is one boundary.
        while j < n, bytes[j] == 0x0A || bytes[j] == 0x0D { j += 1 }
        i = j
    }
    return out
}

public func linuxDistroFamily(osRelease: String) -> String {
    let fields = parseOsRelease(osRelease)
    let id = (fields["ID"] ?? "").lowercased()
    let like = (fields["ID_LIKE"] ?? "").lowercased()
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    let tokens = ([id] + like).filter { !$0.isEmpty }
    func matches(_ needles: Set<String>) -> Bool {
        tokens.contains { needles.contains($0) }
    }
    if matches(["arch", "archlinux", "manjaro", "endeavouros", "garuda", "cachyos", "artix", "archarm"]) {
        return "arch"
    }
    if matches(["fedora", "rhel", "centos", "rocky", "almalinux", "alma", "nobara", "ol", "amzn"]) {
        return "fedora"
    }
    if tokens.contains(where: { $0.contains("suse") || $0 == "sles" || $0.hasPrefix("opensuse") }) {
        return "suse"
    }
    if matches(["debian", "ubuntu", "linuxmint", "pop", "elementary", "raspbian", "kali", "zorin", "neon"]) {
        return "debian"
    }
    return "unknown"
}

/// Distro package manager used for orphans and outdated queries.
public enum DistroPackageManager: String, Sendable {
    case pacman
    case apt
    case dnf
    case zypper
}

/// Family from os-release, then PATH order pacman, dnf, zypper, apt.
public func resolveDistroPackageManager(family: String, which: WhichFn) -> DistroPackageManager? {
    switch family {
    case "arch":
        return .pacman
    case "debian":
        return .apt
    case "fedora":
        return .dnf
    case "suse":
        return .zypper
    default:
        break
    }
    if which("pacman") != nil { return .pacman }
    if which("dnf5") != nil || which("dnf") != nil || which("yum") != nil { return .dnf }
    if which("zypper") != nil { return .zypper }
    if which("apt-get") != nil || which("apt") != nil { return .apt }
    return nil
}

/// UTF-8 decode. Invalid bytes become U+FFFD. A leading BOM is not content.
public func decodeUTF8(_ data: Data) -> String {
    var text = String(decoding: data, as: UTF8.self)
    if text.hasPrefix("\u{FEFF}") {
        text.removeFirst()
    }
    return text
}

/// Case fold that does not follow the process locale.
/// `String.lowercased()` maps "I" to "ı" in tr_TR, which breaks identity keys.
///
/// ASCII fast path: byte fold (~30 ns) instead of the Locale/ICU pass
/// (~1.5 µs). Only non-ASCII input takes the slow path, where POSIX and
/// Turkish mappings can actually differ.
public func posixLowercased(_ s: String) -> String {
    // ASCII check first: works on small/non-contiguous strings too, where
    // `withContiguousStorageIfAvailable` gives up and would force the slow path.
    guard !s.utf8.contains(where: { $0 >= 0x80 }) else {
        return s.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    let n = s.utf8.count
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: n) { buf in
        var k = 0
        for c in s.utf8 {
            buf[k] = (c >= 0x41 && c <= 0x5A) ? c &+ 32 : c
            k += 1
        }
        return String(decoding: UnsafeBufferPointer(start: buf.baseAddress, count: n), as: UTF8.self)
    }
}

/// Read a file as UTF-8. Invalid sequences become U+FFFD, matching `runCommand`.
public func readUTF8File(_ path: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return decodeUTF8(data)
}

public func linuxOsReleaseText(
    readFile: (String) -> String? = { path in
        readUTF8File(path)
    }
) -> String {
    readFile("/etc/os-release") ?? readFile("/usr/lib/os-release") ?? ""
}

/// XDG Base Directory: unset, empty, or non-absolute values use `home/fallback`.
public func xdgUserDir(
    _ variable: String,
    fallback: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    if let raw = env[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("/") {
        return raw
    }
    return (home as NSString).appendingPathComponent(fallback)
}

public func xdgDataHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_DATA_HOME", fallback: ".local/share", home: home, env: env)
}

public func xdgConfigHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_CONFIG_HOME", fallback: ".config", home: home, env: env)
}

public func xdgCacheHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_CACHE_HOME", fallback: ".cache", home: home, env: env)
}

public func xdgStateHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_STATE_HOME", fallback: ".local/state", home: home, env: env)
}

/// Identity token for leftover/app matching. NFC and NFD spellings of the same
/// word collapse (macOS filenames are NFD, plist names are usually NFC).
/// Fold one scalar the way the slow path does: NFD -> case+diacritic fold -> keep
/// ASCII letters/digits. Only the non-ASCII path needs the full Unicode machinery.
private func normSlow(_ s: String) -> String {
    s.decomposedStringWithCanonicalMapping
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

public func norm(_ s: String) -> String {
    // Fast path: for pure-ASCII input, canonical decomposition and diacritic
    // folding are no-ops, so this is exactly lowercasing then keeping [a-z0-9].
    // Most app names take it, avoiding three String allocations per call.
    var bytes: [UInt8] = []
    bytes.reserveCapacity(s.utf8.count)
    for b in s.utf8 {
        if b >= 0x80 {
            return normSlow(s)
        }
        let c = (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
        if (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) {
            bytes.append(c)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Comparison form for leftover ignore paths. NFC so a pasted path matches
/// a filesystem path that used combining marks.
public func pathIdentityKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping
}

/// Standardized home, cached: `homeDirectoryForCurrentUser` (6.7 µs) plus
/// `standardizingPath` (4 µs) dominated this function, not the scan itself.
private let redactHomeLock = NSLock()
nonisolated(unsafe) private var redactHomeCache: [String: String] = [:]

private func standardizedHome(_ home: String) -> String {
    redactHomeLock.lock()
    defer { redactHomeLock.unlock() }
    if let cached = redactHomeCache[home] { return cached }
    let std = (home as NSString).standardizingPath
    redactHomeCache[home] = std
    return std
}

/// Process home, resolved once: `homeDirectoryForCurrentUser` costs ~7 µs per
/// call and the old default-arg form paid it on every log line.
private func processHome() -> String {
    redactHomeLock.lock()
    defer { redactHomeLock.unlock() }
    if let cached = redactHomeCache[""] { return cached }
    let std = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
    redactHomeCache[""] = std
    return std
}

/// Replace the user's home directory prefix with `~` so logs and errors do not
/// carry the account path. `/home/alice2` is left alone when home is `/home/alice`.
public func redactHomePaths(
    _ text: String,
    home: String? = nil
) -> String {
    // No path separator, no home prefix.
    guard text.contains("/") else { return text }
    let homePath: String
    var rawHome: String?
    if let home {
        homePath = standardizedHome(home)
        // `standardizingPath` resolves symlinks on Darwin (/home, /tmp, /var),
        // so a subprocess error can carry either spelling. Try both.
        if home != homePath { rawHome = home }
    } else {
        homePath = processHome()
    }
    if homePath.count > 1, text.contains(homePath), let redacted = redactHomePrefix(text, homePath: homePath) {
        return redacted
    }
    if let rawHome, rawHome.count > 1, text.contains(rawHome),
       let redacted = redactHomePrefix(text, homePath: rawHome) {
        return redacted
    }
    return text
}

/// Replace every `homePath` occurrence in `text` that ends on a path boundary
/// with `~`. Nil when there is none. Byte scan: the old NSRegularExpression +
/// NSString round-trip cost ~11 µs per call, and this runs on every log line.
private func redactHomePrefix(_ text: String, homePath: String) -> String? {
    // One of the two can be bridged from NSString on Darwin (see
    // `standardizedHome`), where its UTF-8 is not contiguous. Falling back to
    // the copies keeps redaction working there instead of leaking the account
    // path into logs and error dialogs.
    let fast = text.utf8.withContiguousStorageIfAvailable { tu -> [(Int, Int)]? in
        homePath.utf8.withContiguousStorageIfAvailable { hu -> [(Int, Int)]? in
            homePrefixHits(tu, hu)
        } ?? nil
    } ?? nil
    guard let hits = fast ?? homePrefixHits(Array(text.utf8), Array(homePath.utf8)) else {
        return nil
    }
    var out = text
    // Replace back to front so earlier indices stay valid.
    for (s, e) in hits.reversed() {
        let rs = text.utf8.index(text.utf8.startIndex, offsetBy: s)
        let re = text.utf8.index(rs, offsetBy: e - s)
        out.replaceSubrange(rs..<re, with: "~")
    }
    return out
}

/// Byte offsets of every `home` occurrence in `text` that ends on a path
/// boundary (`/`, end of text, or one of `[\s:"',;]`). Nil when none.
private func homePrefixHits<T: RandomAccessCollection, H: RandomAccessCollection>(
    _ text: T,
    _ home: H
) -> [(Int, Int)]? where T.Element == UInt8, T.Index == Int, H.Element == UInt8, H.Index == Int {
    let tn = text.count
    let hn = home.count
    guard hn > 0, tn >= hn else { return nil }
    var hits: [(Int, Int)] = []
    var i = 0
    outer: while i + hn <= tn {
        for k in 0..<hn where text[i + k] != home[k] {
            i += 1
            continue outer
        }
        // Boundary after the prefix: `/`, end, or one of `[\s:"',;]`.
        let a = i + hn
        let ok: Bool
        if a >= tn {
            ok = true
        } else {
            let c = text[a]
            ok = c == 0x2F || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D ||
                c == 0x3A || c == 0x22 || c == 0x27 || c == 0x2C || c == 0x3B
        }
        if ok { hits.append((i, a)); i = a } else { i += 1 }
    }
    return hits.isEmpty ? nil : hits
}

public func restrictOwnerOnlyFile(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

public func restrictOwnerOnlyDirectory(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Owner-only mode on a private data file. If the parent directory is named
/// `appattic`, that directory is owner-only as well. Other parents are left alone.
public func restrictPrivateDataFile(at url: URL) throws {
    try restrictOwnerOnlyFile(at: url)
    let dir = url.deletingLastPathComponent()
    if dir.lastPathComponent.lowercased() == "appattic" {
        try restrictOwnerOnlyDirectory(at: dir)
    }
}

public func writeOwnerOnlyFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try restrictOwnerOnlyFile(at: url)
}

public func whichCommand(_ name: String) -> String? {
    if name.isEmpty { return nil }
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var extras = [
        home + "/.local/bin",
        home + "/bin",
        home + "/.bun/bin",
        home + "/.deno/bin",
        home + "/.volta/bin",
        home + "/.yarn/bin",
        home + "/.cargo/bin",
        home + "/.fnm/aliases/default/bin",
        home + "/.local/share/pnpm",
        home + "/.npm-global/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    let nvmRoot = home + "/.nvm/versions/node"
    if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
        for v in vers where !v.hasPrefix(".") {
            extras.append(nvmRoot + "/" + v + "/bin")
        }
    }
    let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
    var seen = Set<String>()
    for dir in extras + pathDirs {
        if !seen.insert(dir).inserted { continue }
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

public func pmap<T, R>(_ items: [T], workers: Int = 16, _ fn: (T) -> R) -> [R] {
    guard !items.isEmpty else { return [] }
    if items.count == 1 || workers <= 1 { return items.map(fn) }
    var results = [R?](repeating: nil, count: items.count)
    let lock = NSLock()
    let sem = DispatchSemaphore(value: max(workers, 1))
    // `concurrentPerform` keeps `fn` non-escaping end to end. Handing it to
    // `queue.async` needs `withoutActuallyEscaping`, whose runtime check is
    // racy: a dispatched block can outlive the join, so the check aborts the
    // process with "non-escaping closure has escaped" mid-scan.
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        sem.wait()
        let value = fn(items[i])
        lock.lock()
        results[i] = value
        lock.unlock()
        sem.signal()
    }
    return results.map { $0! }
}

/// Truncate ISO-8601 fractional seconds so `ISO8601DateFormatter` can parse
/// GTK/GNOME timestamps that carry microseconds (`…T15:00:00.123456Z`).
func truncateISOFractionalSeconds(_ s: String, maxDigits: Int = 3) -> String {
    guard let tIndex = s.firstIndex(of: "T") else { return s }
    guard let dot = s[tIndex...].firstIndex(of: ".") else { return s }
    var digitEnd = s.index(after: dot)
    var count = 0
    while digitEnd < s.endIndex, s[digitEnd].isNumber {
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

/// Direct parse of the ISO-8601 shapes the formatters below accept, by integer
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
            guard i == n, om <= 59 else { return nil }
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

func monotonicSeconds() -> TimeInterval {
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

/// Bytes that need no quoting in a POSIX shell word.
@inline(__always)
func isSafeShellByte(_ c: UInt8) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5F || c == 0x40 || c == 0x25 || c == 0x2B || c == 0x3D ||
        c == 0x3A || c == 0x2C || c == 0x2E || c == 0x2F || c == 0x2D
}

public func shellQuote(_ value: String) -> String {
    if value.isEmpty { return "''" }
    // Byte scan: `CharacterSet.inverted` + `rangeOfCharacter` cost ~2.9 µs per
    // call, and this runs on every scripted path.
    //
    // The non-contiguous fallback applies the same predicate instead of
    // assuming "needs quoting": values bridged from NSString (Darwin) are not
    // contiguous, and guessing there made the same command quote differently
    // per platform.
    let needsQuote = value.utf8.withContiguousStorageIfAvailable { u -> Bool in
        for c in u where !isSafeShellByte(c) { return true }
        return false
    } ?? value.utf8.contains { !isSafeShellByte($0) }
    if !needsQuote { return value }
    // Only `'` needs escaping inside single quotes.
    if !value.contains("'") { return "'" + value + "'" }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// Cached process username: environment copy + trims + folds per call cost
/// ~2 µs, and `classify` calls this per entry. The account name cannot change
/// mid-scan.
private let cachedUsernameLock = NSLock()
nonisolated(unsafe) private var cachedUsername: String? = nil

func currentUsername() -> String {
    cachedUsernameLock.lock()
    defer { cachedUsernameLock.unlock() }
    if let cached = cachedUsername { return cached }
    let resolved: String = {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["USER"] ?? env["LOGNAME"] ?? "").trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty { return posixLowercased(raw) }
        #if os(macOS)
        let name = NSUserName().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return posixLowercased(name) }
        #endif
        return posixLowercased(ProcessInfo.processInfo.userName)
    }()
    cachedUsername = resolved
    return resolved
}

public func cleanupPathDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
    [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        (home as NSString).appendingPathComponent(".local/bin"),
        (home as NSString).appendingPathComponent("bin"),
        "/usr/bin",
        "/bin",
    ]
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

/// Saturating sum for non-negative byte totals. Overflow becomes Int.max.
public func addBytes(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
}

/// One decimal place without `String(format:)` (~1.2 µs/call from locale +
/// varargs overhead). Rounds half away from zero the way `%.1f` prints.
func oneDecimal(_ n: Double) -> String {
    let neg = n < 0
    let tenths = Int((abs(n) * 10).rounded())
    return (neg ? "-" : "") + "\(tenths / 10).\(tenths % 10)"
}

public func humanSize(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
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

public func runCommand(_ cmd: [String], timeout: TimeInterval = 60) -> (Int32, String, String) {
    guard let exe = cmd.first else { return (127, "", "empty command") }
    let resolved: String
    if exe.hasPrefix("/") {
        resolved = exe
    } else if let found = whichCommand(exe) {
        resolved = found
    } else {
        return (127, "", "not found: \(exe)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolved)
    process.arguments = Array(cmd.dropFirst())
    var env = ProcessInfo.processInfo.environment
    if URL(fileURLWithPath: resolved).lastPathComponent == "brew" {
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    }
    process.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice
    let collected = CommandPipes()
    let group = DispatchGroup()
    // Dedicated threads: pmap workers already occupy the GCD pool. Queueing
    // pipe reads on that pool deadlocks (workers wait for readers, readers wait
    // for threads).
    group.enter()
    Thread.detachNewThread {
        collected.out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    Thread.detachNewThread {
        collected.err = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    do {
        try process.run()
    } catch {
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        group.wait()
        return (127, "", error.localizedDescription)
    }
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()
    let start = monotonicSeconds()
    while process.isRunning && (monotonicSeconds() - start) < timeout {
        Thread.sleep(forTimeInterval: 0.05)
    }
    var timedOut = false
    if process.isRunning {
        timedOut = true
        process.terminate()
        let killStart = monotonicSeconds()
        while process.isRunning && (monotonicSeconds() - killStart) < 1 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()
    group.wait()
    if timedOut {
        return (127, "", "timeout")
    }
    let out = decodeUTF8(collected.out)
    let err = decodeUTF8(collected.err)
    return (process.terminationStatus, out, err)
}

private final class CommandPipes: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    var out: Data {
        get { lock.lock(); defer { lock.unlock() }; return _out }
        set { lock.lock(); defer { lock.unlock() }; _out = newValue }
    }
    var err: Data {
        get { lock.lock(); defer { lock.unlock() }; return _err }
        set { lock.lock(); defer { lock.unlock() }; _err = newValue }
    }
}

func intFromSizeAttribute(_ raw: Any?) -> Int {
    let v: Int64
    if let u = raw as? UInt64 {
        if u > UInt64(Int64.max) { return Int.max }
        v = Int64(u)
    } else if let n = raw as? NSNumber {
        v = n.int64Value
    } else if let i = raw as? Int {
        v = Int64(i)
    } else if let i = raw as? Int64 {
        v = i
    } else {
        return 0
    }
    if v < 0 { return 0 }
    if v > Int64(Int.max) { return Int.max }
    return Int(v)
}

public func fileSize(_ path: String) -> Int {
    intFromSizeAttribute(try? FileManager.default.attributesOfItem(atPath: path)[.size])
}

public func duSize(_ path: String, timeout: TimeInterval = 8, run: CommandRun = runCommand) -> (Int, Bool) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        return (0, false)
    }
    if !isDir.boolValue {
        return (fileSize(path), true)
    }
    if path.hasSuffix(".app"), let bytes = spotlightFSSize(path, run: run) {
        return (bytes, true)
    }
    for exe in ["/usr/bin/du", "du"] {
        let (rc, out, _) = run([exe, "-sk", path], timeout)
        if rc == 0 {
            let pair = parseDuKB(out)
            if pair.1, pair.0 > 0 { return pair }
        }
    }
    return directoryByteSize(path, timeout: timeout)
}

public func spotlightFSSize(_ path: String, run: CommandRun = runCommand) -> Int? {
    let (rc, out, _) = run(["/usr/bin/mdls", "-name", "kMDItemFSSize", "-raw", path], 5)
    guard rc == 0 else { return nil }
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "(null)" { return nil }
    guard let n = Int(trimmed), n > 0 else { return nil }
    return n
}

func parseDuKB(_ out: String) -> (Int, Bool) {
    guard let first = out.split(whereSeparator: \.isWhitespace).first, let kb = Int(first), kb > 0 else {
        return (0, false)
    }
    let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
    if overflow { return (0, false) }
    return (bytes, true)
}

/// Split into consecutive runs of at most `n` elements.
func chunked<T>(_ xs: [T], into n: Int) -> [[T]] {
    guard n > 0 else { return [] }
    var out: [[T]] = []
    out.reserveCapacity((xs.count + n - 1) / n)
    var i = 0
    while i < xs.count {
        out.append(Array(xs[i..<min(i + n, xs.count)]))
        i += n
    }
    return out
}

/// Batch `du -sk` for many directories: one spawn per chunk instead of one
/// per path. A full leftover scan spawns `du` hundreds of times (~50 ms each);
/// batching cuts that to a handful. Missing/error lines fall back to the
/// in-process walk, never to another spawn.
///
/// `du` separates size and path with a tab. Paths containing newlines cannot
/// round-trip through line parsing; unmatched lines fall back safely, but a
/// mangled fragment could theoretically collide with another queried path.
public func duSizes(
    _ paths: [String],
    timeout: TimeInterval = 8,
    run: CommandRun = runCommand
) -> [String: (Int, Bool)] {
    var out: [String: (Int, Bool)] = [:]
    var dirs: [String] = []
    for path in paths {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            out[path] = (0, false)
            continue
        }
        if !isDir.boolValue {
            out[path] = (fileSize(path), true)
            continue
        }
        dirs.append(path)
    }
    // Chunk well under ARG_MAX even for very long paths.
    for chunk in chunked(dirs, into: 128) {
        var missing = Set(chunk)
        for exe in ["/usr/bin/du", "du"] {
            let (rc, duOut, _) = run([exe, "-sk"] + chunk, timeout)
            if rc != 0, duOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            var parsedAny = false
            for raw in duOut.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let tab = raw.firstIndex(of: "\t") else { continue }
                guard let kb = Int(raw[..<tab]), kb > 0 else { continue }
                let p = String(raw[raw.index(after: tab)...])
                guard missing.contains(p) else { continue }
                let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
                guard !overflow else { continue }
                out[p] = (bytes, true)
                missing.remove(p)
                parsedAny = true
            }
            // The binary ran: leftovers are genuinely unreadable by du, so
            // fall back to the walk instead of retrying another binary.
            if parsedAny || rc == 0 { break }
        }
        for path in missing {
            out[path] = directoryByteSize(path, timeout: timeout)
        }
    }
    return out
}

/// Logical file bytes for a directory tree: sum of regular-file `st_size`,
/// symlinks not followed.
///
/// Uses `opendir`/`fstatat` rather than `FileManager.enumerator` +
/// `resourceValues`. On corelibs-foundation those populate owner names, which
/// costs an NSS lookup per entry (~0.5 ms here: `libnss_systemd` D-Bus round
/// trip), so a 2 300-file tree took 1.2 s instead of ~3 ms.
public func directoryByteSize(_ path: String, timeout: TimeInterval = 8) -> (Int, Bool) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        return (0, false)
    }
    if !isDir.boolValue {
        return (fileSize(path), true)
    }
    let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard fd >= 0 else {
        return (0, false)
    }
    defer { close(fd) }
    var total = 0
    var sawError = false
    let complete = walkLogicalBytes(
        fd: fd,
        total: &total,
        sawError: &sawError,
        deadline: monotonicSeconds() + timeout
    )
    if !complete { return (total, false) }
    return (total, !sawError)
}

/// Returns false when the deadline passed before the tree was fully walked.
func walkLogicalBytes(
    fd: Int32,
    total: inout Int,
    sawError: inout Bool,
    deadline: TimeInterval
) -> Bool {
    if monotonicSeconds() > deadline { return false }
    let dupfd = dup(fd)
    guard dupfd >= 0 else {
        sawError = true
        return true
    }
    guard let dirp = fdopendir(dupfd) else {
        close(dupfd)
        sawError = true
        return true
    }
    defer { closedir(dirp) }
    while true {
        errno = 0
        guard let ent = readdir(dirp) else {
            if errno != 0 { sawError = true }
            break
        }
        let name = direntName(ent)
        if name == "." || name == ".." { continue }
        var st = stat()
        guard name.withCString({ fstatat(fd, $0, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            sawError = true
            continue
        }
        let kind = Int32(st.st_mode) & Int32(S_IFMT)
        if kind == Int32(S_IFDIR) {
            let childFd = name.withCString { openat(fd, $0, childDirFlags) }
            if childFd < 0 {
                sawError = true
            } else {
                let complete = walkLogicalBytes(
                    fd: childFd,
                    total: &total,
                    sawError: &sawError,
                    deadline: deadline
                )
                close(childFd)
                if !complete { return false }
            }
        } else if kind == Int32(S_IFREG) {
            total = addBytes(total, Int(st.st_size))
        }
        if monotonicSeconds() > deadline { return false }
    }
    return true
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
