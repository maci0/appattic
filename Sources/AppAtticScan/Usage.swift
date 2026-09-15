import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

let indexWindowS: TimeInterval = 120
let maxHistoryLines = 500_000

let envAssignRE = try! NSRegularExpression(pattern: #"^[A-Za-z_]\w*="#)
let cmdTokenRE = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_][\w.+-]*$"#)
let tsRE = try! NSRegularExpression(pattern: #"^:\s+(\d{9,11}):\d+;(.*)$"#)
let fishCmdRE = try! NSRegularExpression(pattern: #"^- cmd:\s+(.*)$"#)
let fishWhenRE = try! NSRegularExpression(pattern: #"^\s*when:\s+(\d+)$"#)
let appExeRE = try! NSRegularExpression(pattern: #"\.app/Contents/MacOS/([^/\s]+)"#, options: [.caseInsensitive])
let appBundleRE = try! NSRegularExpression(pattern: #"/([^/]+)\.app(?:/|$)"#, options: [.caseInsensitive])

let genericProc: Set<String> = [
    "app", "helper", "agent", "service", "desktop", "electron", "java",
    "python", "python3", "python3.12", "python3.13", "python3.14",
    "node", "ruby", "perl", "bash", "zsh", "sh", "dash", "plugin",
    "widget", "renderer", "gpu", "crashpad", "kernel_task", "launchd",
]

public struct HistoryIndex {
    public var lastSeen: [String: Date]
    public var everUsed: Set<String>
    /// Oldest timestamp in the history file, including commands that were not kept.
    public var oldestSeen: Date?
    public init(lastSeen: [String: Date] = [:], everUsed: Set<String> = [], oldestSeen: Date? = nil) {
        self.lastSeen = lastSeen
        self.everUsed = everUsed
        self.oldestSeen = oldestSeen
    }
}

public func effectiveLastUsed(
    _ lastUsed: Date?,
    _ dateAdded: Date?,
    windowSeconds: TimeInterval = 120
) -> Date? {
    guard let lastUsed else { return nil }
    guard let dateAdded else { return lastUsed }
    if abs(lastUsed.timeIntervalSince(dateAdded)) <= windowSeconds { return nil }
    return lastUsed
}

public func recentlyUsedXbelPath(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    (xdgDataHome(home: home, env: env) as NSString).appendingPathComponent("recently-used.xbel")
}

public func gnomeApplicationStatePath(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    ((xdgDataHome(home: home, env: env) as NSString).appendingPathComponent("gnome-shell") as NSString)
        .appendingPathComponent("application_state")
}

public func flatpakVarAppPath() -> String {
    (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".var/app")
}

final class XbelSink: NSObject, XMLParserDelegate {
    var hits: [String: Date] = [:]
    var bookmarkDate: Date?

    func record(_ key: String?, _ dt: Date?) {
        guard let key, let dt else { return }
        let k = posixLowercased(key.trimmingCharacters(in: .whitespaces))
        if k.isEmpty { return }
        if let prev = hits[k], prev >= dt { return }
        hits[k] = dt
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        if tag == "bookmark" {
            bookmarkDate = parseISODate(attributes["visited"]) ?? parseISODate(attributes["modified"])
        } else if tag == "application" {
            let dt = parseISODate(attributes["modified"]) ?? parseISODate(attributes["visited"]) ?? bookmarkDate
            record(attributes["name"], dt)
            if let execLine = attributes["exec"], !execLine.isEmpty {
                let first = execLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let base = URL(fileURLWithPath: first).lastPathComponent
                record(base, dt)
                record(URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent, dt)
            }
        }
    }
}

public func parseRecentlyUsedXbel(_ path: String) -> [String: Date] {
    guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
    let sink = XbelSink()
    parser.delegate = sink
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    _ = parser.parse()
    return sink.hits
}

final class GnomeStateSink: NSObject, XMLParserDelegate {
    var hits: [String: Date] = [:]

    func record(_ key: String, _ dt: Date) {
        let k = posixLowercased(key.trimmingCharacters(in: .whitespaces))
        if k.isEmpty { return }
        if let prev = hits[k], prev >= dt { return }
        hits[k] = dt
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        guard tag == "application" else { return }
        let appId = attributes["id"] ?? ""
        let raw = attributes["last-seen"] ?? ""
        if appId.isEmpty || raw.isEmpty { return }
        guard let epoch = Double(raw), epoch.isFinite else { return }
        let dt = dateFromUnixEpoch(epoch)
        record(appId, dt)
        let stem = posixLowercased(appId).hasSuffix(".desktop") ? String(appId.dropLast(8)) : appId
        record(stem, dt)
        record(URL(fileURLWithPath: stem).lastPathComponent, dt)
        if stem.contains(".") {
            let last = stem.split(separator: ".").last.map(String.init) ?? ""
            if last.count >= 4, !genericProc.contains(posixLowercased(last)) {
                record(last, dt)
            }
        }
    }
}

public func parseGnomeApplicationState(_ path: String) -> [String: Date] {
    guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
    let sink = GnomeStateSink()
    parser.delegate = sink
    parser.shouldResolveExternalEntities = false
    _ = parser.parse()
    return sink.hits
}

public func parseFlatpakVarAppMtimes(_ root: String) -> [String: Date] {
    var hits: [String: Date] = [:]
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return hits }
    for name in names {
        let path = (root as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let dt = attrs[.modificationDate] as? Date
        else { continue }
        let key = posixLowercased(name)
        if hits[key] == nil || dt > hits[key]! { hits[key] = dt }
        if key.contains(".") {
            let last = key.split(separator: ".").last.map(String.init) ?? ""
            if last.count >= 4, !genericProc.contains(last) {
                if hits[last] == nil || dt > hits[last]! { hits[last] = dt }
            }
        }
    }
    return hits
}

func firstCommandToken(_ cmd: String) -> String? {
    for tok in cmd.split(whereSeparator: \.isWhitespace).map(String.init) {
        if fullMatch(envAssignRE, tok) { continue }
        return tok.split(separator: "/").last.map(String.init)
    }
    return nil
}

func noteHistoryTime(_ ts: Date?, index: inout HistoryIndex) {
    guard let ts else { return }
    if let prev = index.oldestSeen, prev <= ts { return }
    index.oldestSeen = ts
}

func retainHistoryToken(_ token: String, keep: Set<String>?) -> Bool {
    guard let keep else { return true }
    return keep.contains(token)
}

public func parseHistoryFile(_ path: String, index: inout HistoryIndex, keep: Set<String>? = nil) {
    guard let text = readUTF8File(path) else { return }
    let bytes = Array(text.utf8)
    if !historyBytesAreASCII(bytes) {
        parseHistoryFileRegex(text, index: &index, keep: keep)
        return
    }
    parseHistoryASCII(bytes, index: &index, keep: keep)
}

// MARK: - ASCII-fast history scanning
//
// The regex path below runs four NSRegularExpressions per line plus `line as
// NSString`, a `String(raw)` per line, and `split().map(String.init)` per
// command: 445 ms for a 50 000-line zsh history. The patterns match ASCII only
// in practice, so scan UTF-8 bytes directly and keep the regex path for files
// that carry non-ASCII bytes (where `\w`/`\s` are Unicode classes).

/// Word-chunked scan for any byte with the high bit set. Returns false so the
/// caller can fall back to the Unicode path.
func historyBytesAreASCII(_ bytes: [UInt8]) -> Bool {
    let n = bytes.count
    let ascii = bytes.withUnsafeBytes { raw -> Bool in
        let words = n / 8
        var i = 0
        while i < words {
            if raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) & 0x8080_8080_8080_8080 != 0 {
                return false
            }
            i += 1
        }
        var j = words * 8
        while j < n {
            if raw[j] >= 0x80 { return false }
            j += 1
        }
        return true
    }
    return ascii
}

@inline(__always) func hxDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

/// ICU `\s` restricted to ASCII, and Swift `Character.isWhitespace` for ASCII.
@inline(__always) func hxSpace(_ b: UInt8) -> Bool { b == 0x20 || (b >= 0x09 && b <= 0x0D) }

/// Unicode `CharacterSet.whitespaces` restricted to ASCII (tab and Zs).
@inline(__always) func hxTrimEdge(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

@inline(__always) func hxWord(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
}

func hxDigitsValue(_ b: [UInt8], _ i: Int, _ j: Int) -> Double {
    var v = 0
    var k = i
    while k < j {
        v = v * 10 + Int(b[k] - 0x30)
        k += 1
    }
    return Double(v)
}

/// `fullMatch(envAssignRE, tok)` for `^[A-Za-z_]\w*=$` on ASCII bytes.
@inline(__always)
func hxIsEnvAssign(_ b: [UInt8], _ i: Int, _ j: Int) -> Bool {
    guard j - i >= 2, b[j - 1] == 0x3D else { return false }
    let f = b[i]
    guard (f >= 0x41 && f <= 0x5A) || (f >= 0x61 && f <= 0x7A) || f == 0x5F else { return false }
    var k = i + 1
    while k < j - 1 {
        if !hxWord(b[k]) { return false }
        k += 1
    }
    return true
}

/// `fullMatch(cmdTokenRE, tok)` for `^[A-Za-z0-9_][\w.+-]*$` on ASCII bytes.
@inline(__always)
func hxIsCommandToken(_ b: [UInt8], _ i: Int, _ j: Int) -> Bool {
    guard j > i else { return false }
    let f = b[i]
    guard (f >= 0x41 && f <= 0x5A) || (f >= 0x61 && f <= 0x7A) || (f >= 0x30 && f <= 0x39) || f == 0x5F else {
        return false
    }
    var k = i + 1
    while k < j {
        let c = b[k]
        if !(hxWord(c) || c == 0x2E || c == 0x2B || c == 0x2D) { return false }
        k += 1
    }
    return true
}

/// `firstCommandToken` on ASCII bytes: first whitespace-delimited token that is
/// not an env assignment, reduced to its last non-empty `/` segment.
func hxFirstCommand(_ b: [UInt8], _ start: Int, _ end: Int) -> (Int, Int)? {
    var i = start
    while i < end {
        while i < end, hxSpace(b[i]) { i += 1 }
        if i >= end { return nil }
        var j = i
        while j < end, !hxSpace(b[j]) { j += 1 }
        if !hxIsEnvAssign(b, i, j) {
            var e = j
            while e > i, b[e - 1] == 0x2F { e -= 1 }
            if e == i { return nil }
            var s = e
            while s > i, b[s - 1] != 0x2F { s -= 1 }
            return (s, e)
        }
        i = j
    }
    return nil
}

/// `posixLowercased` for an ASCII token, without a heap allocation for the
/// intermediate byte buffer.
func hxLowerToken(_ b: [UInt8], _ i: Int, _ j: Int) -> String {
    let n = j - i
    guard n > 0 else { return "" }
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: n) { buf in
        for k in 0..<n {
            let c = b[i + k]
            buf[k] = (c >= 0x41 && c <= 0x5A) ? c &+ 32 : c
        }
        return String(decoding: UnsafeBufferPointer(start: buf.baseAddress, count: n), as: UTF8.self)
    }
}

/// Shared tail of both history formats: validate, filter, index one command.
@inline(__always)
func hxRecordCommand(
    _ b: [UInt8],
    _ cs: Int,
    _ ce: Int,
    ts: Date?,
    index: inout HistoryIndex,
    keep: Set<String>?
) {
    guard cs < ce, let (fs, fe) = hxFirstCommand(b, cs, ce), hxIsCommandToken(b, fs, fe) else { return }
    if let keep, !keep.contains(String(decoding: b[fs..<fe], as: UTF8.self)) { return }
    let lower = hxLowerToken(b, fs, fe)
    index.everUsed.insert(lower)
    if let ts {
        if let prev = index.lastSeen[lower], prev >= ts { return }
        index.lastSeen[lower] = ts
    }
}

func parseHistoryASCII(_ bytes: [UInt8], index: inout HistoryIndex, keep: Set<String>?) {
    let count = bytes.count
    var lineNo = 0
    var pos = 0
    while pos <= count {
        if lineNo >= maxHistoryLines { break }
        lineNo += 1
        var end = pos
        while end < count, bytes[end] != 0x0A { end += 1 }
        var stop = end
        if stop > pos, bytes[stop - 1] == 0x0D { stop -= 1 }

        var trimmedStart = pos
        while trimmedStart < stop, hxTrimEdge(bytes[trimmedStart]) { trimmedStart += 1 }
        let blank = trimmedStart >= stop
        let comment = !blank && bytes[pos] == 0x23
        if !blank, !comment {
            var tsStart = -1
            var tsCount = 0
            var cmdStart = -1
            var cmdEnd = -1
            if bytes[pos] == 0x3A {
                var p = pos + 1
                while p < stop, hxSpace(bytes[p]) { p += 1 }
                if p > pos + 1 {
                    let d0 = p
                    while p < stop, hxDigit(bytes[p]) { p += 1 }
                    tsCount = p - d0
                    tsStart = d0
                    if tsCount >= 9, tsCount <= 11, p < stop, bytes[p] == 0x3A {
                        p += 1
                        let d2 = p
                        while p < stop, hxDigit(bytes[p]) { p += 1 }
                        if p > d2, p < stop, bytes[p] == 0x3B {
                            p += 1
                            cmdStart = p
                            cmdEnd = stop
                        }
                    }
                }
            }
            var ts: Date?
            if cmdStart < 0 {
                cmdStart = trimmedStart
                cmdEnd = stop
            } else {
                ts = dateFromUnixEpoch(hxDigitsValue(bytes, tsStart, tsStart + tsCount))
            }
            var cs = cmdStart
            while cs < cmdEnd, hxTrimEdge(bytes[cs]) { cs += 1 }
            var ce = cmdEnd
            while ce > cs, hxTrimEdge(bytes[ce - 1]) { ce -= 1 }
            noteHistoryTime(ts, index: &index)
            if cs < ce {
                hxRecordCommand(bytes, cs, ce, ts: ts, index: &index, keep: keep)
            }
        }
        if end >= count { break }
        pos = end + 1
    }
}

public func parseFishHistory(_ path: String, index: inout HistoryIndex, keep: Set<String>? = nil) {
    guard let text = readUTF8File(path) else { return }
    let bytes = Array(text.utf8)
    if !historyBytesAreASCII(bytes) {
        parseFishHistoryRegex(text, index: &index, keep: keep)
        return
    }
    parseFishHistoryASCII(bytes, index: &index, keep: keep)
}

func parseFishHistoryASCII(_ bytes: [UInt8], index: inout HistoryIndex, keep: Set<String>?) {
    let count = bytes.count
    var lineNo = 0
    var pos = 0
    var pending: (Int, Int)?
    while pos <= count {
        if lineNo >= maxHistoryLines { break }
        lineNo += 1
        var end = pos
        while end < count, bytes[end] != 0x0A { end += 1 }
        var stop = end
        if stop > pos, bytes[stop - 1] == 0x0D { stop -= 1 }

        var handledByCmd = false
        if stop - pos >= 6,
           bytes[pos] == 0x2D, bytes[pos + 1] == 0x20,
           bytes[pos + 2] == 0x63, bytes[pos + 3] == 0x6D,
           bytes[pos + 4] == 0x64, bytes[pos + 5] == 0x3A {
            var p = pos + 6
            while p < stop, hxSpace(bytes[p]) { p += 1 }
            if p > pos + 6 {
                var a = p
                var bEnd = stop
                while a < bEnd, hxTrimEdge(bytes[a]) { a += 1 }
                while bEnd > a, hxTrimEdge(bytes[bEnd - 1]) { bEnd -= 1 }
                pending = (a, bEnd)
                handledByCmd = true
            }
        }
        if !handledByCmd, let (ps, pe) = pending {
            var p = pos
            while p < stop, hxSpace(bytes[p]) { p += 1 }
            if stop - p >= 5,
               bytes[p] == 0x77, bytes[p + 1] == 0x68, bytes[p + 2] == 0x65,
               bytes[p + 3] == 0x6E, bytes[p + 4] == 0x3A {
                var q = p + 5
                while q < stop, hxSpace(bytes[q]) { q += 1 }
                if q > p + 5 {
                    var d = q
                    while d < stop, hxDigit(bytes[d]) { d += 1 }
                    if d > q, d == stop {
                        let ts = dateFromUnixEpoch(hxDigitsValue(bytes, q, d))
                        noteHistoryTime(ts, index: &index)
                        hxRecordCommand(bytes, ps, pe, ts: ts, index: &index, keep: keep)
                        pending = nil
                    }
                }
            }
        }
        if end >= count { break }
        pos = end + 1
    }
}

func parseHistoryFileRegex(_ text: String, index: inout HistoryIndex, keep: Set<String>? = nil) {
    // `components` splits CRLF: Swift treats "\r\n" as one grapheme cluster, so
        // `split(separator: "\n")` never splits a CRLF history file at all.
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
        if n >= maxHistoryLines { break }
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        var ts: Date?
        var cmd: String
        if let m = tsRE.firstMatch(in: line, range: range), m.numberOfRanges >= 3,
           let tR = Range(m.range(at: 1), in: line),
           let cR = Range(m.range(at: 2), in: line) {
            if let epoch = TimeInterval(line[tR]) {
                ts = dateFromUnixEpoch(epoch)
            }
            cmd = String(line[cR]).trimmingCharacters(in: .whitespaces)
        } else {
            cmd = line.trimmingCharacters(in: .whitespaces)
        }
        noteHistoryTime(ts, index: &index)
        if cmd.isEmpty { continue }
        guard let first = firstCommandToken(cmd), fullMatch(cmdTokenRE, first) else { continue }
        guard retainHistoryToken(first, keep: keep) else { continue }
        let token = posixLowercased(first)
        index.everUsed.insert(token)
        if let ts {
            if let prev = index.lastSeen[token], prev >= ts { continue }
            index.lastSeen[token] = ts
        }
    }
}

func parseFishHistoryRegex(_ text: String, index: inout HistoryIndex, keep: Set<String>? = nil) {
    var pending: String?
    // `components` splits CRLF: Swift treats "\r\n" as one grapheme cluster, so
        // `split(separator: "\n")` never splits a CRLF history file at all.
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
        if n >= maxHistoryLines { break }
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = fishCmdRE.firstMatch(in: line, range: range), m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: line) {
            pending = String(line[r]).trimmingCharacters(in: .whitespaces)
            continue
        }
        if let m = fishWhenRE.firstMatch(in: line, range: range), m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: line), let pendingCmd = pending {
            let ts = TimeInterval(line[r]).map(dateFromUnixEpoch)
            noteHistoryTime(ts, index: &index)
            if let first = firstCommandToken(pendingCmd), fullMatch(cmdTokenRE, first), retainHistoryToken(first, keep: keep) {
                let token = posixLowercased(first)
                index.everUsed.insert(token)
                if let ts, index.lastSeen[token].map({ ts > $0 }) ?? true {
                    index.lastSeen[token] = ts
                }
            }
            pending = nil
        }
    }
}

public func loadHistory(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment,
    keep: Set<String>? = nil
) -> HistoryIndex {
    var idx = HistoryIndex()
    let ns = home as NSString
    for name in [".zsh_history", ".bash_history", ".histfile"] {
        parseHistoryFile(ns.appendingPathComponent(name), index: &idx, keep: keep)
    }
    let data = xdgDataHome(home: home, env: env) as NSString
    let config = xdgConfigHome(home: home, env: env) as NSString
    var seen = Set<String>()
    for path in [
        (data.appendingPathComponent("fish") as NSString).appendingPathComponent("fish_history"),
        (ns.appendingPathComponent(".local/share/fish") as NSString).appendingPathComponent("fish_history"),
        (config.appendingPathComponent("fish") as NSString).appendingPathComponent("fish_history"),
        (ns.appendingPathComponent(".config/fish") as NSString).appendingPathComponent("fish_history"),
    ] {
        let abs = URL(fileURLWithPath: path).standardizedFileURL.path
        if seen.insert(abs).inserted {
            parseFishHistory(path, index: &idx, keep: keep)
        }
    }
    return idx
}

public func innerExecutablePath(_ appPath: String, executable: String?) -> String? {
    guard let executable, !executable.isEmpty, !appPath.isEmpty else { return nil }
    for base in appBundleBases(appPath) {
        for rel in ["Contents/MacOS/\(executable)", executable] {
            let path = (base as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return path
            }
        }
    }
    return nil
}

public func appUsageKeys(_ app: AppRecord) -> Set<String> {
    var keys: Set<String> = []
    func addRaw(_ value: String) {
        let v = posixLowercased(value.trimmingCharacters(in: .whitespaces))
        if v.isEmpty { return }
        keys.insert(v)
        let base = URL(fileURLWithPath: v).lastPathComponent
        keys.insert(base)
        keys.insert(URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent)
    }
    addRaw(app.bundleId ?? "")
    addRaw(app.displayName)
    addRaw(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
    addRaw(app.extra["executable"] ?? "")
    addRaw(app.extra["wmclass"] ?? "")
    let desktopId = app.extra["desktop_id"] ?? ""
    addRaw(desktopId)
    if !desktopId.isEmpty, !posixLowercased(desktopId).hasSuffix(".desktop") {
        addRaw(desktopId + ".desktop")
    }
    let desktop = app.extra["desktop"] ?? ""
    if !desktop.isEmpty {
        let base = URL(fileURLWithPath: desktop).lastPathComponent
        addRaw(base)
        addRaw(URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent)
    }
    if !app.displayName.isEmpty {
        addRaw(app.displayName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
    }
    for k in Array(keys) {
        keys.formUnion(expandNameAliases(k))
    }
    keys.remove("")
    return keys
}

public func processBasenames(_ psOutput: String) -> Set<String> {
    var names: Set<String> = []
    for raw in psOutput.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        for m in appExeRE.matches(in: line, range: range) where m.numberOfRanges >= 2 {
            names.insert(posixLowercased(ns.substring(with: m.range(at: 1))))
        }
        for m in appBundleRE.matches(in: line, range: range) where m.numberOfRanges >= 2 {
            names.insert(posixLowercased(ns.substring(with: m.range(at: 1))))
        }
        let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let baseName = URL(fileURLWithPath: token).lastPathComponent
        if !baseName.contains(" ") {
            let base = posixLowercased(baseName)
            if !base.isEmpty {
                names.insert(base)
                names.insert(URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent)
            }
        }
    }
    return names
}

public func appMatchesRunning(_ app: AppRecord, comms: Set<String>) -> Bool {
    var keys: Set<String> = []
    let exe = app.extra["executable"] ?? app.extra["wmclass"]
    if let exe, !exe.isEmpty {
        keys.insert(posixLowercased(URL(fileURLWithPath: exe).lastPathComponent))
    }
    var base = posixLowercased(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
    if base.hasSuffix(".app") { base = String(base.dropLast(4)) }
    if base.count >= 4 { keys.insert(base) }
    let display = posixLowercased(app.displayName)
    if !display.isEmpty, !display.contains(" "), display.count >= 4 {
        keys.insert(display)
    }
    let last = posixLowercased(app.bundleId ?? "").split(separator: ".").last.map(String.init) ?? ""
    if last.count >= 5 { keys.insert(last) }
    keys.subtract(genericProc)
    keys.remove("")
    return !keys.isDisjoint(with: comms)
}

func runningCommBasenames(run: CommandRun) -> Set<String> {
    for cmd in [
        ["ps", "-axo", "command="],
        ["ps", "-eo", "args="],
        ["ps", "-axo", "comm="],
        ["ps", "-eo", "comm="],
    ] {
        let (rc, out, _) = run(cmd, 10)
        if rc == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return processBasenames(out)
        }
    }
    return []
}

func mdlsMeta(
    _ path: String,
    dropIfNearCreated: Bool = true,
    run: CommandRun
) -> (Date?, Date?, String?) {
    let (rc, out, _) = run([
        "mdls",
        "-name", "kMDItemLastUsedDate",
        "-name", "kMDItemDateAdded",
        "-name", "kMDItemFSCreationDate",
        "-name", "kMDItemDescription",
        path,
    ], 20)
    if rc != 0 { return (nil, nil, nil) }
    var lastUsed: Date?
    var dateAdded: Date?
    var created: Date?
    var description: String?
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        guard s.contains(" = ") else { continue }
        let parts = s.components(separatedBy: " = ")
        guard parts.count >= 2 else { continue }
        let k = parts[0].trimmingCharacters(in: .whitespaces)
        var value = parts.dropFirst().joined(separator: " = ").trimmingCharacters(in: .whitespaces)
        if k == "kMDItemDescription" {
            if value == "" || value == "(null)" {
                description = nil
            } else {
                if value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                let t = value.trimmingCharacters(in: .whitespaces)
                description = t.isEmpty ? nil : t
            }
            continue
        }
        let dt = parseMdlsDate(value)
        if k == "kMDItemLastUsedDate" { lastUsed = dt }
        else if k == "kMDItemDateAdded" { dateAdded = dt }
        else if k == "kMDItemFSCreationDate" { created = dt }
    }
    let installed = dateAdded ?? created
    var used = effectiveLastUsed(lastUsed, dateAdded)
    if dropIfNearCreated, used != nil, dateAdded == nil {
        used = effectiveLastUsed(used, created)
    }
    return (used, installed, description)
}

public func mdlsDates(
    _ path: String,
    dropIfNearCreated: Bool = true,
    run: CommandRun = runCommand
) -> (Date?, Date?) {
    let (used, installed, _) = mdlsMeta(path, dropIfNearCreated: dropIfNearCreated, run: run)
    return (used, installed)
}

func mergeHits(_ hits: inout [String: Date], _ extra: [String: Date]) {
    for (key, dt) in extra {
        if let prev = hits[key], prev >= dt { continue }
        hits[key] = dt
    }
}

func linuxLaunchHits(xbelPath: String?, gnomePath: String?, varApp: String?) -> [String: Date] {
    var hits: [String: Date] = [:]
    let xbel = xbelPath ?? recentlyUsedXbelPath()
    if FileManager.default.fileExists(atPath: xbel) {
        hits.merge(parseRecentlyUsedXbel(xbel)) { a, b in a > b ? a : b }
    }
    let gnome = gnomePath ?? gnomeApplicationStatePath()
    if FileManager.default.fileExists(atPath: gnome) {
        mergeHits(&hits, parseGnomeApplicationState(gnome))
    }
    let varAppPath = varApp ?? flatpakVarAppPath()
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: varAppPath, isDirectory: &isDir), isDir.boolValue {
        mergeHits(&hits, parseFlatpakVarAppMtimes(varAppPath))
    }
    return hits
}

public func fillAppUsage(
    _ apps: inout [AppRecord],
    progress: (String) -> Void = { _ in },
    run: CommandRun = runCommand,
    runningComms: Set<String>? = nil,
    xbelPath: String? = nil,
    gnomeStatePath: String? = nil,
    flatpakVarApp: String? = nil,
    now: Date = Date()
) {
    if PlatformOverride.isLinux {
        let hits = linuxLaunchHits(xbelPath: xbelPath, gnomePath: gnomeStatePath, varApp: flatpakVarApp)
        progress("  · checking recently-used.xbel (\(hits.count) apps)…")
        for i in apps.indices {
            if FileManager.default.fileExists(atPath: apps[i].path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: apps[i].path) {
                let birth = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
                apps[i].installedAt = birth
            }
            let keys = appUsageKeys(apps[i])
            var best: Date?
            for k in keys {
                if let dt = hits[k], best == nil || dt > best! { best = dt }
            }
            if let best, !hasAuthoritativeUsage(apps[i]),
               let used = effectiveLastUsed(best, apps[i].installedAt) {
                apps[i].lastUsed = used
                apps[i].lastUsedSource = "recently-used"
            }
        }
        markRunning(&apps, runningComms: runningComms, run: run, now: now)
        return
    }

    progress("  · checking Spotlight usage metadata for \(apps.count) apps…")
    let results = pmap(apps.map(\.path), workers: 16) { mdlsMeta($0, run: run) }
    for i in apps.indices {
        let (lastUsed, installedAt, description) = results[i]
        if let lastUsed, !hasAuthoritativeUsage(apps[i]), apps[i].lastUsed == nil || lastUsed > apps[i].lastUsed! {
            apps[i].lastUsed = lastUsed
            apps[i].lastUsedSource = "spotlight"
        }
        if let installedAt {
            apps[i].installedAt = installedAt
        } else if FileManager.default.fileExists(atPath: apps[i].path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: apps[i].path) {
            apps[i].installedAt = attrs[.creationDate] as? Date
        }
        if let description, !description.isEmpty, apps[i].extra["comment"] == nil {
            apps[i].extra["comment"] = description
        }
    }

    var needInner: [(Int, String)] = []
    for i in apps.indices {
        if let inner = innerExecutablePath(apps[i].path, executable: apps[i].extra["executable"]) {
            needInner.append((i, inner))
        }
    }
    if !needInner.isEmpty {
        let innerDates = pmap(needInner.map(\.1), workers: 16) { mdlsDates($0, run: run) }
        for (pair, dates) in zip(needInner, innerDates) {
            let i = pair.0
            var used = dates.0
            if let usedDt = used, let installed = apps[i].installedAt,
               abs(usedDt.timeIntervalSince(installed)) <= indexWindowS {
                used = nil
            }
            if let used, !hasAuthoritativeUsage(apps[i]), apps[i].lastUsed == nil || used > apps[i].lastUsed! {
                apps[i].lastUsed = used
                apps[i].lastUsedSource = "spotlight"
            }
        }
    }
    markRunning(&apps, runningComms: runningComms, run: run, now: now)
}

func hasAuthoritativeUsage(_ app: AppRecord) -> Bool {
    app.lastUsed != nil && app.lastUsedSource == "steam"
}

func markRunning(_ apps: inout [AppRecord], runningComms: Set<String>?, run: CommandRun, now: Date = Date()) {
    let comms = runningComms ?? runningCommBasenames(run: run)
    if comms.isEmpty { return }
    for i in apps.indices where appMatchesRunning(apps[i], comms: comms) {
        apps[i].lastUsed = now
        apps[i].lastUsedSource = "running"
    }
}

public func lastUsedFromHistory(_ names: [String], index: HistoryIndex) -> (Date?, Bool) {
    var best: Date?
    var ever = false
    for n in names {
        let key = posixLowercased(n)
        if index.everUsed.contains(key) { ever = true }
        if let ts = index.lastSeen[key], best == nil || ts > best! {
            best = ts
        }
    }
    return (best, ever)
}

public func historySpanDays(_ index: HistoryIndex, now: Date = Date()) -> Double? {
    guard let oldest = index.oldestSeen ?? index.lastSeen.values.min() else { return nil }
    return daysSince(oldest, now: now)
}
