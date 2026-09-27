import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Package checks that could not run in the scan now in flight, by manager or
/// tool name: the update queries below and the orphan/global listings in
/// `Packages.swift` both report here. A check that failed is not the answer
/// "nothing to report", it is an unknown, and the two collapse into the same
/// empty list. The scan cache keeps a scan for `scanCacheMaxAge`, so an unknown
/// written to it is served as a verified "up to date" for a day. `performScan`
/// reads the set and marks the scan incomplete, which is the flag
/// `commitScanCache` already refuses to keep and `isScanCacheStale` already
/// refuses to serve. Reset per scan, so a long lived process (the UI) cannot
/// carry one scan's failure into the next.
private let failedCheckLock = NSLock()
nonisolated(unsafe) private var failedChecks: Set<String> = []

func noteScanCheckFailed(_ source: String) {
    failedCheckLock.lock()
    failedChecks.insert(source)
    failedCheckLock.unlock()
}

func scanCheckFailures() -> [String] {
    failedCheckLock.lock()
    defer { failedCheckLock.unlock() }
    return failedChecks.sorted()
}

func resetScanCheckFailures() {
    failedCheckLock.lock()
    failedChecks.removeAll()
    failedCheckLock.unlock()
}

// Per-line hot loops below use manual index walks instead of NSRegularExpression
// plus `trimmingCharacters` (which alone costs ~2.2 µs/line). The byte walks
// themselves allocate nothing; rows still build a result String.
// Compiled once. NSRegularExpression is immutable and safe to share across threads.
private let localeRegionRE = try! NSRegularExpression(pattern: #"rg=([a-z]{2})"#, options: [.caseInsensitive])
private let localeCountryRE = try! NSRegularExpression(pattern: #"_([A-Z]{2})"#)

// Per-line hot loops below scan UTF-8 bytes directly. `Character.isWhitespace`
// on String indices costs ~2 µs/line (grapheme/Unicode overhead); byte compares
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

    public var updatable: Bool { outdatedIsUpdatable(manager: manager, kind: kind) }

    /// The manager behind `updatable`, or nil for report-only managers and untrusted casks.
    public var upgradableManager: UpgradableManager? {
        kind == "untrusted" ? nil : UpgradableManager(rawValue: manager)
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
            kind: kind ?? defaultOutdatedKind(manager),
            bundle_id: bundleId
        )
    }
}

public func outdatedReportFooter(_ pkgs: [OutdatedPkg]) -> [String] {
    var lines: [String] = []
    if pkgs.contains(where: \.updatable) {
        lines.append("Named upgrades (Homebrew, Flatpak, apt, pacman, AUR, dnf, yum, zypper): appattic update --dry-run, then appattic update. Not a full distro upgrade.")
    }
    if pkgs.contains(where: { $0.kind == "untrusted" }) {
        lines.append("Untrusted casks stay listed. AppAttic will not trust the tap.")
    }
    if pkgs.contains(where: {
        ["app-store", "snap"].contains($0.manager)
    }) {
        lines.append("App Store and Snap stay report-only.")
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
    "aur": "AUR",
    "dnf": "dnf",
    "yum": "yum",
    "zypper": "zypper",
]

/// Same guard as `packageLabel` in Packages.swift: a manager carrying no `-`
/// skips the Foundation replace instead of copying the string to find nothing.
private func outdatedManagerLabel(_ manager: String) -> String {
    if let known = managerLabel[manager] { return known }
    return manager.contains("-") ? manager.replacingOccurrences(of: "-", with: " ") : manager
}

public let outdatedSkippedManagersNote =
    "Untrusted casks, App Store, and Snap are skipped."

public func outdatedReason(_ pkg: OutdatedPkg, page: String = "Outdated") -> String {
    outdatedReason(
        manager: pkg.manager,
        reason: pkg.reason,
        currentVersion: pkg.currentVersion,
        latestVersion: pkg.latestVersion,
        updatable: pkg.updatable,
        page: page
    )
}

/// Same reason for a JSON `OutdatedEntry` row, for a surface that never holds
/// the runtime `OutdatedPkg` it was serialized from.
public func outdatedReason(_ entry: OutdatedEntry, page: String = "Outdated") -> String {
    outdatedReason(
        manager: entry.manager,
        reason: entry.reason,
        currentVersion: entry.current_version,
        latestVersion: entry.latest_version,
        updatable: entry.updatable,
        page: page
    )
}

private func outdatedReason(
    manager: String,
    reason: String?,
    currentVersion: String?,
    latestVersion: String?,
    updatable: Bool,
    page: String
) -> String {
    if let reason, !reason.isEmpty { return reason }
    let mgr = outdatedManagerLabel(manager)
    let cur = currentVersion ?? "the installed version"
    let latest = latestVersion ?? "a newer version"
    if updatable {
        return "\(mgr) reports \(cur) installed and \(latest) available. You can update it from \(page)."
    }
    return "\(mgr) reports \(cur) installed and \(latest) available. AppAttic does not run this upgrade."
}

/// Marks refused casks as untrusted and adds the ones absent from `pkgs`.
/// `OutdatedPkg` is a class, so the marking mutates the caller's elements in
/// place; only newly added rows are exclusive to the returned array.
public func applyUntrustedCasks(_ pkgs: [OutdatedPkg], refused: [UntrustedCask]) -> [OutdatedPkg] {
    var out = pkgs
    for u in refused {
        let key = u.name.posixLowercased()
        if let existing = out.first(where: { $0.manager == "brew-cask" && $0.name.posixLowercased() == key }) {
            existing.kind = "untrusted"
            existing.reason = untrustedCaskReason(u)
            if existing.summary?.isEmpty ?? true {
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

func aurHelperBin(_ which: WhichFn = whichCommand) -> String {
    for name in ["paru", "yay", "pikaur"] {
        if which(name) != nil { return name }
    }
    return "paru"
}

public func updateCommand(_ pkg: OutdatedPkg) -> String? {
    guard let manager = pkg.upgradableManager else { return nil }
    let quoted = shellQuote(pkg.name)
    switch manager {
    case .brewFormula:
        return "brew upgrade \(quoted)"
    case .brewCask:
        return "brew upgrade --cask \(quoted)"
    case .flatpak:
        return "flatpak update -y \(quoted)"
    case .apt:
        return "apt-get -y install --only-upgrade \(quoted)"
    case .pacman:
        return "pacman --noconfirm -S \(quoted)"
    case .aur:
        return "\(aurHelperBin()) --noconfirm -S \(quoted)"
    case .dnf:
        return "dnf upgrade -y \(quoted)"
    case .yum:
        return "yum upgrade -y \(quoted)"
    case .zypper:
        return "zypper --non-interactive update \(quoted)"
    }
}

/// Named upgrade script. CLI `update` with no `--dry-run` runs this; the UI confirms first.
public func updateScript(_ pkgs: [OutdatedPkg]) -> String {
    let cmds = pkgs.compactMap(updateCommand)
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic package update",
        "# Review every line before running. `appattic update` (no --dry-run) runs this script.",
        "",
    ]
    if cmds.isEmpty {
        lines.append("# Nothing to update. \(outdatedSkippedManagersNote)")
        return lines.joined(separator: "\n") + "\n"
    }
    let wrapped = cmds.map(withRootCmd)
    if wrapped.contains(where: callsRootHelper) {
        lines.append(scriptRootHelper)
    }
    lines.append("# Named package upgrades. Not a full distro upgrade.")
    lines.append(contentsOf: wrapped)
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
    outdatedSummaryFallback(summary: pkg.summary, manager: pkg.manager)
}

/// Same fallback for a JSON `OutdatedEntry` row.
public func outdatedSummaryFallback(_ entry: OutdatedEntry) -> String {
    outdatedSummaryFallback(summary: entry.summary, manager: entry.manager)
}

private func outdatedSummaryFallback(summary: String?, manager: String) -> String {
    if let summary, !summary.isEmpty { return summary }
    let mgr = outdatedManagerLabel(manager)
    return "Package managed by \(mgr)"
}

private func flatpakRows(_ text: String) -> [String: (String?, String?, String?)] {
    var mapping: [String: (String?, String?, String?)] = [:]
    // Byte scan: the old `split().map(String.init)` + per-field
    // `trimmingCharacters` cost ~8.6 µs/line.
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let row = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring?, Substring?, Substring?)? in
            let (ls, le) = trimRange(u)
            guard ls < le else { return nil }
            var bounds: [(Int, Int)] = []
            bounds.reserveCapacity(4)
            // Tab path: split on \t, drop empties. WS path: first 3 tokens,
            // remainder is the 4th field.
            var hasTab = false
            for k in ls..<le where u[k] == 0x09 { hasTab = true; break }
            if hasTab {
                var f = ls
                while f <= le {
                    var g = f
                    while g < le, u[g] != 0x09 { g += 1 }
                    // Keep whitespace-only fields as positional placeholders
                    // (the old `filter { !$0.isEmpty }` kept `" "`); trim on
                    // materialize below.
                    if f < g { bounds.append((f, g)) }
                    f = g + 1
                }
            } else {
                var i = ls
                for _ in 0..<3 {
                    guard let tb = tokBounds(u, le, &i), tb.0 < tb.1 else { break }
                    bounds.append(tb)
                }
                if bounds.count == 3 {
                    let (rs, re) = trimBounds(u, le, ls: i)
                    if rs < re { bounds.append((rs, re)) }
                }
            }
            guard !bounds.isEmpty else { return nil }
            // Trim on materialize: whitespace-only placeholders become "".
            func sub(_ b: (Int, Int)) -> Substring {
                let (ts, te) = trimBounds(u, b.1, ls: b.0)
                return tokSub(raw, u, (ts, te))
            }
            let key = sub(bounds[0])
            guard !key.isEmpty else { return nil }
            // Extra fields fold into the summary: the old code joined the
            // (empty-dropped, untrimmed) parts[3...] with "\t", then trimmed.
            // Non-nil whenever a 4th field exists, even if it trims to "".
            // Fast path: exactly 4 fields need no join.
            var tail: Substring? = nil
            if bounds.count == 4 {
                tail = sub(bounds[3])
            } else if bounds.count > 4 {
                var acc = ""
                acc.reserveCapacity(64)
                for b in bounds[3...] {
                    acc += String(sub(b))
                    acc += "\t"
                }
                if acc.hasSuffix("\t") { acc.removeLast() }
                tail = Substring(acc.trimmingCharacters(in: .whitespaces))
            }
            return (key,
                    bounds.count > 1 ? sub(bounds[1]) : nil,
                    bounds.count > 2 ? sub(bounds[2]) : nil,
                    tail)
        }) ?? nil else { continue }
        let key = String(row.0)
        let low = key.posixLowercased()
        if low == "application" || low == "application id" || low == "name" || low == "id" { continue }
        let version = row.1.map(String.init)
        var title = row.2.map(String.init)
        let summary = row.3.map(String.init)
        if let t = title, t.posixLowercased() == low { title = nil }
        mapping[key] = (version, title, summary)
    }
    return mapping
}

public func parseFlatpakUpdates(_ updatesText: String, installedText: String = "") -> [OutdatedPkg] {
    let latest = flatpakRows(updatesText)
    let current = flatpakRows(installedText)
    var out: [OutdatedPkg] = []
    // `latest` is a dictionary, and Swift seeds hashing per process: walking it
    // unsorted gives the outdated list a different order on every run.
    for (name, triple) in latest.sorted(by: { $0.key < $1.key }) {
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

/// First two tokens of a trimmed line, or nil when fewer.
private func snapTokens(_ raw: Substring) -> (Substring, Substring)? {
    raw.utf8.withContiguousStorageIfAvailable { u -> (Substring, Substring)? in
        let (ls, le) = trimRange(u)
        guard ls < le else { return nil }
        var i = ls
        guard let a = tokBounds(u, le, &i), a.0 < a.1,
              let b = tokBounds(u, le, &i), b.0 < b.1
        else { return nil }
        return (tokSub(raw, u, a), tokSub(raw, u, b))
    } ?? nil
}

private func snapNameVersionMap(_ text: String) -> [String: String] {
    var mapping: [String: String] = [:]
    let raws = text.split(separator: "\n", omittingEmptySubsequences: false)
    // `All snaps up to date.` — case-insensitive prefix of the first non-empty
    // line, matching the old check exactly. A `Name …` header on that same
    // line is skipped by index, so single-token leaders can't shift it.
    var headIdx: Int? = nil
    for (idx, raw) in raws.enumerated() {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t.posixLowercased().hasPrefix("all snaps up to date") { return mapping }
        headIdx = t.split(whereSeparator: \.isWhitespace).first?.posixLowercased() == "name" ? idx : nil
        break
    }
    for (idx, raw) in raws.enumerated() {
        if idx == headIdx { continue }
        guard let pair = snapTokens(raw) else { continue }
        mapping[String(pair.0)] = String(pair.1)
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

/// `apt list --upgradable` line: `name/dist latest arch [upgradable from: cur]`.
func parseAptUpgradableLine(_ s: Substring) -> (name: String, current: String, latest: String)? {
    s.utf8.withContiguousStorageIfAvailable { u -> (String, String, String)? in
        let (ls, le) = trimRange(u)
        guard ls < le else { return nil }
        var i = ls
        while i < le, u[i] != 0x2F /* / */, !bWS(u[i]) { i += 1 }
        guard i < le, u[i] == 0x2F else { return nil }
        let nameB = (ls, i)
        i += 1
        guard let distB = tokBounds(u, le, &i), distB.0 < distB.1,
              let latestB = tokBounds(u, le, &i), latestB.0 < latestB.1,
              let archB = tokBounds(u, le, &i), archB.0 < archB.1
        else { return nil }
        _ = distB
        _ = archB
        while i < le, bWS(u[i]) { i += 1 }
        guard i < le, u[i] == 0x5B /* [ */ else { return nil }
        i += 1
        var close = i
        while close < le, u[close] != 0x5D /* ] */ { close += 1 }
        guard close < le else { return nil }
        var bs = i
        var be = close
        while bs < be, bWS(u[bs]) { bs += 1 }
        while be > bs, bWS(u[be - 1]) { be -= 1 }
        // `upgradable from:` marker, case-insensitive.
        let marker: [UInt8] = [0x75, 0x70, 0x67, 0x72, 0x61, 0x64, 0x61, 0x62, 0x6C, 0x65, 0x20, 0x66, 0x72, 0x6F, 0x6D, 0x3A]
        guard be - bs > marker.count else { return nil }
        for k in 0..<marker.count {
            var c = u[bs + k]
            if c >= 0x41, c <= 0x5A { c &+= 32 }
            guard c == marker[k] else { return nil }
        }
        var cs = bs + marker.count
        var ce = be
        while cs < ce, bWS(u[cs]) { cs += 1 }
        while ce > cs, bWS(u[ce - 1]) { ce -= 1 }
        guard cs < ce else { return nil }
        var k = cs
        while k < ce, !bWS(u[k]) { k += 1 }
        guard k == ce else { return nil }
        return (String(tokSub(s, u, nameB)), String(tokSub(s, u, (cs, ce))), String(tokSub(s, u, latestB)))
    } ?? nil
}

public func parseAptUpgradable(_ text: String) -> [OutdatedPkg] {
    var out: [OutdatedPkg] = []
    out.reserveCapacity(1024)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let (name, cur, latest) = parseAptUpgradableLine(raw) else { continue }
        out.append(OutdatedPkg(name: name, manager: "apt", currentVersion: cur, latestVersion: latest))
    }
    return out
}

/// `pacman -Qu` / `paru -Qua` line: `name cur -> latest [ignored?]`.
func parsePacmanQuLine(_ s: Substring) -> (name: String, current: String, latest: String)? {
    s.utf8.withContiguousStorageIfAvailable { u -> (String, String, String)? in
        let (ls, le) = trimRange(u)
        guard ls < le else { return nil }
        var i = ls
        guard let nameB = tokBounds(u, le, &i),
              let curB = tokBounds(u, le, &i),
              let arrowB = tokBounds(u, le, &i), arrowB.1 - arrowB.0 == 2,
              u[arrowB.0] == 0x2D, u[arrowB.0 + 1] == 0x3E,
              let latestB = tokBounds(u, le, &i), latestB.0 < latestB.1
        else { return nil }
        while i < le, bWS(u[i]) { i += 1 }
        if i < le {
            // Trailing `[ignored]` marker only.
            guard u[i] == 0x5B /* [ */, u[le - 1] == 0x5D /* ] */ else { return nil }
            var rs = i + 1
            var re = le - 1
            while rs < re, bWS(u[rs]) { rs += 1 }
            while re > rs, bWS(u[re - 1]) { re -= 1 }
            guard rs < re else { return nil }
            var k = rs
            while k < re, !bWS(u[k]) { k += 1 }
            guard k == re else { return nil }
        }
        return (String(tokSub(s, u, nameB)), String(tokSub(s, u, curB)), String(tokSub(s, u, latestB)))
    } ?? nil
}

public func parsePacmanQu(_ text: String) -> [OutdatedPkg] {
    var out: [OutdatedPkg] = []
    out.reserveCapacity(1024)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let (name, cur, latest) = parsePacmanQuLine(raw) else { continue }
        out.append(OutdatedPkg(
            name: name,
            manager: "pacman",
            currentVersion: cur,
            latestVersion: latest
        ))
    }
    return out
}

/// `dnf list --upgrades` row: `name[.arch] version repo`. The version token must
/// carry a digit; the repo token is required (name-only noise lines drop out).
func parseDnfUpgradesLine(_ s: Substring) -> (name: String, latest: String)? {
    s.utf8.withContiguousStorageIfAvailable { u -> (String, String)? in
        let (ls, le) = trimRange(u)
        guard ls < le else { return nil }
        var i = ls
        guard let nameB = tokBounds(u, le, &i),
              let verB = tokBounds(u, le, &i),
              let repoB = tokBounds(u, le, &i), repoB.0 < repoB.1
        else { return nil }
        var (ns, ne) = nameB
        // Strip a known `.arch` suffix.
        var dot = -1
        var k = ne - 1
        while k >= ns {
            if u[k] == 0x2E /* . */ { dot = k; break }
            k -= 1
        }
        if dot > ns {
            let slen = ne - dot - 1
            let archs: [[UInt8]] = [
                [0x78, 0x38, 0x36, 0x5F, 0x36, 0x34], // x86_64
                [0x61, 0x61, 0x72, 0x63, 0x68, 0x36, 0x34], // aarch64
                [0x69, 0x36, 0x38, 0x36], // i686
                [0x6E, 0x6F, 0x61, 0x72, 0x63, 0x68], // noarch
                [0x70, 0x70, 0x63, 0x36, 0x34, 0x6C, 0x65], // ppc64le
                [0x73, 0x33, 0x39, 0x30, 0x78], // s390x
            ]
            for a in archs where a.count == slen {
                var match = true
                for j in 0..<slen where u[dot + 1 + j] != a[j] { match = false; break }
                if match { ne = dot; break }
            }
        }
        guard ns < ne else { return nil }
        // Name charset `[A-Za-z0-9_+.-]`, version carries a digit.
        var hasDigit = false
        for j in ns..<ne {
            let c = u[j]
            guard bAlphaNum(c) || c == 0x5F || c == 0x2B || c == 0x2E || c == 0x2D else { return nil }
        }
        for j in verB.0..<verB.1 where bDigit(u[j]) { hasDigit = true; break }
        guard hasDigit else { return nil }
        return (String(tokSub(s, u, (ns, ne))), String(tokSub(s, u, verB)))
    } ?? nil
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

public func parseDnfUpgrades(_ text: String, manager: String = "dnf") -> [OutdatedPkg] {
    var out: [OutdatedPkg] = []
    out.reserveCapacity(1024)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if isDnfListingNoise(raw) { continue }
        guard let (name, latest) = parseDnfUpgradesLine(raw) else { continue }
        out.append(OutdatedPkg(
            name: name,
            manager: manager,
            latestVersion: latest
        ))
    }
    return out
}

public func parseZypperListUpdates(_ text: String) -> [OutdatedPkg] {
    var out: [OutdatedPkg] = []
    out.reserveCapacity(256)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let cols = pipeColumns(raw), cols.count >= 5 else { continue }
        guard let row = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring, Substring?)? in
            // Status `S` rows and the header row drop out.
            let (ss, se) = cols[0]
            if se - ss == 1 {
                var c = u[ss]
                if c >= 0x41, c <= 0x5A { c &+= 32 }
                if c == 0x73 /* s */ { return nil }
            }
            let name = tokSub(raw, u, cols[2])
            guard !name.isEmpty, name.caseInsensitiveCompare("Name") != .orderedSame else { return nil }
            let cur = tokSub(raw, u, cols[3])
            let avail = tokSub(raw, u, cols[4])
            return (name, avail, cur.isEmpty ? nil : cur)
        }) ?? nil else { continue }
        out.append(OutdatedPkg(
            name: String(row.0),
            manager: "zypper",
            currentVersion: row.2.map(String.init),
            latestVersion: String(row.1)
        ))
    }
    return out
}

/// `mas outdated` line: `id name (cur -> latest)`. The id is digits, the name
/// is the head remainder, the parenthesised tail is exactly `a -> b`.
func parseMasOutdatedLine(_ s: Substring) -> (id: String, name: String, current: String, latest: String)? {
    s.utf8.withContiguousStorageIfAvailable { u -> (String, String, String, String)? in
        let (ls, le) = trimRange(u)
        guard ls < le, u[le - 1] == 0x29 /* ) */ else { return nil }
        var open = le - 1
        while open > ls, u[open] != 0x28 /* ( */ { open -= 1 }
        guard open > ls else { return nil }
        let (hs, he) = trimBounds(u, open, ls: ls)
        let (ts, te) = trimBounds(u, le - 1, ls: open + 1)
        // `->` split inside the tail.
        var arrow = -1
        var k = ts
        while k + 1 < te {
            if u[k] == 0x2D, u[k + 1] == 0x3E { arrow = k; break }
            k += 1
        }
        guard arrow > ts else { return nil }
        let (cs, ce) = trimBounds(u, arrow, ls: ts)
        let (vs, ve) = trimBounds(u, te, ls: arrow + 2)
        guard cs < ce, vs < ve else { return nil }
        for j in cs..<ce where u[j] == 0x28 || u[j] == 0x29 { return nil }
        for j in vs..<ve where u[j] == 0x28 || u[j] == 0x29 { return nil }
        // Head: digits id, then the name.
        var p = hs
        while p < he, bDigit(u[p]) { p += 1 }
        let idE = p
        guard idE > hs, p < he, bWS(u[p]) else { return nil }
        while p < he, bWS(u[p]) { p += 1 }
        guard p < he else { return nil }
        return (
            String(tokSub(s, u, (hs, idE))),
            String(tokSub(s, u, (p, he))),
            String(tokSub(s, u, (cs, ce))),
            String(tokSub(s, u, (vs, ve)))
        )
    } ?? nil
}

public func parseMasOutdated(_ text: String) -> [OutdatedPkg] {
    var out: [OutdatedPkg] = []
    out.reserveCapacity(1024)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let (id, name, cur, latest) = parseMasOutdatedLine(raw) else { continue }
        out.append(OutdatedPkg(
            name: id,
            manager: "app-store",
            currentVersion: cur,
            latestVersion: latest,
            title: name
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
    let ns = src as NSString
    let full = NSRange(location: 0, length: ns.length)
    if let m = localeRegionRE.firstMatch(in: src, range: full), m.numberOfRanges >= 2 {
        countries.append(ns.substring(with: m.range(at: 1)).posixLowercased())
    }
    if let m = localeCountryRE.firstMatch(in: src, range: full), m.numberOfRanges >= 2 {
        let code = ns.substring(with: m.range(at: 1)).posixLowercased()
        if !countries.contains(code) { countries.append(code) }
    }
    if !countries.contains("us") { countries.append("us") }
    return countries
}

/// `cur * 10 + digit` that saturates instead of trapping.
///
/// A version comes from a package index or the App Store, so a digit run is
/// only as long as whoever published it made it. The same bound `hxDigitsValue`
/// needs for shell history applies here: past 18 digits `cur * 10` overflows
/// and the trap takes the whole scan down with it. Saturating keeps the
/// comparison ordered, and two components too wide to tell apart compare by
/// the components after them.
@inline(__always)
private func appendVersionDigit(_ cur: Int, _ digit: Int) -> Int {
    let (scaled, scaleOverflow) = cur.multipliedReportingOverflow(by: 10)
    if scaleOverflow { return Int.max }
    let (sum, sumOverflow) = scaled.addingReportingOverflow(digit)
    return sumOverflow ? Int.max : sum
}

public func versionNewer(latest: String?, current: String?) -> Bool {
    func parts(_ v: String?) -> [Int] {
        var nums: [Int] = []
        let src = v ?? ""
        var cur = 0
        var inDigits = false
        for ch in src {
            // ASCII 0-9 only. `Character.isNumber` is also true for numeric
            // punctuation such as ½, which has no wholeNumberValue.
            if ch.isNumber, ch.isASCII, let digit = ch.wholeNumberValue {
                cur = appendVersionDigit(cur, digit)
                inDigits = true
            } else if inDigits {
                nums.append(cur)
                cur = 0
                inDigits = false
            }
        }
        if inDigits { nums.append(cur) }
        // Keep one component: a version of "0" or "0.0.0" is still a version,
        // and emptying the list sent it down the string-compare path below,
        // which called "0" newer than "1".
        while nums.count > 1, nums.last == 0 { nums.removeLast() }
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
    // First paragraph without bridging to NSString (`components(separatedBy:)`
    // decodes the whole string as UTF-16 per call).
    let para: Substring
    if let r = raw.range(of: "\n\n") {
        para = raw[..<r.lowerBound]
    } else {
        para = raw[...]
    }
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
    guard versionNewer(latest: latestVal, current: current) else { return nil }
    let title = (displayName ?? (row["trackName"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    var titleOut: String? = title.isEmpty ? nil : title
    if let t = titleOut, t.posixLowercased() == bundleId.posixLowercased() { titleOut = nil }
    return OutdatedPkg(
        name: bundleId,
        manager: "app-store",
        currentVersion: current,
        latestVersion: latestVal,
        title: titleOut,
        summary: shortDesc(row["description"] as? String)
    )
}

/// What one lookup returned: the rows it indexed, and why it returned none when
/// the request itself failed. An empty answer and a failed request are the same
/// list of rows, and only the second one is worth telling the operator about: a
/// failed lookup leaves every App Store app looking up to date.
struct ItunesLookup {
    var rows: [String: [String: Any]]
    var failure: String?
    /// Set once the task's completion handler has run, so a wait that times out
    /// can tell "still in flight" from "answered with nothing".
    var answered = false
}

/// The lookup endpoint, the per-request timeout, and the longer wait around
/// the task: the request timeout bounds the transfer, the outer wait bounds a
/// task that never calls back.
let itunesLookupURL = "https://itunes.apple.com/lookup"
let itunesRequestTimeout: TimeInterval = 12
let itunesLookupTimeout: TimeInterval = 15

func itunesRequest(
    _ params: [String: String],
    session: URLSession = .shared,
    onFailure: ((String) -> Void)? = nil
) -> [String: [String: Any]] {
    var items: [URLQueryItem] = []
    for (k, v) in params.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
    var comp = URLComponents(string: itunesLookupURL)
    comp?.queryItems = items
    guard let url = comp?.url else {
        onFailure?("the lookup URL could not be built")
        return [:]
    }
    var req = URLRequest(url: url, timeoutInterval: itunesRequestTimeout)
    req.setValue("AppAttic/1.0", forHTTPHeaderField: "User-Agent")
    let box = LockBox<ItunesLookup>(ItunesLookup(rows: [:], failure: nil))
    let sem = DispatchSemaphore(value: 0)
    session.dataTask(with: req) { data, response, error in
        defer {
            box.mutate { $0.answered = true }
            sem.signal()
        }
        if let error {
            box.mutate { $0.failure = "no response (\(error.localizedDescription))" }
            return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            box.mutate { $0.failure = "HTTP \(http.statusCode)" }
            return
        }
        guard let data else {
            box.mutate { $0.failure = "the response carried no body" }
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            box.mutate { $0.failure = "the response was not JSON" }
            return
        }
        box.mutate { $0.rows = indexItunesResults(obj) }
    }.resume()
    var result = box.value
    if !result.answered, sem.wait(timeout: .now() + itunesLookupTimeout) == .timedOut {
        result.failure = "no answer within \(Int(itunesLookupTimeout))s"
    }
    if let failure = result.failure {
        onFailure?(failure)
    }
    return result.rows
}

private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    init(_ value: T) { _value = value }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&_value)
    }
}

public func itunesLookup(
    _ bundleId: String,
    session: URLSession = .shared,
    onFailure: ((String) -> Void)? = nil
) -> [String: Any]? {
    if bundleId.isEmpty { return nil }
    for country in storeCountries() {
        let idx = itunesRequest(
            ["bundleId": bundleId, "country": country],
            session: session,
            onFailure: onFailure
        )
        if let row = idx[bundleId] { return row }
    }
    return nil
}

public func itunesLookupBatch(
    _ adamIds: [String],
    session: URLSession = .shared,
    onFailure: ((String) -> Void)? = nil
) -> [String: [String: Any]] {
    let ids = adamIds.filter { !$0.isEmpty }
    if ids.isEmpty { return [:] }
    var out: [String: [String: Any]] = [:]
    for country in storeCountries() {
        let missing = ids.filter { out[$0] == nil }
        if missing.isEmpty { break }
        var i = 0
        while i < missing.count {
            let chunk = Array(missing[i..<min(i + 20, missing.count)])
            let idx = itunesRequest(
                ["id": chunk.joined(separator: ","), "country": country],
                session: session,
                onFailure: onFailure
            )
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
        cat = masCatalog(masApps, onFailure: { progress?("  · App Store lookup failed (\($0)): updates may be missing") })
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

func masCatalog(
    _ apps: [AppRecord],
    session: URLSession = .shared,
    onFailure: ((String) -> Void)? = nil
) -> [String: [String: Any]] {
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
    var catalog = itunesLookupBatch(ids, session: session, onFailure: onFailure)
    for app in mutated {
        let extra = app.extra
        let adam = extra["mas_adam_id"] ?? ""
        let bid = app.bundleId
        if (!adam.isEmpty && catalog[adam] != nil) || (bid != nil && catalog[bid!] != nil) {
            continue
        }
        guard let bid else { continue }
        guard let row = itunesLookup(bid, session: session, onFailure: onFailure) else { continue }
        catalog[bid] = row
        if let tid = row["trackId"] {
            catalog["\(tid)"] = row
        }
    }
    return catalog
}

public func attachItunesMeta(
    _ pkgs: [OutdatedPkg],
    catalog: [String: [String: Any]]? = nil,
    onFailure: ((String) -> Void)? = nil
) {
    let ids = pkgs.filter { $0.manager == "app-store" && $0.name.allSatisfy(\.isNumber) }.map(\.name)
    let cat = catalog ?? itunesLookupBatch(ids, onFailure: onFailure)
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
            if !title.isEmpty, title.posixLowercased() != p.name.posixLowercased() {
                p.title = title
            }
        }
    }
}

public func queryMas(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg]? {
    guard let path = which("mas") else { return nil }
    progress?("  · checking App Store updates…")
    let (rc, out, _) = run([path, "outdated"], 90)
    if rc != 0 { return nil }
    return parseMasOutdated(out)
}

public func queryAppstore(
    _ apps: [AppRecord],
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    if PlatformOverride.isLinux { return [] }
    if let pkgs = queryMas(progress: progress, which: which, run: run) {
        attachItunesMeta(pkgs) { progress?("  · App Store lookup failed (\($0)): details may be missing") }
        return pkgs
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
    // `remote-ls` (network) and `list` (local metadata walk, ~2.4 s itself)
    // are independent: overlap them. `concurrentPerform` keeps `run`
    // non-escaping, so no `withoutActuallyEscaping` check can abort the scan.
    func pair(withMeta: Bool) -> (rc: Int32, updates: String, installed: String) {
        let r1 = LockBox<(Int32, String)>((127, ""))
        let r2 = LockBox<(Int32, String)>((127, ""))
        let args = [
            flatpakColumns(path: path, kind: "updates", withMeta: withMeta),
            flatpakColumns(path: path, kind: "list", withMeta: withMeta),
        ]
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let (rc, out, _) = run(args[i], 60)
            if i == 0 { r1.value = (rc, out) } else { r2.value = (rc, out) }
        }
        let (rc1, updates) = r1.value
        let (rc2, installed) = r2.value
        return (rc1, updates, rc2 == 0 ? installed : "")
    }
    var (rc, updates, installed) = pair(withMeta: true)
    // A failing remote (GPG error on stderr) still prints other remotes'
    // rows on stdout: use them instead of discarding and repaying the
    // full `remote-ls` cost with plain columns. Retry plain only when BOTH
    // outputs parse to nothing: that means old flatpak without --columns,
    // not a flaky remote (local `list` still succeeds then).
    if rc != 0, parseFlatpakUpdates(updates).isEmpty, installed.isEmpty {
        (rc, updates, installed) = pair(withMeta: false)
        if rc != 0, parseFlatpakUpdates(updates).isEmpty {
            noteScanCheckFailed("flatpak")
            return []
        }
    }
    return parseFlatpakUpdates(updates, installedText: installed)
}

public func querySnap(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("snap") else { return [] }
    progress?("  · checking Snap updates…")
    // `refresh --list` and `list` are independent: overlap them.
    // `concurrentPerform` keeps `run` non-escaping (see `pmap`).
    let r1 = LockBox<(Int32, String)>((127, ""))
    let r2 = LockBox<(Int32, String)>((127, ""))
    let refreshArgs = [path, "refresh", "--list"]
    let listArgs = [path, "list"]
    DispatchQueue.concurrentPerform(iterations: 2) { i in
        let (rc, out, _) = run(i == 0 ? refreshArgs : listArgs, 60)
        if i == 0 { r1.value = (rc, out) } else { r2.value = (rc, out) }
    }
    let (rc, refresh) = r1.value
    if rc != 0 {
        noteScanCheckFailed("snap")
        return []
    }
    let (rc2, listed) = r2.value
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
    if rc != 0 {
        noteScanCheckFailed("apt")
        return []
    }
    return parseAptUpgradable(out)
}

public func queryAur(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    for name in ["paru", "yay", "pikaur"] {
        guard let path = which(name) else { continue }
        progress?("  · checking AUR updates…")
        let (rc, out, _) = run([path, "-Qua"], 60)
        if rc != 0 && rc != 1 {
            noteScanCheckFailed("aur")
            continue
        }
        return parsePacmanQu(out).map { pkg in
            OutdatedPkg(
                name: pkg.name,
                manager: "aur",
                currentVersion: pkg.currentVersion,
                latestVersion: pkg.latestVersion
            )
        }
    }
    return []
}

public func queryPacman(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("pacman") else { return [] }
    progress?("  · checking pacman updates…")
    let (rc, out, _) = run([path, "-Qu"], 60)
    if rc != 0 && rc != 1 {
        noteScanCheckFailed("pacman")
        return []
    }
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
    let manager = name == "yum" ? "yum" : "dnf"
    func parsed(_ rc: Int32, _ out: String) -> [OutdatedPkg]? {
        if rc == 0 || rc == 100 { return parseDnfUpgrades(out, manager: manager) }
        return nil
    }
    if name != "yum" {
        let (rc, out, _) = run([path, "list", "--upgrades"], 60)
        if let pkgs = parsed(rc, out) { return pkgs }
    }
    let (rc, out, _) = run([path, "check-update"], 60)
    if let pkgs = parsed(rc, out) { return pkgs }
    noteScanCheckFailed(manager)
    return []
}

public func queryZypper(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> [OutdatedPkg] {
    guard let path = which("zypper") else { return [] }
    progress?("  · checking zypper updates…")
    let (rc, out, _) = run([path, "--non-interactive", "list-updates"], 60)
    if rc != 0 {
        noteScanCheckFailed("zypper")
        return []
    }
    return parseZypperListUpdates(out)
}

public func collectLinux(
    progress: ((String) -> Void)? = nil,
    which: @escaping WhichFn = whichCommand,
    run: @escaping CommandRun = runCommand,
    osRelease: String? = nil
) -> [OutdatedPkg] {
    // Manager queries are independent subprocess waits: run them concurrently
    // (flatpak + AUR alone cost ~3 s sequential on this box). One summary
    // progress line: per-manager lines would interleave across threads.
    progress?("  · checking Linux updates (flatpak, snap, AUR, distro)…")
    let family = linuxDistroFamily(osRelease: osRelease ?? linuxOsReleaseText())
    let distro = resolveDistroPackageManager(family: family, which: which)
    var queries: [() -> [OutdatedPkg]] = [
        { queryFlatpak(which: which, run: run) },
        { querySnap(which: which, run: run) },
        { queryAur(which: which, run: run) },
    ]
    switch distro {
    case .pacman:
        queries.append { queryPacman(which: which, run: run) }
    case .dnf:
        queries.append { queryDnf(which: which, run: run) }
    case .some(DistroPackageManager.zypperPkg):
        queries.append { queryZypper(which: which, run: run) }
    case .apt, .dpkg:
        queries.append { queryApt(which: which, run: run) }
    case nil:
        break
    }
    return pmap(queries, workers: 4) { $0() }.flatMap { $0 }
}

/// Lookup keys for joining a package to the software it belongs to. These are
/// identifiers from Homebrew, apt, the App Store and the desktop database, so
/// the fold must not follow the user's locale: in tr_TR `lowercased()` maps "I"
/// to "ı" and a package called "ILKER" never links to an app called "ilker",
/// which silently drops it from the Outdated list.
func softwareKeys(_ sw: Software) -> Set<String> {
    var keys: Set<String> = [sw.name.posixLowercased()]
    if let v = sw.caskName, !v.isEmpty { keys.insert(v.posixLowercased()) }
    if let v = sw.bundleId, !v.isEmpty { keys.insert(v.posixLowercased()) }
    if let v = sw.pkgId, !v.isEmpty { keys.insert(v.posixLowercased()) }
    for b in sw.bins { keys.insert(b.posixLowercased()) }
    if let desktopId = sw.extra["desktop_id"], !desktopId.isEmpty {
        keys.insert(desktopId.posixLowercased())
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
        var keys: Set<String> = [pkg.name.posixLowercased()]
        if let title = pkg.title, !title.isEmpty { keys.insert(title.posixLowercased()) }
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
        var hit = index[pkg.name.posixLowercased()]
        if hit == nil, let title = pkg.title {
            hit = index[title.posixLowercased()]
        }
        if let hit { pkg.summary = hit }
    }
}
