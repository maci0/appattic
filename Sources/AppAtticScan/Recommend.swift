import Foundation

/// Last-used within this many days is KEEP (actively in use).
public let activeDays = 30
/// Last-used older than this many days can be REMOVE if reinstall is easy and data is small.
public let staleDays = 180
/// Owned user data at or above this size blocks REMOVE (REVIEW instead).
public let dataKeepThreshold = 50 * 1024 * 1024

public final class Software {
    public var name: String
    public var kind: String
    public var path: String
    public var source: String
    public var sizeBytes: Int
    public var sizeMeasured: Bool
    public var lastUsed: Date?
    public var usageSource: String?
    public var installedAt: Date?
    public var dataBytes: Int
    public var dataMeasured: Bool
    public var dataPaths: [String]
    public var dataMtime: Date?
    public var runningService: Bool
    public var version: String?
    public var caskName: String?
    public var isLeaf: Bool
    public var bins: [String]
    public var historySpanDays: Double?
    public var outdated: Bool
    public var latestVersion: String?
    public var pkgId: String?
    public var bundleId: String?
    public var summary: String?
    public var extra: [String: String]

    public init(
        name: String,
        kind: String,
        path: String,
        source: String,
        sizeBytes: Int = 0,
        sizeMeasured: Bool = true,
        lastUsed: Date? = nil,
        usageSource: String? = nil,
        installedAt: Date? = nil,
        dataBytes: Int = 0,
        dataMeasured: Bool = true,
        dataPaths: [String] = [],
        dataMtime: Date? = nil,
        runningService: Bool = false,
        version: String? = nil,
        caskName: String? = nil,
        isLeaf: Bool = true,
        bins: [String] = [],
        historySpanDays: Double? = nil,
        outdated: Bool = false,
        latestVersion: String? = nil,
        pkgId: String? = nil,
        bundleId: String? = nil,
        summary: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.path = path
        self.source = source
        self.sizeBytes = sizeBytes
        self.sizeMeasured = sizeMeasured
        self.lastUsed = lastUsed
        self.usageSource = usageSource
        self.installedAt = installedAt
        self.dataBytes = dataBytes
        self.dataMeasured = dataMeasured
        self.dataPaths = dataPaths
        self.dataMtime = dataMtime
        self.runningService = runningService
        self.version = version
        self.caskName = caskName
        self.isLeaf = isLeaf
        self.bins = bins
        self.historySpanDays = historySpanDays
        self.outdated = outdated
        self.latestVersion = latestVersion
        self.pkgId = pkgId
        self.bundleId = bundleId
        self.summary = summary
        self.extra = extra
    }
}

public struct Verdict {
    public var software: Software
    public var tier: String
    public var reason: String
    public var reclaimableBytes: Int
    public init(software: Software, tier: String, reason: String = "", reclaimableBytes: Int = 0) {
        self.software = software
        self.tier = tier
        self.reason = reason
        self.reclaimableBytes = reclaimableBytes
    }

    public var softwareTier: SoftwareTier? { SoftwareTier(rawValue: tier) }
}

/// REVIEW and REMOVE rows, plus SYSTEM when `includeSystem` is on. KEEP is omitted.
public func staleVerdicts(_ verdicts: [Verdict], includeSystem: Bool = false) -> [Verdict] {
    verdicts.filter {
        $0.tier == "remove" || $0.tier == "review" || (includeSystem && $0.tier == "system")
    }
}

/// Same filter as `staleVerdicts` for JSON `SoftwareItem` rows.
public func visibleStaleSoftware(_ items: [SoftwareItem], includeSystem: Bool) -> [SoftwareItem] {
    items.filter {
        $0.tier == "remove" || $0.tier == "review" || (includeSystem && $0.tier == "system")
    }
}

func matchDataItems(softwareName: String, bundleId: String?, items: [DataItem]) -> [DataItem] {
    var out: [DataItem] = []
    let swLow = softwareName.lowercased()
    let swNorm = norm(softwareName)
    let b = (bundleId ?? "").lowercased()
    for it in items {
        if it.status != "owned" { continue }
        let n = stripLeftoverNameSuffix(it.name).lowercased()
        if let owner = it.owner, owner.lowercased() == swLow {
            out.append(it)
            continue
        }
        if !b.isEmpty, n == b {
            out.append(it)
            continue
        }
        let display = leftoverDisplayName(name: it.name, extraPaths: it.extraPaths)
        if display.lowercased() == swLow || norm(display) == swNorm {
            out.append(it)
            continue
        }
        if n == swLow || norm(it.name) == swNorm {
            out.append(it)
        }
    }
    return out
}

func attachOwnedData(_ sw: Software, name: String, bundleId: String?, items: [DataItem]) {
    let matched = matchDataItems(softwareName: name, bundleId: bundleId, items: items)
    sw.dataBytes = matched.reduce(0) { addBytes($0, $1.sizeBytes) }
    sw.dataPaths = matched.map(\.path)
    sw.dataMtime = newestActivity(matched)
    sw.dataMeasured = matched.allSatisfy(\.sizeMeasured)
}

public func staleSizeText(sizeBytes: Int, sizeMeasured: Bool, dataBytes: Int) -> String {
    let app = sizeMeasured ? humanSize(sizeBytes) : "n/a"
    if dataBytes > 0 {
        return "\(app) + \(humanSize(dataBytes))"
    }
    return app
}

/// Byte total for listed stale rows (REVIEW + REMOVE). Overview uses this as a size hint, not a promise that cleanup will delete them.
public func staleReclaimableBytes(_ items: [SoftwareItem]) -> Int {
    items.filter { $0.tier == "remove" || $0.tier == "review" }
        .reduce(0) { addBytes($0, $1.totalBytes) }
}

public func overviewStaleTotalLabel(count: Int, bytes: Int) -> String {
    if bytes > 0 {
        return "\(count) · \(humanSize(bytes))"
    }
    return "\(count)"
}

func newestActivity(_ items: [DataItem]) -> Date? {
    var best: Date?
    for it in items {
        let dt = it.activityMtime ?? it.mtime
        if let dt, best == nil || dt > best! { best = dt }
    }
    return best
}

func caskForApp(_ app: AppRecord, casks: [Cask], pathIndex: [String: String]) -> Cask? {
    if let token = pathIndex[app.path], let hit = casks.first(where: { $0.name == token }) {
        return hit
    }
    let base = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.lowercased()
    let display = app.displayName.lowercased()
    let an = norm(app.displayName)
    for c in casks {
        for art in c.appNames {
            let artBase = URL(fileURLWithPath: art).deletingPathExtension().lastPathComponent.lowercased()
            if !artBase.isEmpty, artBase == base { return c }
        }
        let titles = [c.name] + c.titles
        let lowered = Set(titles.filter { !$0.isEmpty }.map { $0.lowercased() })
        if !display.isEmpty, lowered.contains(display) { return c }
        if an.count < 6 { continue }
        for t in titles {
            let tn = norm(t)
            if tn.isEmpty { continue }
            if an == tn { return c }
            if min(an.count, tn.count) >= 6, tn.hasPrefix(an) || an.hasPrefix(tn) { return c }
        }
    }
    return nil
}

func appBlurb(_ extra: [String: String], appName: String) -> String? {
    let raw = extra["comment"] ?? extra["description"]
    guard let raw else { return nil }
    return plistDescription(["NSHumanReadableDescription": raw], appName: appName)
}

func brewHistoryKeep(_ brew: BrewSnapshot) -> Set<String> {
    var keep: Set<String> = []
    for f in brew.formulas {
        keep.insert(f.name)
        keep.formUnion(f.aliases)
        keep.formUnion(f.bins)
    }
    return keep
}

public func buildSoftware(
    apps: [AppRecord],
    brew: BrewSnapshot,
    dataItems: [DataItem],
    progress: (String) -> Void = { _ in },
    history: HistoryIndex? = nil,
    includeDarwinNonApp: Bool? = nil,
    nonAppPaths: [String]? = nil,
    du: ((String) -> (Int, Bool))? = nil,
    now: Date = Date()
) -> [Software] {
    let history = history ?? (brew.available && !brew.formulas.isEmpty
        ? loadHistory(keep: brewHistoryKeep(brew))
        : HistoryIndex())
    var software: [Software] = []
    let caskDesc = Dictionary(brew.casks.compactMap { c in
        c.desc.map { (c.name, $0) }
    }, uniquingKeysWith: { _, last in last })
    var caskAppPaths: [String: String] = [:]
    for c in brew.casks {
        for p in c.appPaths { caskAppPaths[p] = c.name }
    }

    for a in apps {
        let cask = caskForApp(a, casks: brew.casks, pathIndex: caskAppPaths)
        let source: String
        if a.isSystem {
            source = "system"
        } else if a.extra["steam_appid"] != nil || a.extra["steam_client"] == "1" || a.sourceDir == "steam" {
            source = "steam"
        } else if a.extra["crossover_bottle"] == "1" || a.sourceDir == "crossover" {
            source = "crossover"
        } else if cask != nil {
            source = "brew-cask"
        } else if let linux = a.extra["linux_source"], linux == "flatpak" || linux == "snap" || linux == "appimage" {
            source = linux
        } else {
            source = "pkg/other"
        }
        let sw = Software(
            name: a.displayName,
            kind: "app",
            path: a.path,
            source: source,
            sizeBytes: a.sizeBytes,
            sizeMeasured: a.sizeMeasured,
            lastUsed: a.lastUsed,
            usageSource: a.lastUsedSource ?? (a.isSystem ? "unknown" : nil),
            installedAt: a.installedAt,
            pkgId: a.extra["pkg_id"] ?? a.extra["desktop_id"] ?? a.bundleId,
            bundleId: a.bundleId,
            extra: a.extra
        )
        attachOwnedData(sw, name: a.displayName, bundleId: a.bundleId, items: dataItems)
        if let cask { sw.caskName = cask.name }
        sw.summary = shortDesc(
            appBlurb(a.extra, appName: a.displayName)
                ?? cask?.desc
                ?? (sw.caskName.flatMap { caskDesc[$0] })
                ?? a.extra["category"]
        )
        software.append(sw)
    }

    if brew.available {
        progress("  · checking shell history for \(brew.formulas.count) brew formulas…")
        let span = historySpanDays(history, now: now)
        for f in brew.formulas {
            let names = [f.name] + f.aliases + f.bins
            let (last, ever) = lastUsedFromHistory(names, index: history)
            let sw = Software(
                name: f.name,
                kind: "formula",
                path: URL(fileURLWithPath: brew.prefix ?? "/opt/homebrew")
                    .appendingPathComponent("bin")
                    .appendingPathComponent(f.name)
                    .path,
                source: "brew-formula",
                lastUsed: last,
                usageSource: (last != nil || ever) ? "shell-history" : "unknown",
                runningService: brew.services.contains(f.name),
                version: f.version,
                isLeaf: f.isLeaf,
                bins: f.bins,
                historySpanDays: span,
                summary: shortDesc(f.desc)
            )
            attachOwnedData(sw, name: f.name, bundleId: nil, items: dataItems)
            software.append(sw)
        }
    }

    let darwinNonApp = includeDarwinNonApp ?? PlatformOverride.isDarwin
    if darwinNonApp {
        let formulaNames = Set(brew.formulas.map { $0.name.lowercased() })
        let caskNames = Dictionary(brew.casks.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { _, last in last })
        let paths = nonAppPaths ?? nonAppEntriesIn("/Applications")
        let measure = du ?? { p in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return duSize(p)
            }
            return (fileSize(p), true)
        }
        for path in paths {
            if apps.contains(where: { $0.path.hasPrefix(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") || $0.path.hasPrefix(path + "/") }) {
                continue
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let key = name.lowercased()
            if formulaNames.contains(key) { continue }
            let (size, measured) = measure(path)
            let caskName = caskNames[key]
            software.append(Software(
                name: name,
                kind: "other",
                path: path,
                source: caskName != nil ? "brew-cask" : "pkg/other",
                sizeBytes: size,
                sizeMeasured: measured,
                caskName: caskName,
                summary: shortDesc(caskName.flatMap { caskDesc[$0] })
            ))
        }
    }

    var seenCasks = Set(software.compactMap { $0.caskName?.lowercased() })
    for c in brew.casks {
        let key = c.name.lowercased()
        if seenCasks.contains(key) { continue }
        seenCasks.insert(key)
        let path = URL(fileURLWithPath: brew.prefix ?? "/opt/homebrew")
            .appendingPathComponent("Caskroom")
            .appendingPathComponent(c.name)
            .path
        var size = 0
        var measured = true
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let pair = du?(path) ?? (isDir.boolValue ? duSize(path) : (fileSize(path), true))
            size = pair.0
            measured = pair.1
        }
        let title = (c.titles.first ?? "").trimmingCharacters(in: .whitespaces)
        let hasApp = !c.appNames.isEmpty || !c.appPaths.isEmpty
        software.append(Software(
            name: title.isEmpty ? c.name : title,
            kind: hasApp ? "app" : "other",
            path: path,
            source: "brew-cask",
            sizeBytes: size,
            sizeMeasured: measured,
            caskName: c.name,
            summary: shortDesc(c.desc)
        ))
    }
    return software
}

func spanNote(_ sw: Software) -> String {
    if sw.historySpanDays == nil {
        return "shell history has no timestamps"
    }
    return "no usage in the last \(humanDays(sw.historySpanDays!)) of shell history"
}

func isSteamClientSoftware(_ sw: Software) -> Bool {
    if sw.extra["steam_client"] == "1" { return true }
    return sw.source == "steam"
        && sw.extra["steam_appid"] == nil
        && sw.name.compare("Steam", options: .caseInsensitive) == .orderedSame
}

/// KEEP / REVIEW / REMOVE / SYSTEM from usage age, data size, and how easy reinstall is.
/// System apps and the Steam client are never REMOVE. Missing last-used is REVIEW unless
/// a brew formula has a long enough shell-history span.
public func evaluate(_ sw: Software, now: Date = Date()) -> Verdict {
    if sw.source == "system" {
        return Verdict(software: sw, tier: "system", reason: "System app: leave alone")
    }
    if isSteamClientSoftware(sw) {
        return Verdict(software: sw, tier: "keep", reason: "Steam client: uninstall games from Steam, not by deleting this folder")
    }
    if sw.runningService {
        return Verdict(software: sw, tier: "keep", reason: "Running as a brew service (daemon)")
    }
    var used = sw.lastUsed
    var fromData = false
    if let dm = sw.dataMtime, used == nil || dm > used! {
        used = dm
        fromData = true
    }
    let days = daysSince(used, now: now)
    let reinstallEasy = reinstallHint(sw.source) != nil

    if sw.kind == "formula", !sw.isLeaf {
        return Verdict(software: sw, tier: "keep", reason: "Dependency of other brew packages: remove the parent instead")
    }
    if sw.kind == "formula", sw.bins.isEmpty, days == nil {
        return Verdict(software: sw, tier: "keep", reason: "Library formula: no command to measure usage")
    }

    if days == nil {
        let ageDays = sw.installedAt != nil ? daysSince(sw.installedAt, now: now) : nil
        if let ageDays, ageDays < Double(activeDays) {
            return Verdict(software: sw, tier: "keep", reason: "Installed \(humanDays(ageDays)) ago: too new to judge")
        }
        if sw.kind == "formula" {
            let span = sw.historySpanDays
            if span == nil || span! < Double(staleDays) {
                return Verdict(software: sw, tier: "keep", reason: "\(spanNote(sw)): not enough history to judge usage")
            }
            return Verdict(
                software: sw,
                tier: "remove",
                reason: "\(spanNote(sw)); easy to reinstall via brew",
                reclaimableBytes: addBytes(sw.sizeBytes, sw.dataBytes)
            )
        }
        if sw.source == "brew-cask", sw.kind == "other" {
            return Verdict(software: sw, tier: "keep", reason: "Homebrew cask with no app bundle: no unused-app signal")
        }
        if reinstallEasy {
            let when = ageDays != nil ? humanDays(ageDays!) : "a while"
            return Verdict(
                software: sw,
                tier: "review",
                reason: "No usage detected (installed \(when) ago). Review before uninstalling."
            )
        }
        return Verdict(software: sw, tier: "review", reason: "No usage detected: check if you still need it")
    }

    let d = days!
    if d <= Double(activeDays) {
        if fromData {
            return Verdict(software: sw, tier: "keep", reason: "Data directory written \(humanDays(d)) ago")
        }
        return Verdict(software: sw, tier: "keep", reason: "Used \(humanDays(d)) ago: actively in use")
    }
    if fromData {
        return Verdict(software: sw, tier: "review", reason: "Data directory written \(humanDays(d)) ago")
    }
    if d <= Double(staleDays) {
        return Verdict(software: sw, tier: "review", reason: "Not used for \(humanDays(d))")
    }
    if !sw.dataMeasured {
        return Verdict(
            software: sw,
            tier: "review",
            reason: "Not used for \(humanDays(d)) but holds data that could not be measured: review before removing"
        )
    }
    if sw.dataBytes >= dataKeepThreshold {
        return Verdict(
            software: sw,
            tier: "review",
            reason: "Not used for \(humanDays(d)) but holds significant data: review before removing"
        )
    }
    if reinstallEasy {
        return Verdict(
            software: sw,
            tier: "remove",
            reason: "Not used for \(humanDays(d)). \(reinstallHint(sw.source) ?? "Easy to reinstall.")",
            reclaimableBytes: addBytes(sw.sizeBytes, sw.dataBytes)
        )
    }
    return Verdict(
        software: sw,
        tier: "review",
        reason: "Not used for \(humanDays(d)). Manual reinstall if you still want it."
    )
}

public func reinstallHint(_ source: String) -> String? {
    switch source {
    case "brew-cask", "brew-formula":
        return "Easy to reinstall with brew."
    case "flatpak":
        return "Easy to reinstall with Flatpak."
    case "snap":
        return "Easy to reinstall with Snap."
    case "appimage":
        return "Easy to replace with the same AppImage."
    default:
        return nil
    }
}

/// Map cached reason strings from older scans onto current copy. New verdicts already use the new wording.
public func displayStaleReason(_ reason: String) -> String {
    let rules: [(String, String)] = [
        ("trivial to reinstall", ". Easy to reinstall with brew."),
        ("manual reinstall would be required", ". Manual reinstall if you still want it."),
    ]
    for (needle, suffix) in rules {
        guard reason.contains(needle) else { continue }
        let prefix = reason.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? reason
        return prefix.trimmingCharacters(in: .whitespaces) + suffix
    }
    return reason
}

public func evaluateAll(_ software: [Software], now: Date = Date()) -> [Verdict] {
    software.map { evaluate($0, now: now) }
}

public func softwareDisplaySummary(_ sw: Software) -> String {
    if let s = sw.summary, !s.isEmpty, !isJunkAppBlurb(s) {
        let words = s.split(whereSeparator: \.isWhitespace)
        if sw.source != "steam" || isSteamClientSoftware(sw) || words.count >= 4 {
            return s
        }
    }
    if sw.kind == "formula" || sw.source == "brew-formula" { return "Homebrew formula" }
    if sw.source == "brew-cask" { return "Homebrew cask" }
    if sw.source == "flatpak" { return "Flatpak app" }
    if sw.source == "snap" { return "Snap app" }
    if sw.source == "appimage" { return "AppImage" }
    if isSteamClientSoftware(sw) { return "Steam client" }
    if sw.source == "steam" { return "Steam game" }
    if sw.source == "crossover" { return "CrossOver bottle" }
    if sw.kind == "app" { return "Installed application" }
    return "Installed software"
}
