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
    public init(lastSeen: [String: Date] = [:], everUsed: Set<String> = []) {
        self.lastSeen = lastSeen
        self.everUsed = everUsed
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

public func recentlyUsedXbelPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (home as NSString).appendingPathComponent(".local/share")
    return (data as NSString).appendingPathComponent("recently-used.xbel")
}

public func gnomeApplicationStatePath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (home as NSString).appendingPathComponent(".local/share")
    return ((data as NSString).appendingPathComponent("gnome-shell") as NSString).appendingPathComponent("application_state")
}

public func flatpakVarAppPath() -> String {
    (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".var/app")
}

final class XbelSink: NSObject, XMLParserDelegate {
    var hits: [String: Date] = [:]
    var bookmarkDate: Date?

    func record(_ key: String?, _ dt: Date?) {
        guard let key, let dt else { return }
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
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
    _ = parser.parse()
    return sink.hits
}

final class GnomeStateSink: NSObject, XMLParserDelegate {
    var hits: [String: Date] = [:]

    func record(_ key: String, _ dt: Date) {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
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
        guard let epoch = Double(raw) else { return }
        let dt = Date(timeIntervalSince1970: epoch)
        record(appId, dt)
        let stem = appId.lowercased().hasSuffix(".desktop") ? String(appId.dropLast(8)) : appId
        record(stem, dt)
        record(URL(fileURLWithPath: stem).lastPathComponent, dt)
        if stem.contains(".") {
            let last = stem.split(separator: ".").last.map(String.init) ?? ""
            if last.count >= 4, !genericProc.contains(last.lowercased()) {
                record(last, dt)
            }
        }
    }
}

public func parseGnomeApplicationState(_ path: String) -> [String: Date] {
    guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
    let sink = GnomeStateSink()
    parser.delegate = sink
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
        let key = name.lowercased()
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

public func parseHistoryFile(_ path: String, index: inout HistoryIndex) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return }
    defer { try? handle.close() }
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
    for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if n >= maxHistoryLines { break }
        let line = String(raw)
        if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        var ts: Date?
        var cmd: String
        if let m = tsRE.firstMatch(in: line, range: range), m.numberOfRanges >= 3,
           let tR = Range(m.range(at: 1), in: line),
           let cR = Range(m.range(at: 2), in: line) {
            if let epoch = TimeInterval(line[tR]) {
                ts = Date(timeIntervalSince1970: epoch)
            }
            cmd = String(line[cR]).trimmingCharacters(in: .whitespaces)
        } else {
            cmd = line.trimmingCharacters(in: .whitespaces)
        }
        if cmd.isEmpty { continue }
        guard let first = firstCommandToken(cmd), fullMatch(cmdTokenRE, first) else { continue }
        index.everUsed.insert(first)
        if let ts {
            if let prev = index.lastSeen[first], prev >= ts { continue }
            index.lastSeen[first] = ts
        }
    }
}

public func parseFishHistory(_ path: String, index: inout HistoryIndex) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    else { return }
    var pending: String?
    for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if n >= maxHistoryLines { break }
        let line = String(raw)
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = fishCmdRE.firstMatch(in: line, range: range), m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: line) {
            pending = String(line[r]).trimmingCharacters(in: .whitespaces)
            continue
        }
        if let m = fishWhenRE.firstMatch(in: line, range: range), m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: line), let pendingCmd = pending {
            let first = pendingCmd.split(whereSeparator: \.isWhitespace).first.map { $0.split(separator: "/").last.map(String.init) ?? "" } ?? ""
            if !first.isEmpty, fullMatch(cmdTokenRE, first) {
                index.everUsed.insert(first)
                if let epoch = TimeInterval(line[r]) {
                    let ts = Date(timeIntervalSince1970: epoch)
                    if index.lastSeen[first] == nil || ts > index.lastSeen[first]! {
                        index.lastSeen[first] = ts
                    }
                }
            }
            pending = nil
        }
    }
}

public func loadHistory() -> HistoryIndex {
    var idx = HistoryIndex()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for name in [".zsh_history", ".bash_history", ".histfile"] {
        parseHistoryFile((home as NSString).appendingPathComponent(name), index: &idx)
    }
    parseFishHistory(((home as NSString).appendingPathComponent(".local/share/fish") as NSString).appendingPathComponent("fish_history"), index: &idx)
    parseFishHistory(((home as NSString).appendingPathComponent(".config/fish") as NSString).appendingPathComponent("fish_history"), index: &idx)
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
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
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
    if !desktopId.isEmpty, !desktopId.lowercased().hasSuffix(".desktop") {
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
            names.insert(ns.substring(with: m.range(at: 1)).lowercased())
        }
        for m in appBundleRE.matches(in: line, range: range) where m.numberOfRanges >= 2 {
            names.insert(ns.substring(with: m.range(at: 1)).lowercased())
        }
        let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let baseName = URL(fileURLWithPath: token).lastPathComponent
        if !baseName.contains(" ") {
            let base = baseName.lowercased()
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
        keys.insert(URL(fileURLWithPath: exe).lastPathComponent.lowercased())
    }
    var base = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.lowercased()
    if base.hasSuffix(".app") { base = String(base.dropLast(4)) }
    if base.count >= 4 { keys.insert(base) }
    let display = app.displayName.lowercased()
    if !display.isEmpty, !display.contains(" "), display.count >= 4 {
        keys.insert(display)
    }
    let last = (app.bundleId ?? "").lowercased().split(separator: ".").last.map(String.init) ?? ""
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
    flatpakVarApp: String? = nil
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
        markRunning(&apps, runningComms: runningComms, run: run)
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
    markRunning(&apps, runningComms: runningComms, run: run)
}

func hasAuthoritativeUsage(_ app: AppRecord) -> Bool {
    app.lastUsed != nil && app.lastUsedSource == "steam"
}

func markRunning(_ apps: inout [AppRecord], runningComms: Set<String>?, run: CommandRun) {
    let comms = runningComms ?? runningCommBasenames(run: run)
    if comms.isEmpty { return }
    let now = Date()
    for i in apps.indices where appMatchesRunning(apps[i], comms: comms) {
        apps[i].lastUsed = now
        apps[i].lastUsedSource = "running"
    }
}

public func lastUsedFromHistory(_ names: [String], index: HistoryIndex) -> (Date?, Bool) {
    var best: Date?
    var ever = false
    for n in names {
        if index.everUsed.contains(n) { ever = true }
        if let ts = index.lastSeen[n], best == nil || ts > best! {
            best = ts
        }
    }
    return (best, ever)
}

public func historySpanDays(_ index: HistoryIndex, now: Date = Date()) -> Double? {
    guard let oldest = index.lastSeen.values.min() else { return nil }
    return daysSince(oldest, now: now)
}
