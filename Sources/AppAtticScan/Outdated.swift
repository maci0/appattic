import Foundation

public final class OutdatedPkg {
    public var name: String
    public var manager: String
    public var currentVersion: String?
    public var latestVersion: String?
    public var title: String?
    public var summary: String?
    public var reason: String?
    public var bundleId: String?
    public var kind: String?

    public init(
        name: String,
        manager: String,
        currentVersion: String? = nil,
        latestVersion: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        reason: String? = nil,
        bundleId: String? = nil,
        kind: String? = nil
    ) {
        self.name = name
        self.manager = manager
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.title = title
        self.summary = summary
        self.reason = reason
        self.bundleId = bundleId
        self.kind = kind
    }

    public var updatable: Bool {
        if kind == "untrusted" { return false }
        switch manager {
        case "brew-formula", "brew-cask", "flatpak": return true
        default: return false
        }
    }

    public func toEntry() -> OutdatedEntry {
        OutdatedEntry(
            name: name,
            manager: manager,
            current_version: currentVersion,
            latest_version: latestVersion,
            title: title,
            summary: summary ?? outdatedSummaryFallback(self),
            reason: outdatedReason(self),
            kind: kind ?? defaultOutdatedKind(manager)
        )
    }
}

public func outdatedReportFooter(_ pkgs: [OutdatedPkg]) -> [String] {
    var lines: [String] = []
    if pkgs.contains(where: \.updatable) {
        lines.append("Homebrew and Flatpak: appattic update --dry-run, then appattic update.")
    }
    if pkgs.contains(where: { $0.kind == "untrusted" }) {
        lines.append("Untrusted casks stay listed. AppAttic will not trust the tap.")
    }
    if pkgs.contains(where: {
        ["app-store", "apt", "snap", "pacman", "dnf", "zypper"].contains($0.manager)
    }) {
        lines.append("App Store, apt, pacman, dnf, zypper, and Snap are report-only.")
    }
    return lines
}

func defaultOutdatedKind(_ manager: String) -> String {
    switch manager {
    case "brew-formula": return "formula"
    case "brew-cask": return "cask"
    case "app-store": return "app"
    default: return manager
    }
}

private let managerLabel: [String: String] = [
    "brew-formula": "Homebrew",
    "brew-cask": "Homebrew",
    "app-store": "the App Store",
    "flatpak": "Flatpak",
    "snap": "Snap",
    "apt": "apt",
    "pacman": "pacman",
    "dnf": "dnf",
    "zypper": "zypper",
]

public let outdatedSkippedManagersNote =
    "Untrusted casks, App Store, apt, pacman, dnf, zypper, and Snap are skipped."

public func outdatedReason(_ pkg: OutdatedPkg) -> String {
    if let reason = pkg.reason, !reason.isEmpty { return reason }
    let mgr = managerLabel[pkg.manager] ?? pkg.manager.replacingOccurrences(of: "-", with: " ")
    let cur = pkg.currentVersion ?? "the installed version"
    let latest = pkg.latestVersion ?? "a newer version"
    if pkg.updatable {
        return "\(mgr) reports \(cur) installed and \(latest) available. You can update it from Outdated."
    }
    return "\(mgr) reports \(cur) installed and \(latest) available. AppAttic does not run this upgrade."
}

public func applyUntrustedCasks(_ pkgs: [OutdatedPkg], refused: [UntrustedCask]) -> [OutdatedPkg] {
    var out = pkgs
    for u in refused {
        let key = u.name.lowercased()
        if let existing = out.first(where: { $0.manager == "brew-cask" && $0.name.lowercased() == key }) {
            existing.kind = "untrusted"
            existing.reason = untrustedCaskReason(u)
            if existing.summary == nil || existing.summary?.isEmpty == true {
                existing.summary = untrustedCaskSummary(u)
            }
        } else {
            out.append(OutdatedPkg(
                name: u.name,
                manager: "brew-cask",
                summary: untrustedCaskSummary(u),
                reason: untrustedCaskReason(u),
                kind: "untrusted"
            ))
        }
    }
    return out
}

public func updateCommand(_ pkg: OutdatedPkg) -> String? {
    guard pkg.updatable else { return nil }
    let quoted = shellQuote(pkg.name)
    switch pkg.manager {
    case "brew-formula":
        return "brew upgrade \(quoted)"
    case "brew-cask":
        return "brew upgrade --cask \(quoted)"
    case "flatpak":
        return "flatpak update -y \(quoted)"
    default:
        return nil
    }
}

public func updateScript(_ pkgs: [OutdatedPkg]) -> String {
    let cmds = pkgs.compactMap(updateCommand)
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic package update",
        "# Review every line before running. Nothing here is updated automatically.",
        "",
    ]
    if cmds.isEmpty {
        lines.append("# Nothing to update. \(outdatedSkippedManagersNote)")
        return lines.joined(separator: "\n") + "\n"
    }
    lines.append("# Homebrew and Flatpak only")
    lines.append(contentsOf: cmds)
    return lines.joined(separator: "\n") + "\n"
}

public func updateScript(from data: ScanData, selectedIds: Set<String>? = nil) -> String {
    let pkgs = (data.outdated ?? []).compactMap { entry -> OutdatedPkg? in
        if let selectedIds, !selectedIds.contains(entry.id) { return nil }
        return OutdatedPkg(
            name: entry.name,
            manager: entry.manager,
            currentVersion: entry.current_version,
            latestVersion: entry.latest_version,
            title: entry.title,
            summary: entry.summary,
            reason: entry.reason,
            kind: entry.kind
        )
    }
    return updateScript(pkgs)
}

public func outdatedSummaryFallback(_ pkg: OutdatedPkg) -> String {
    if let summary = pkg.summary, !summary.isEmpty { return summary }
    let mgr = managerLabel[pkg.manager] ?? pkg.manager.replacingOccurrences(of: "-", with: " ")
    return "Package managed by \(mgr)"
}

public func parseBrewOutdatedJSON(_ text: String) -> [OutdatedPkg] {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    var out: [OutdatedPkg] = []
    for (key, manager) in [("formulae", "brew-formula"), ("casks", "brew-cask")] {
        for item in obj[key] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            var current: String?
            if let installed = item["installed_versions"] as? [String] {
                current = installed.first
            } else if let installed = item["installed_versions"] as? String {
                current = installed
            }
            out.append(OutdatedPkg(
                name: name,
                manager: manager,
                currentVersion: current,
                latestVersion: item["current_version"] as? String
            ))
        }
    }
    return out
}

public func queryBrew(
    _ brew: String,
    progress: ((String) -> Void)? = nil,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    if brew.isEmpty { return [] }
    progress?("  · checking for outdated Homebrew packages…")
    let (rc, out, _) = run([brew, "outdated", "--json=v2"], 90)
    if rc != 0 || out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
    return parseBrewOutdatedJSON(out)
}

public func brewPackageMeta(_ data: [String: Any]) -> ([String: String], [String: String]) {
    var summaries: [String: String] = [:]
    var titles: [String: String] = [:]
    for f in data["formulae"] as? [[String: Any]] ?? [] {
        let name = (f["name"] as? String) ?? (f["full_name"] as? String)
        let desc = (f["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let name, !name.isEmpty, !desc.isEmpty {
            summaries[name] = desc
        }
    }
    for c in data["casks"] as? [[String: Any]] ?? [] {
        guard let token = c["token"] as? String, !token.isEmpty else { continue }
        let desc = (c["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !desc.isEmpty { summaries[token] = desc }
        var pretty: String?
        if let names = c["name"] as? [String], let first = names.first {
            pretty = first.trimmingCharacters(in: .whitespaces)
        } else if let name = c["name"] as? String {
            pretty = name.trimmingCharacters(in: .whitespaces)
        }
        if let pretty, !pretty.isEmpty, pretty.lowercased() != token.lowercased() {
            titles[token] = pretty
        }
    }
    return (summaries, titles)
}

public func attachSummaries(
    _ pkgs: [OutdatedPkg],
    summaries: [String: String],
    titles: [String: String] = [:]
) {
    for p in pkgs {
        if p.summary == nil || p.summary?.isEmpty == true {
            let text = (summaries[p.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { p.summary = text }
        }
        if p.title == nil || p.title?.isEmpty == true {
            let text = (titles[p.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text.lowercased() != p.name.lowercased() {
                p.title = text
            }
        }
    }
}

private func flatpakRows(_ text: String) -> [String: (String?, String?, String?)] {
    var mapping: [String: (String?, String?, String?)] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        var parts: [String]
        if line.contains("\t") {
            parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        } else {
            let toks = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if toks.count <= 3 {
                parts = toks
            } else {
                parts = Array(toks.prefix(3)) + [toks.dropFirst(3).joined(separator: " ")]
            }
        }
        guard let key = parts.first?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { continue }
        let low = key.lowercased()
        if ["application", "application id", "name", "id"].contains(low) { continue }
        let version = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        var title = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : nil
        let summary = parts.count > 3 ? parts[3...].joined(separator: "\t").trimmingCharacters(in: .whitespaces) : nil
        if let t = title, t.lowercased() == key.lowercased() { title = nil }
        mapping[key] = (version, title, summary)
    }
    return mapping
}

public func parseFlatpakUpdates(_ updatesText: String, installedText: String = "") -> [OutdatedPkg] {
    let latest = flatpakRows(updatesText)
    let current = flatpakRows(installedText)
    var out: [OutdatedPkg] = []
    for (name, triple) in latest {
        var title = triple.1
        var summary = triple.2
        let cur = current[name]
        if let cur {
            if title == nil { title = cur.1 }
            if summary == nil { summary = cur.2 }
        }
        out.append(OutdatedPkg(
            name: name,
            manager: "flatpak",
            currentVersion: cur?.0,
            latestVersion: triple.0,
            title: title,
            summary: summary
        ))
    }
    return out
}

private func snapNameVersionMap(_ text: String) -> [String: String] {
    var mapping: [String: String] = [:]
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if lines.isEmpty { return mapping }
    if lines[0].lowercased().hasPrefix("all snaps up to date") { return mapping }
    let start = lines[0].split(whereSeparator: \.isWhitespace).first?.lowercased() == "name" ? 1 : 0
    for ln in lines.dropFirst(start) {
        let parts = ln.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2 {
            mapping[parts[0]] = parts[1]
        }
    }
    return mapping
}

public func parseSnapRefreshList(_ refreshText: String, installedText: String = "") -> [OutdatedPkg] {
    let latest = snapNameVersionMap(refreshText)
    let current = snapNameVersionMap(installedText)
    return latest.map { name, ver in
        OutdatedPkg(name: name, manager: "snap", currentVersion: current[name], latestVersion: ver)
    }
}

public func parseAptUpgradable(_ text: String) -> [OutdatedPkg] {
    let re = try! NSRegularExpression(pattern: #"^([^/]+)/\S+\s+(\S+)\s+\S+\s+\[upgradable from:\s*([^\]]+)\]"#)
    var out: [OutdatedPkg] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 4,
              let n = Range(m.range(at: 1), in: s),
              let latest = Range(m.range(at: 2), in: s),
              let cur = Range(m.range(at: 3), in: s)
        else { continue }
        out.append(OutdatedPkg(name: String(s[n]), manager: "apt", currentVersion: String(s[cur]), latestVersion: String(s[latest])))
    }
    return out
}

public func parsePacmanQu(_ text: String) -> [OutdatedPkg] {
    let re = try! NSRegularExpression(pattern: #"^(\S+)\s+(\S+)\s+->\s+(\S+)"#)
    var out: [OutdatedPkg] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 4,
              let n = Range(m.range(at: 1), in: s),
              let cur = Range(m.range(at: 2), in: s),
              let latest = Range(m.range(at: 3), in: s)
        else { continue }
        out.append(OutdatedPkg(
            name: String(s[n]),
            manager: "pacman",
            currentVersion: String(s[cur]),
            latestVersion: String(s[latest])
        ))
    }
    return out
}

public func parseDnfUpgrades(_ text: String) -> [OutdatedPkg] {
    let re = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9_+.-]+?)(?:\.(x86_64|aarch64|i686|noarch|ppc64le|s390x))?\s+(\S*[0-9]\S*)\s+\S+"#
    )
    var out: [OutdatedPkg] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { continue }
        let low = s.lowercased()
        if low.hasPrefix("last metadata") || low.hasPrefix("available upgrade") || low.hasPrefix("obsoleting") {
            continue
        }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 4,
              let n = Range(m.range(at: 1), in: s),
              let latest = Range(m.range(at: 3), in: s)
        else { continue }
        out.append(OutdatedPkg(
            name: String(s[n]),
            manager: "dnf",
            latestVersion: String(s[latest])
        ))
    }
    return out
}

public func parseZypperListUpdates(_ text: String) -> [OutdatedPkg] {
    var out: [OutdatedPkg] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || !s.contains("|") || s.hasPrefix("--") { continue }
        let cols = s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard cols.count >= 5 else { continue }
        let status = cols[0].lowercased()
        let name = cols[2]
        let current = cols[3]
        let available = cols[4]
        if status == "s" || name.isEmpty || name.lowercased() == "name" { continue }
        out.append(OutdatedPkg(
            name: name,
            manager: "zypper",
            currentVersion: current.isEmpty ? nil : current,
            latestVersion: available
        ))
    }
    return out
}

public func parseMasOutdated(_ text: String) -> [OutdatedPkg] {
    let re = try! NSRegularExpression(pattern: #"^(\d+)\s+(.+?)\s+\((.+?)\s+->\s+(.+?)\)$"#)
    var out: [OutdatedPkg] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 5,
              let idR = Range(m.range(at: 1), in: s),
              let nameR = Range(m.range(at: 2), in: s),
              let curR = Range(m.range(at: 3), in: s),
              let latestR = Range(m.range(at: 4), in: s)
        else { continue }
        out.append(OutdatedPkg(
            name: String(s[idR]),
            manager: "app-store",
            currentVersion: String(s[curR]).trimmingCharacters(in: .whitespaces),
            latestVersion: String(s[latestR]).trimmingCharacters(in: .whitespaces),
            title: String(s[nameR]).trimmingCharacters(in: .whitespaces)
        ))
    }
    return out
}

public func storeCountries(_ localeText: String? = nil) -> [String] {
    var text = localeText
    if text == nil {
        let (rc, out, _) = runCommand(["defaults", "read", "-g", "AppleLocale"], timeout: 5)
        if rc == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ProcessInfo.processInfo.environment["LANG"] ?? ""
        }
    }
    var countries: [String] = []
    let src = text ?? ""
    let rgRE = try! NSRegularExpression(pattern: #"rg=([a-z]{2})"#, options: [.caseInsensitive])
    let ns = src as NSString
    let full = NSRange(location: 0, length: ns.length)
    if let m = rgRE.firstMatch(in: src, range: full), m.numberOfRanges >= 2 {
        countries.append(ns.substring(with: m.range(at: 1)).lowercased())
    }
    let locRE = try! NSRegularExpression(pattern: #"_([A-Z]{2})"#)
    if let m = locRE.firstMatch(in: src, range: full), m.numberOfRanges >= 2 {
        let code = ns.substring(with: m.range(at: 1)).lowercased()
        if !countries.contains(code) { countries.append(code) }
    }
    if !countries.contains("us") { countries.append("us") }
    return countries
}

public func versionNewer(_ latest: String?, _ current: String?) -> Bool {
    func parts(_ v: String?) -> [Int] {
        var nums: [Int] = []
        let re = try! NSRegularExpression(pattern: #"\d+"#)
        let src = v ?? ""
        let ns = src as NSString
        for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range)) { nums.append(n) }
        }
        while nums.last == 0 { nums.removeLast() }
        return nums
    }
    let lp = parts(latest)
    let cp = parts(current)
    if lp.isEmpty || cp.isEmpty {
        return !(latest ?? "").isEmpty && (latest ?? "") != (current ?? "")
    }
    for (a, b) in zip(lp, cp) {
        if a != b { return a > b }
    }
    return lp.count > cp.count
}

public func itunesRowForBundle(_ data: [String: Any], bundleId: String) -> [String: Any]? {
    for row in data["results"] as? [[String: Any]] ?? [] {
        if row["bundleId"] as? String == bundleId { return row }
    }
    return nil
}

public func indexItunesResults(_ data: [String: Any]) -> [String: [String: Any]] {
    var out: [String: [String: Any]] = [:]
    for row in data["results"] as? [[String: Any]] ?? [] {
        if let bid = row["bundleId"] as? String { out[bid] = row }
        if let tid = row["trackId"] {
            out["\(tid)"] = row
        }
    }
    return out
}

public func parseMdlsMas(_ text: String) -> (String?, String?) {
    var adam: String?
    var category: String?
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        guard line.contains("=") else { continue }
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        var val: String? = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if val == "" || val == "(null)" { val = nil }
        if key == "kMDItemAppStoreAdamID" { adam = val }
        else if key == "kMDItemAppStoreCategory" { category = val }
    }
    return (adam, category)
}

public func shortDesc(_ text: String?, limit: Int = 220) -> String? {
    guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    let para = raw.components(separatedBy: "\n\n").first ?? raw
    let collapsed = para.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if collapsed.count <= limit { return collapsed }
    let prefix = String(collapsed.prefix(limit))
    if let r = prefix.range(of: " ", options: .backwards) {
        let trimmed = String(prefix[..<r.lowerBound])
        return trimmed.isEmpty ? String(collapsed.prefix(limit)) : trimmed
    }
    return String(collapsed.prefix(limit))
}

public func pkgFromItunes(
    displayName: String?,
    bundleId: String,
    current: String?,
    row: [String: Any]?
) -> OutdatedPkg? {
    guard let row else { return nil }
    if let bid = row["bundleId"] as? String, bid != bundleId { return nil }
    let latest = (row["version"] as? String)?.trimmingCharacters(in: .whitespaces)
    let latestVal = (latest?.isEmpty == false) ? latest : nil
    guard versionNewer(latestVal, current) else { return nil }
    var title = (displayName ?? (row["trackName"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    if title.isEmpty { title = "" }
    var titleOut: String? = title.isEmpty ? nil : title
    if let t = titleOut, t.lowercased() == bundleId.lowercased() { titleOut = nil }
    return OutdatedPkg(
        name: bundleId,
        manager: "app-store",
        currentVersion: current,
        latestVersion: latestVal,
        title: titleOut,
        summary: shortDesc(row["description"] as? String)
    )
}

func itunesRequest(_ params: [String: String]) -> [String: [String: Any]] {
    var items: [URLQueryItem] = []
    for (k, v) in params { items.append(URLQueryItem(name: k, value: v)) }
    var comp = URLComponents(string: "https://itunes.apple.com/lookup")
    comp?.queryItems = items
    guard let url = comp?.url else { return [:] }
    var req = URLRequest(url: url, timeoutInterval: 12)
    req.setValue("AppAttic/1.0", forHTTPHeaderField: "User-Agent")
    let box = LockBox<[String: [String: Any]]>([:])
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        box.value = indexItunesResults(obj)
    }.resume()
    _ = sem.wait(timeout: .now() + 15)
    return box.value
}

private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    init(_ value: T) { _value = value }
}

public func itunesLookup(_ bundleId: String) -> [String: Any]? {
    if bundleId.isEmpty { return nil }
    for country in storeCountries() {
        let idx = itunesRequest(["bundleId": bundleId, "country": country])
        if let row = idx[bundleId] { return row }
    }
    return nil
}

public func itunesLookupBatch(_ adamIds: [String]) -> [String: [String: Any]] {
    let ids = adamIds.filter { !$0.isEmpty }
    if ids.isEmpty { return [:] }
    var out: [String: [String: Any]] = [:]
    for country in storeCountries() {
        let missing = ids.filter { out[$0] == nil }
        if missing.isEmpty { break }
        var i = 0
        while i < missing.count {
            let chunk = Array(missing[i..<min(i + 20, missing.count)])
            let idx = itunesRequest(["id": chunk.joined(separator: ","), "country": country])
            for (k, v) in idx { out[k] = v }
            i += 20
        }
    }
    return out
}

public func masSpotlightMeta(_ path: String, run: CommandRun = runCommand) -> (String?, String?) {
    let (rc, out, _) = run(["mdls", "-name", "kMDItemAppStoreAdamID", "-name", "kMDItemAppStoreCategory", path], 8)
    if rc != 0 { return (nil, nil) }
    return parseMdlsMas(out)
}

public func collectAppstore(
    _ apps: [AppRecord],
    progress: ((String) -> Void)? = nil,
    lookup: ((String) -> [String: Any]?)? = nil,
    catalog: [String: [String: Any]]? = nil
) -> [OutdatedPkg] {
    let masApps = apps.filter { app in
        app.bundleId != nil && (app.extra["mas_receipt"] == "1" || app.extra["mas_receipt"] == "true")
    }
    if masApps.isEmpty { return [] }
    progress?("  · checking App Store updates…")
    if let lookup {
        return masApps.compactMap { app in
            guard let bid = app.bundleId, let row = lookup(bid) else { return nil }
            return pkgFromItunes(displayName: app.displayName, bundleId: bid, current: app.extra["version"], row: row)
        }
    }
    var cat = catalog
    if cat == nil {
        cat = masCatalog(masApps)
    }
    let resolved = cat ?? [:]
    var out: [OutdatedPkg] = []
    for app in masApps {
        guard let bid = app.bundleId else { continue }
        let adam = app.extra["mas_adam_id"] ?? ""
        let row = (adam.isEmpty ? nil : resolved[adam]) ?? resolved[bid]
        if let pkg = pkgFromItunes(displayName: app.displayName, bundleId: bid, current: app.extra["version"], row: row) {
            out.append(pkg)
        }
    }
    return out
}

func masCatalog(_ apps: [AppRecord]) -> [String: [String: Any]] {
    var ids: [String] = []
    var mutated = apps
    for i in mutated.indices {
        var extra = mutated[i].extra
        var adam = extra["mas_adam_id"]
        if adam == nil {
            let (found, category) = masSpotlightMeta(mutated[i].path)
            if let found { extra["mas_adam_id"] = found; adam = found }
            if let category { extra["mas_category"] = category }
            mutated[i].extra = extra
        }
        if let adam { ids.append(adam) }
    }
    var catalog = itunesLookupBatch(ids)
    for app in mutated {
        let extra = app.extra
        let adam = extra["mas_adam_id"] ?? ""
        let bid = app.bundleId
        if (!adam.isEmpty && catalog[adam] != nil) || (bid != nil && catalog[bid!] != nil) {
            continue
        }
        guard let bid else { continue }
        guard let row = itunesLookup(bid) else { continue }
        catalog[bid] = row
        if let tid = row["trackId"] {
            catalog["\(tid)"] = row
        }
    }
    return catalog
}

public func attachItunesMeta(_ pkgs: [OutdatedPkg], catalog: [String: [String: Any]]? = nil) {
    let ids = pkgs.filter { $0.manager == "app-store" && $0.name.allSatisfy(\.isNumber) }.map(\.name)
    let cat = catalog ?? itunesLookupBatch(ids)
    for p in pkgs where p.manager == "app-store" {
        guard let row = cat[p.name] else { continue }
        if let bid = row["bundleId"] as? String, p.name.allSatisfy(\.isNumber) {
            p.name = bid
        }
        if p.summary == nil {
            p.summary = shortDesc(row["description"] as? String)
        }
        if p.title == nil {
            let title = (row["trackName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !title.isEmpty, title.lowercased() != p.name.lowercased() {
                p.title = title
            }
        }
    }
}

public func queryMas(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("mas") else { return [] }
    progress?("  · checking App Store updates…")
    let (rc, out, _) = run([path, "outdated"], 90)
    if rc != 0 { return [] }
    return parseMasOutdated(out)
}

public func queryAppstore(
    _ apps: [AppRecord],
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    if PlatformOverride.isLinux { return [] }
    if let path = which("mas") {
        progress?("  · checking App Store updates…")
        let (rc, out, _) = run([path, "outdated"], 90)
        if rc == 0 {
            let pkgs = parseMasOutdated(out)
            attachItunesMeta(pkgs)
            return pkgs
        }
    }
    return collectAppstore(apps, progress: progress)
}

private func flatpakColumns(path: String, kind: String, withMeta: Bool) -> [String] {
    let cols = withMeta ? "application,version,name,description" : "application,version"
    if kind == "updates" {
        return [path, "remote-ls", "--updates", "--app", "--columns=\(cols)"]
    }
    return [path, "list", "--app", "--columns=\(cols)"]
}

public func queryFlatpak(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("flatpak") else { return [] }
    progress?("  · checking Flatpak updates…")
    var (rc, updates, _) = run(flatpakColumns(path: path, kind: "updates", withMeta: true), 60)
    let withMeta = rc == 0
    if !withMeta {
        (rc, updates, _) = run(flatpakColumns(path: path, kind: "updates", withMeta: false), 60)
        if rc != 0 { return [] }
    }
    let (rc2, installed, _) = run(flatpakColumns(path: path, kind: "list", withMeta: withMeta), 60)
    return parseFlatpakUpdates(updates, installedText: rc2 == 0 ? installed : "")
}

public func querySnap(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("snap") else { return [] }
    progress?("  · checking Snap updates…")
    let (rc, refresh, _) = run([path, "refresh", "--list"], 60)
    if rc != 0 { return [] }
    let (rc2, listed, _) = run([path, "list"], 60)
    return parseSnapRefreshList(refresh, installedText: rc2 == 0 ? listed : "")
}

public func queryApt(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("apt") else { return [] }
    progress?("  · checking apt upgradable packages…")
    let (rc, out, _) = run([path, "list", "--upgradable"], 60)
    if rc != 0 { return [] }
    return parseAptUpgradable(out)
}

public func queryPacman(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("pacman") else { return [] }
    progress?("  · checking pacman updates…")
    let (rc, out, _) = run([path, "-Qu"], 60)
    if rc != 0 && rc != 1 { return [] }
    return parsePacmanQu(out)
}

public func queryDnf(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("dnf5") ?? which("dnf") ?? which("yum") else { return [] }
    progress?("  · checking dnf updates…")
    let name = URL(fileURLWithPath: path).lastPathComponent
    func parsed(_ rc: Int32, _ out: String) -> [OutdatedPkg]? {
        if rc == 0 || rc == 100 { return parseDnfUpgrades(out) }
        return nil
    }
    if name != "yum" {
        let (rc, out, _) = run([path, "list", "--upgrades"], 60)
        if let pkgs = parsed(rc, out) { return pkgs }
    }
    let (rc, out, _) = run([path, "check-update"], 60)
    return parsed(rc, out) ?? []
}

public func queryZypper(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("zypper") else { return [] }
    progress?("  · checking zypper updates…")
    let (rc, out, _) = run([path, "--non-interactive", "list-updates"], 60)
    if rc != 0 { return [] }
    return parseZypperListUpdates(out)
}

public func collectLinux(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand,
    osRelease: String? = nil
) -> [OutdatedPkg] {
    var pkgs: [OutdatedPkg] = []
    pkgs.append(contentsOf: queryFlatpak(progress: progress, which: which, run: run))
    pkgs.append(contentsOf: querySnap(progress: progress, which: which, run: run))
    let family = linuxDistroFamily(osRelease: osRelease ?? linuxOsReleaseText())
    switch family {
    case "arch":
        pkgs.append(contentsOf: queryPacman(progress: progress, which: which, run: run))
    case "fedora":
        pkgs.append(contentsOf: queryDnf(progress: progress, which: which, run: run))
    case "suse":
        pkgs.append(contentsOf: queryZypper(progress: progress, which: which, run: run))
    case "debian":
        pkgs.append(contentsOf: queryApt(progress: progress, which: which, run: run))
    default:
        if which("pacman") != nil {
            pkgs.append(contentsOf: queryPacman(progress: progress, which: which, run: run))
        } else if which("dnf5") != nil || which("dnf") != nil || which("yum") != nil {
            pkgs.append(contentsOf: queryDnf(progress: progress, which: which, run: run))
        } else if which("zypper") != nil {
            pkgs.append(contentsOf: queryZypper(progress: progress, which: which, run: run))
        } else {
            pkgs.append(contentsOf: queryApt(progress: progress, which: which, run: run))
        }
    }
    return pkgs
}

func softwareKeys(_ sw: Software) -> Set<String> {
    var keys: Set<String> = [sw.name.lowercased()]
    if let v = sw.caskName, !v.isEmpty { keys.insert(v.lowercased()) }
    if let v = sw.bundleId, !v.isEmpty { keys.insert(v.lowercased()) }
    if let v = sw.pkgId, !v.isEmpty { keys.insert(v.lowercased()) }
    for b in sw.bins { keys.insert(b.lowercased()) }
    if let desktopId = sw.extra["desktop_id"], !desktopId.isEmpty {
        keys.insert(desktopId.lowercased())
    }
    return keys
}

public func applyOutdated(_ software: [Software], pkgs: [OutdatedPkg]) {
    var index: [String: [Software]] = [:]
    for sw in software {
        for key in softwareKeys(sw) {
            index[key, default: []].append(sw)
        }
    }
    for pkg in pkgs {
        var keys: Set<String> = [pkg.name.lowercased()]
        if let title = pkg.title, !title.isEmpty { keys.insert(title.lowercased()) }
        for key in keys {
            for sw in index[key] ?? [] {
                sw.outdated = true
                sw.latestVersion = pkg.latestVersion
                if let cur = pkg.currentVersion, sw.version == nil {
                    sw.version = cur
                }
                if let summary = pkg.summary, sw.summary == nil {
                    sw.summary = summary
                }
            }
        }
    }
}

public func attachSummariesFromSoftware(_ software: [Software], pkgs: [OutdatedPkg]) {
    var index: [String: String] = [:]
    for sw in software {
        guard let text = sw.summary, !text.isEmpty else { continue }
        for key in softwareKeys(sw) {
            if index[key] == nil { index[key] = text }
        }
    }
    for pkg in pkgs {
        if pkg.summary != nil { continue }
        var hit = index[pkg.name.lowercased()]
        if hit == nil, let title = pkg.title {
            hit = index[title.lowercased()]
        }
        if let hit { pkg.summary = hit }
    }
}
