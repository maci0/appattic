import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public let appAtticVersion = "1.1.0"

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
    let low = line.lowercased()
    return low.hasPrefix("last metadata")
        || low.hasPrefix("packages")
        || low.hasPrefix("finding")
        || low.hasPrefix("available upgrade")
        || low.hasPrefix("obsoleting")
}

public func parseOsRelease(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq])
        var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if val.count >= 2 {
            let first = val.first
            let last = val.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                val = String(val.dropFirst().dropLast())
            }
        }
        out[key] = val
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
public func posixLowercased(_ s: String) -> String {
    s.lowercased(with: Locale(identifier: "en_US_POSIX"))
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

/// XDG Base Directory: empty or unset variable uses `home/fallback`.
public func xdgUserDir(
    _ variable: String,
    fallback: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    if let raw = env[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
        return (raw as NSString).expandingTildeInPath
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
public func norm(_ s: String) -> String {
    s.decomposedStringWithCanonicalMapping
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

/// Comparison form for leftover ignore paths. NFC so a pasted path matches
/// a filesystem path that used combining marks.
public func pathIdentityKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping
}

/// Replace the user's home directory prefix with `~` so logs and errors do not
/// carry the account path. `/home/alice2` is left alone when home is `/home/alice`.
public func redactHomePaths(
    _ text: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path
) -> String {
    let homePath = (home as NSString).standardizingPath
    guard homePath.count > 1 else { return text }
    let pattern = NSRegularExpression.escapedPattern(for: homePath) + #"(?=/|$|[\s:"',;])"#
    guard let re = try? NSRegularExpression(pattern: pattern) else {
        return text.replacingOccurrences(of: homePath + "/", with: "~/")
    }
    let range = NSRange(location: 0, length: (text as NSString).length)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: "~")
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
    let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
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
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "appattic.pmap", attributes: .concurrent)
    let sem = DispatchSemaphore(value: max(workers, 1))
    return withoutActuallyEscaping(fn) { escapingFn in
        for (i, item) in items.enumerated() {
            // Slot is taken here so GCD is not filled with tasks blocked on this semaphore.
            sem.wait()
            group.enter()
            queue.async {
                let value = escapingFn(item)
                lock.lock()
                results[i] = value
                lock.unlock()
                sem.signal()
                group.leave()
            }
        }
        group.wait()
        return results.map { $0! }
    }
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

public func parseISODate(_ value: String?) -> Date? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    func tryISO(_ s: String) -> Date? {
        frac.date(from: s) ?? basic.date(from: s)
    }

    var variants: [String] = []
    func add(_ s: String) {
        if !s.isEmpty, !variants.contains(s) { variants.append(s) }
    }
    add(raw)
    add(truncateISOFractionalSeconds(raw))
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

    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.isLenient = false
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
    ]
    for s in variants {
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
    }
    return nil
}

public func isoString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f.string(from: date)
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

/// Owner-only mode after writing settings, scan cache, or temp scripts.
public func restrictOwnerOnly(path: String, directory: Bool = false) {
    let mode = directory ? 0o700 : 0o600
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

func posixMode(_ path: String) -> Int {
    guard let raw = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] else {
        return -1
    }
    if let n = raw as? NSNumber { return n.intValue }
    if let i = raw as? Int { return i }
    return -1
}

public func shellQuote(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let unsafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-").inverted
    if value.rangeOfCharacter(from: unsafe) == nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func currentUsername() -> String {
    let env = ProcessInfo.processInfo.environment
    let raw = (env["USER"] ?? env["LOGNAME"] ?? "").trimmingCharacters(in: .whitespaces)
    if !raw.isEmpty { return posixLowercased(raw) }
    #if os(macOS)
    let name = NSUserName().trimmingCharacters(in: .whitespaces)
    if !name.isEmpty { return posixLowercased(name) }
    #endif
    return posixLowercased(ProcessInfo.processInfo.userName)
}

public func cleanupPathDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
    [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        (home as NSString).appendingPathComponent(".local/bin"),
        "/usr/bin",
        "/bin",
    ]
}

/// Saturating sum for non-negative byte totals. Overflow becomes Int.max.
public func addBytes(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
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
            return String(format: "%.1f %@", n, units[unit])
        }
        n /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", n, units[unit])
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
    return String(format: "%.1fy", days / 365)
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
    if let n = raw as? NSNumber {
        v = n.int64Value
    } else if let i = raw as? Int {
        v = Int64(i)
    } else if let i = raw as? Int64 {
        v = i
    } else if let u = raw as? UInt64 {
        if u > UInt64(Int64.max) { return Int.max }
        v = Int64(u)
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

/// Logical file bytes. Fallback when spawned `du` cannot read the tree.
public func directoryByteSize(_ path: String, timeout: TimeInterval = 8) -> (Int, Bool) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        return (0, false)
    }
    if !isDir.boolValue {
        return (fileSize(path), true)
    }
    let start = monotonicSeconds()
    var total = 0
    var sawError = false
    let url = URL(fileURLWithPath: path)
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [],
        errorHandler: { _, _ in
            sawError = true
            return true
        }
    ) else {
        return (0, false)
    }
    while let item = enumerator.nextObject() as? URL {
        do {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total = addBytes(total, values.fileSize ?? 0)
            }
        } catch {
            sawError = true
        }
        if monotonicSeconds() - start > timeout {
            return (total, false)
        }
    }
    return (total, !sawError)
}

public func parseMdlsDate(_ value: String) -> Date? {
    var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    if v.isEmpty || v == "(null)" { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.isLenient = false
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f.date(from: v)
}

public func daysSince(_ date: Date?, now: Date = Date()) -> Double? {
    guard let date else { return nil }
    return max(0, now.timeIntervalSince(date) / 86400)
}
