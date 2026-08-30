import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public let appAtticVersion = "1.0.0"

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

public func parseOsRelease(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
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

public func linuxOsReleaseText(
    readFile: (String) -> String? = { path in
        try? String(contentsOfFile: path, encoding: .utf8)
    }
) -> String {
    readFile("/etc/os-release") ?? readFile("/usr/lib/os-release") ?? ""
}

public func norm(_ s: String) -> String {
    s.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
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
            group.enter()
            queue.async {
                sem.wait()
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

public func parseISODate(_ value: String?) -> Date? {
    guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }
    if text.hasSuffix("Z") {
        text = String(text.dropLast()) + "+00:00"
    }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = frac.date(from: text) { return d }
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    if let d = basic.date(from: text) { return d }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    for fmt in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss Z"] {
        f.dateFormat = fmt
        if let d = f.date(from: text) { return d }
    }
    return nil
}

public func isoString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
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
    if !raw.isEmpty { return raw.lowercased() }
    #if os(macOS)
    let name = NSUserName().trimmingCharacters(in: .whitespaces)
    if !name.isEmpty { return name.lowercased() }
    #endif
    return (ProcessInfo.processInfo.userName).lowercased()
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

public func humanSize(_ bytes: Int) -> String {
    var n = Double(bytes)
    for unit in ["B", "KB", "MB", "GB", "TB"] {
        if abs(n) < 1024 {
            if unit == "B" { return "\(Int(n)) B" }
            return String(format: "%.1f %@", n, unit)
        }
        n /= 1024
    }
    return String(format: "%.1f PB", n)
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
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        collected.out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
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
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    var timedOut = false
    if process.isRunning {
        timedOut = true
        process.terminate()
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()
    _ = group.wait(timeout: .now() + 2)
    if timedOut {
        return (127, "", "timeout")
    }
    let out = String(decoding: collected.out, as: UTF8.self)
    let err = String(decoding: collected.err, as: UTF8.self)
    return (process.terminationStatus, out, err)
}

private final class CommandPipes: @unchecked Sendable {
    var out = Data()
    var err = Data()
}

public func fileSize(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
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
    guard let first = out.split(whereSeparator: \.isWhitespace).first, let kb = Int(first) else {
        return (0, false)
    }
    return (kb * 1024, true)
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
    let deadline = Date().addingTimeInterval(timeout)
    var total = 0
    let url = URL(fileURLWithPath: path)
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [],
        errorHandler: { _, _ in true }
    ) else {
        return (0, false)
    }
    while let item = enumerator.nextObject() as? URL {
        if let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true
        {
            total += values.fileSize ?? 0
        }
        if Date() > deadline {
            return (total, false)
        }
    }
    return (total, true)
}

public func parseMdlsDate(_ value: String) -> Date? {
    var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    if v.isEmpty || v == "(null)" { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f.date(from: v)
}

public func daysSince(_ date: Date?, now: Date = Date()) -> Double? {
    guard let date else { return nil }
    return max(0, now.timeIntervalSince(date) / 86400)
}
