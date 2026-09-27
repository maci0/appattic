import Foundation

/// Last-used within this many days is KEEP (actively in use).
public let activeDays = 30
/// Last-used older than this many days can be REMOVE if reinstall is easy and data is small.
public let staleDays = 180
/// Owned user data at or above this size blocks REMOVE (REVIEW instead).
public let dataKeepThreshold = 50 * 1024 * 1024

/// One installed app, formula, cask, or tool the scan found, with everything
/// later stages need to judge it. The live counterpart of the JSON
/// `SoftwareItem`: `sizeBytes` is the app, `dataBytes` its matched user data,
/// and `sizeMeasured` / `dataMeasured` say whether each number was measured or
/// could not be.
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

/// One software row's tier and the reason behind it. `tier` is the wire string;
/// `tierKind` is the typed read, and `reason` is the sentence the report shows,
/// so a caller never has to re-derive why a row landed where it did.
public struct Verdict {
    public var software: Software
    public var tier: String
    public var reason: String
    /// `tier` as a typed value, or nil when it is not a known tier.
    public var tierKind: StaleTier? { StaleTier(rawValue: tier) }
    public init(software: Software, tier: String, reason: String = "") {
        self.software = software
        self.tier = tier
        self.reason = reason
    }
}

/// REVIEW and REMOVE rows, plus SYSTEM when `includeSystem` is on. KEEP is omitted.
public func staleVerdicts(_ verdicts: [Verdict], includeSystem: Bool = false) -> [Verdict] {
    verdicts.filter { $0.tierKind?.isVisibleStale(includeSystem: includeSystem) == true }
}

/// Same filter as `staleVerdicts` for JSON `SoftwareItem` rows.
public func visibleStaleSoftware(_ items: [SoftwareItem], includeSystem: Bool) -> [SoftwareItem] {
    items.filter { $0.tierKind?.isVisibleStale(includeSystem: includeSystem) == true }
}

func matchDataItems(softwareName: String, bundleId: String?, items: [DataItem]) -> [DataItem] {
    var out: [DataItem] = []
    let swLow = softwareName.posixLowercased()
    // A name in another script folds to "", and so does every other such name,
    // so the folded comparison below is skipped for it. Only the exact
    // lowercase and bundle-id matches can decide ownership.
    let swNorm = normKey(softwareName)
    let b = (bundleId ?? "").posixLowercased()
    for it in items {
        if it.leftoverStatus != .owned { continue }
        let n = stripLeftoverNameSuffix(it.name).posixLowercased()
        if let owner = it.owner, owner.posixLowercased() == swLow {
            out.append(it)
            continue
        }
        if !b.isEmpty, n == b {
            out.append(it)
            continue
        }
        let display = leftoverDisplayName(name: it.name, extraPaths: it.extraPaths)
        if display.posixLowercased() == swLow || n == swLow {
            out.append(it)
            continue
        }
        guard let folded = swNorm,
              normKey(display) == folded || normKey(it.name) == folded
        else { continue }
        out.append(it)
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

/// App size plus its matched data size, `"n/a"` for a part that was not
/// measured. `dataBytes` is dropped when it is zero, so a row with no data
/// reads as the app size alone.
public func staleSizeText(sizeBytes: Int, sizeMeasured: Bool, dataBytes: Int) -> String {
    let app = sizeMeasured ? humanSize(sizeBytes) : "n/a"
    if dataBytes > 0 {
        return "\(app) + \(humanSize(dataBytes))"
    }
    return app
}

/// Byte total for listed stale rows (REVIEW + REMOVE). Overview uses this as a size hint, not a promise that cleanup will delete them.
public func staleReclaimableBytes(_ items: [SoftwareItem]) -> Int {
    items.filter { StaleTier.isSelectable($0.tierKind) }
        .reduce(0) { addBytes($0, $1.totalBytes) }
}

/// The Overview stale total: a count, with a size behind it once there is
/// one. Call it with `staleReclaimableBytes`, which counts REVIEW and REMOVE
/// rows only, so the number matches what cleanup can actually reclaim.
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
    let base = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.posixLowercased()
    let display = app.displayName.posixLowercased()
    let an = norm(app.displayName)
    for c in casks {
        for art in c.appNames {
            let artBase = URL(fileURLWithPath: art).deletingPathExtension().lastPathComponent.posixLowercased()
            if !artBase.isEmpty, artBase == base { return c }
        }
        let titles = [c.name] + c.titles
        let lowered = Set(titles.filter { !$0.isEmpty }.map { $0.posixLowercased() })
        if !display.isEmpty, lowered.contains(display) { return c }
        if an.count < 6 { continue }
        let cn = norm(c.name)
        // `norm` drops separators, so once normalised a pretty title can extend
        // the app name with no word boundary left to check ("Google Chrome" vs
        // "Google Chrome Canary"). A longer title only names the same product
        // when the cask name itself shares the app-name prefix, which is the
        // form Homebrew uses for a variant ("zerotier-one" for ZeroTier One).
        let caskNamesApp = cn.count >= 3 && (cn == an || an.hasPrefix(cn) || cn.hasPrefix(an))
        for t in titles {
            let tn = norm(t)
            if tn.isEmpty { continue }
            if an == tn { return c }
            if caskNamesApp, min(an.count, tn.count) >= 6, tn.hasPrefix(an) || an.hasPrefix(tn) { return c }
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

/// Turn discovered apps and a Homebrew snapshot into `Software` rows, matching
/// each app's user data so the rows carry `dataBytes` and `dataPaths`.
///
/// `history` is the shell-history index; leaving it nil reads the history of
/// the current user, which is slow, so a caller that already has one passes
/// it in. `du` is the `(bytes, measured)` size function; leaving it nil measures
/// with `duSizes`, one `du` per path. `includeDarwinNonApp` and `nonAppPaths`
/// are the non-`.app` inclusions the macOS UI opts into; `includeDarwinNonApp`
/// defaults to whether this is a Darwin host.
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
        ? loadHistory(keep: brewHistoryKeep(brew), now: now)
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
        let formulaNames = Set(brew.formulas.map { $0.name.posixLowercased() })
        let caskNames = Dictionary(brew.casks.map { ($0.name.posixLowercased(), $0.name) }, uniquingKeysWith: { _, last in last })
        let paths = nonAppPaths ?? nonAppEntriesIn("/Applications")
        // A non-app entry is skipped when it holds an app, which the old
        // `apps.contains(where:)` scan answered in O(entries x apps) and
        // re-trimmed the entry per app. Inverted: index the strict ancestor
        // directories of every app once, then probe.
        let appAncestorDirs = strictAncestorDirs(of: apps.map(\.path))
        var candidates: [(name: String, key: String, path: String)] = []
        for path in paths {
            if appAncestorDirs.contains(trimmedSlashes(path)) { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let key = name.posixLowercased()
            if formulaNames.contains(key) { continue }
            candidates.append((name, key, path))
        }
        // One `du -sk` per chunk, not one spawn per entry: the old per-path
        // `measure` cost ~50 ms a spawn, and /Applications holds hundreds of
        // entries.
        let sizes = pathSizes(candidates.map(\.path), du: du)
        for c in candidates {
            let (size, measured) = sizes[c.path] ?? (0, false)
            let caskName = caskNames[c.key]
            software.append(Software(
                name: c.name,
                kind: "other",
                path: c.path,
                source: caskName != nil ? "brew-cask" : "pkg/other",
                sizeBytes: size,
                sizeMeasured: measured,
                caskName: caskName,
                summary: shortDesc(caskName.flatMap { caskDesc[$0] })
            ))
        }
    }

    var seenCasks = Set(software.compactMap { $0.caskName?.posixLowercased() })
    let caskroom = URL(fileURLWithPath: brew.prefix ?? "/opt/homebrew")
        .appendingPathComponent("Caskroom")
    var pendingCasks: [(cask: Cask, path: String, exists: Bool)] = []
    for c in brew.casks {
        let key = c.name.posixLowercased()
        if seenCasks.contains(key) { continue }
        seenCasks.insert(key)
        let path = caskroom.appendingPathComponent(c.name).path
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        pendingCasks.append((c, path, exists))
    }
    // One `du -sk` per chunk, not one spawn per cask: a full caskroom is
    // hundreds of casks, so the per-cask `du` was hundreds of spawns.
    let caskSizes = pathSizes(pendingCasks.filter { $0.exists }.map(\.path), du: du)
    for entry in pendingCasks {
        var size = 0
        var measured = true
        if entry.exists {
            let pair = caskSizes[entry.path] ?? (0, false)
            size = pair.0
            measured = pair.1
        }
        let title = (entry.cask.titles.first ?? "").trimmingCharacters(in: .whitespaces)
        let hasApp = !entry.cask.appNames.isEmpty || !entry.cask.appPaths.isEmpty
        software.append(Software(
            name: title.isEmpty ? entry.cask.name : title,
            kind: hasApp ? "app" : "other",
            path: entry.path,
            source: "brew-cask",
            sizeBytes: size,
            sizeMeasured: measured,
            caskName: entry.cask.name,
            summary: shortDesc(entry.cask.desc)
        ))
    }
    return software
}

func spanNote(_ sw: Software) -> String {
    guard let span = sw.historySpanDays else {
        return "shell history has no timestamps"
    }
    return "no usage in the last \(humanDays(span)) of shell history"
}

func isSteamClientSoftware(_ sw: Software) -> Bool {
    if sw.extra["steam_client"] == "1" { return true }
    return sw.source == "steam"
        && sw.extra["steam_appid"] == nil
        && sw.name.compare("Steam", options: .caseInsensitive) == .orderedSame
}

func isSteamClientSoftware(_ item: SoftwareItem) -> Bool {
    item.source == "steam"
        && item.steam_appid == nil
        && item.name.compare("Steam", options: .caseInsensitive) == .orderedSame
}

/// KEEP / REVIEW / REMOVE / SYSTEM from usage age, data size, and how easy reinstall is.
/// System apps and the Steam client are never REMOVE. Missing last-used is REVIEW unless
/// a brew formula has a long enough shell-history span.
public func evaluate(_ sw: Software, now: Date = Date()) -> Verdict {
    if sw.source == "system" {
        return Verdict(software: sw, tier: StaleTier.system.rawValue, reason: "System app: leave alone")
    }
    if isSteamClientSoftware(sw) {
        return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Steam client: uninstall games from Steam, not by deleting this folder")
    }
    if sw.runningService {
        return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Running as a brew service (daemon)")
    }
    // A usage signal ahead of the scan by more than the skew tolerance is not a
    // usage signal: a data directory restored from a backup taken on a machine
    // whose clock ran ahead, a prefs mtime written by a desktop still catching
    // up, a Steam `last-seen` from a client with a wrong clock. `daysSince`
    // clamps a future date to 0, which reads as "used this second" and pins the
    // app to KEEP with no way to prove it idle. Same bound the launch sources
    // apply at ingestion (`droppingTimestampsAfter`, `isPlausibleLaunchDate`),
    // applied here so it also covers a data mtime.
    let plausible: (Date?) -> Date? = { $0.flatMap { isPlausibleLaunchDate($0, now: now) ? $0 : nil } }
    var used = plausible(sw.lastUsed)
    var fromData = false
    if let dm = plausible(sw.dataMtime), used == nil || dm > used! {
        used = dm
        fromData = true
    }
    let days = daysSince(used, now: now)
    let reinstallEasy = reinstallHint(sw.source) != nil

    if sw.kind == "formula", !sw.isLeaf {
        return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Dependency of other brew packages: remove the parent instead")
    }
    if sw.kind == "formula", sw.bins.isEmpty, days == nil {
        return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Library formula: no command to measure usage")
    }

    if days == nil {
        // Same bound: an install date in the future reads as "installed 1 h
        // ago", which is the "too new to judge" verdict with no way to age out.
        let ageDays = plausible(sw.installedAt).flatMap { daysSince($0, now: now) }
        if let ageDays, ageDays < Double(activeDays) {
            return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Installed \(humanDays(ageDays)) ago: too new to judge")
        }
        if sw.kind == "formula" {
            // A history with no span at all is the weakest signal there is,
            // so it lands on the same side as a span below the bound.
            let span = sw.historySpanDays ?? 0
            if span < Double(staleDays) {
                return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "\(spanNote(sw)): not enough history to judge usage")
            }
            // The same two guards the last-used path applies: a span of
            // history is only a weak usage signal, so a formula holding large
            // or unmeasured user data is REVIEW, exactly as an app would be.
            if !sw.dataMeasured {
                return Verdict(
                    software: sw,
                    tier: StaleTier.review.rawValue,
                    reason: "\(spanNote(sw)) but holds data that could not be measured: review before removing"
                )
            }
            if sw.dataBytes >= dataKeepThreshold {
                return Verdict(
                    software: sw,
                    tier: StaleTier.review.rawValue,
                    reason: "\(spanNote(sw)) but holds significant data: review before removing"
                )
            }
            return Verdict(
                software: sw,
                tier: StaleTier.remove.rawValue,
                reason: "\(spanNote(sw)); easy to reinstall via brew"
            )
        }
        if sw.source == "brew-cask", sw.kind == "other" {
            return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Homebrew cask with no app bundle: no unused-app signal")
        }
        if reinstallEasy {
            let when = ageDays.map(humanDays) ?? "a while"
            return Verdict(
                software: sw,
                tier: StaleTier.review.rawValue,
                reason: "No usage detected (installed \(when) ago). Review before uninstalling."
            )
        }
        return Verdict(software: sw, tier: StaleTier.review.rawValue, reason: "No usage detected: check if you still need it")
    }

    let d = days!
    if d <= Double(activeDays) {
        if fromData {
            return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Data directory written \(humanDays(d)) ago")
        }
        return Verdict(software: sw, tier: StaleTier.keep.rawValue, reason: "Used \(humanDays(d)) ago: actively in use")
    }
    if fromData {
        return Verdict(software: sw, tier: StaleTier.review.rawValue, reason: "Data directory written \(humanDays(d)) ago")
    }
    if d <= Double(staleDays) {
        return Verdict(software: sw, tier: StaleTier.review.rawValue, reason: "Not used for \(humanDays(d))")
    }
    if !sw.dataMeasured {
        return Verdict(
            software: sw,
            tier: StaleTier.review.rawValue,
            reason: "Not used for \(humanDays(d)) but holds data that could not be measured: review before removing"
        )
    }
    if sw.dataBytes >= dataKeepThreshold {
        return Verdict(
            software: sw,
            tier: StaleTier.review.rawValue,
            reason: "Not used for \(humanDays(d)) but holds significant data: review before removing"
        )
    }
    if reinstallEasy {
        return Verdict(
            software: sw,
            tier: StaleTier.remove.rawValue,
            reason: "Not used for \(humanDays(d)). \(reinstallHint(sw.source) ?? "Easy to reinstall.")"
        )
    }
    return Verdict(
        software: sw,
        tier: StaleTier.review.rawValue,
        reason: "Not used for \(humanDays(d)). Manual reinstall if you still want it."
    )
}

/// How hard a row is to bring back, or nil when the source says nothing about
/// reinstalling it.
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

/// One verdict per software row, in the order given. `now` is the instant the
/// idle windows are measured against, so a caller that scans over a long enough
/// run to want a single reference point should pass the same one to every call.
public func evaluateAll(_ software: [Software], now: Date = Date()) -> [Verdict] {
    software.map { evaluate($0, now: now) }
}

/// The one-line label a software row shows. A store description is used when it
/// says something; a junk blur or a too-short Steam blurb falls back to the
/// kind, so the row never reads as an empty description.
public func softwareDisplaySummary(_ sw: Software) -> String {
    softwareDisplaySummary(
        summary: sw.summary,
        kind: sw.kind,
        source: sw.source,
        steamClient: isSteamClientSoftware(sw)
    )
}

/// Same label for a JSON `SoftwareItem` row, which carries `steam_appid` where
/// `Software` carries `extra`, so the Steam-client test has to be re-derived.
public func softwareDisplaySummary(_ item: SoftwareItem) -> String {
    softwareDisplaySummary(
        summary: item.summary,
        kind: item.kind,
        source: item.source,
        steamClient: isSteamClientSoftware(item)
    )
}

private func softwareDisplaySummary(summary: String?, kind: String, source: String, steamClient: Bool) -> String {
    if let s = summary, !s.isEmpty, !isJunkAppBlurb(s) {
        let words = s.split(whereSeparator: \.isWhitespace)
        if source != "steam" || steamClient || words.count >= 4 {
            return s
        }
    }
    if kind == "formula" || source == "brew-formula" { return "Homebrew formula" }
    if source == "brew-cask" { return "Homebrew cask" }
    if source == "flatpak" { return "Flatpak app" }
    if source == "snap" { return "Snap app" }
    if source == "appimage" { return "AppImage" }
    if steamClient { return "Steam client" }
    if source == "steam" { return "Steam game" }
    if source == "crossover" { return "CrossOver bottle" }
    if kind == "app" { return "Installed application" }
    return "Installed software"
}
