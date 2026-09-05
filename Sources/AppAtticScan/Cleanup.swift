import Foundation

public struct CleanupSelection: Equatable, Sendable {
    public var leftovers: Set<String>
    public var apps: Set<String>
    public var outdated: Set<String>
    public var packages: Set<String>
    public var markManual: Set<String>

    public init(
        leftovers: Set<String> = [],
        apps: Set<String> = [],
        outdated: Set<String> = [],
        packages: Set<String> = [],
        markManual: Set<String> = []
    ) {
        self.leftovers = leftovers
        self.apps = apps
        self.outdated = outdated
        self.packages = packages
        self.markManual = markManual
    }
}

/// UI can opt REVIEW and REMOVE into cleanup. CLI `--dry-run` for report/stale only emits REMOVE.
public let selectableCleanupTiers: Set<String> = ["remove", "review"]

public func pruneCleanupSelection(
    leftovers: Set<String>,
    apps: Set<String>,
    outdated: Set<String>,
    packages: Set<String> = [],
    markManual: Set<String> = [],
    data: ScanData,
    ignoring: Set<String>
) -> CleanupSelection {
    let leftoverPaths = Set(visibleOrphanedLeftovers(data.leftovers, ignoring: ignoring).map(\.path))
    let appPaths = Set(
        data.software.filter { selectableCleanupTiers.contains($0.tier ?? "") }.map(\.path)
    )
    let outdatedIds = Set((data.outdated ?? []).filter(\.updatable).map(\.id))
    let listed = data.packages ?? []
    let packageIds = Set(listed.map(\.id))
    let markIds = Set(listed.filter(\.canMarkManual).map(\.id))
    return CleanupSelection(
        leftovers: leftovers.intersection(leftoverPaths),
        apps: apps.intersection(appPaths),
        outdated: outdated.intersection(outdatedIds),
        packages: packages.intersection(packageIds),
        markManual: markManual.intersection(markIds)
    )
}

public func resolvedSelection(_ selected: String?, visibleIds: [String]) -> String? {
    if let selected, visibleIds.contains(selected) { return selected }
    return visibleIds.first
}

public func toggleListedSelection(selected: Set<String>, visible: [String]) -> Set<String> {
    let vis = Set(visible)
    if vis.isEmpty { return selected }
    if vis.isSubset(of: selected) { return [] }
    return selected.union(vis)
}

public func isSteamManagedPath(_ path: String) -> Bool {
    let p = path.lowercased()
    return p.contains("/steamapps/") || p.contains("/steam.appbundle/")
}

public func steamUninstallCommand(appId: String) -> String {
    let uri = "steam://uninstall/\(appId)"
    if PlatformOverride.isLinux {
        return "steam \(shellQuote(uri))"
    }
    return "open \(shellQuote(uri))"
}

public func uninstallCommand(
    source: String,
    name: String,
    path: String,
    caskName: String?,
    steamAppId: String?,
    pkgId: String? = nil
) -> String {
    if source == "brew-formula" {
        let q = shellQuote(name)
        return "if brew list --formula \(q) >/dev/null 2>&1; then brew uninstall \(q); fi"
    }
    if source == "brew-cask" {
        let q = shellQuote(caskName ?? name)
        return "if brew list --cask \(q) >/dev/null 2>&1; then brew uninstall --cask \(q); fi"
    }
    if source == "flatpak" {
        return "flatpak uninstall -y \(shellQuote(linuxUninstallId(source: source, path: path, pkgId: pkgId)))"
    }
    if source == "snap" {
        return "snap remove \(shellQuote(linuxUninstallId(source: source, path: path, pkgId: pkgId)))"
    }
    if source == "appimage" {
        if isProtectedPackagedPath(path) {
            return "# skipped packaged path \(shellQuote(path))"
        }
        return "rm -rf \(shellQuote(path))"
    }
    if source == "steam", let id = steamAppId, !id.isEmpty, !isCrossOverPath(path) {
        return steamUninstallCommand(appId: id)
    }
    if source == "crossover" {
        return crossoverDeleteCommand(bottleName: name)
    }
    if isCrossOverPath(path) {
        return "# \(name): uninstall from CrossOver. Do not delete \(path)"
    }
    if source == "steam" || isSteamManagedPath(path) {
        return "# \(name): uninstall from Steam. Do not delete \(path)"
    }
    if isProtectedPackagedPath(path) {
        return "# skipped packaged path \(shellQuote(path))"
    }
    return "rm -rf \(shellQuote(path))"
}

public func commandFailureMessage(
    status: Int32,
    stderr: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path
) -> String {
    let trimmed = redactHomePaths(
        stderr.trimmingCharacters(in: .whitespacesAndNewlines),
        home: home
    )
    if trimmed.isEmpty {
        return "Command failed (exit \(status)). Selection kept."
    }
    let detail = trimmed.count > 400 ? String(trimmed.prefix(400)) : trimmed
    return "Command failed (exit \(status)). \(detail)"
}

public func scriptHasActionableCommands(_ script: String) -> Bool {
    for raw in script.split(whereSeparator: \.isNewline) {
        let line = String(raw).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") { continue }
        if line == "set -e" || line.hasPrefix("set -") { continue }
        return true
    }
    return false
}

public func stripShellHeader(_ script: String) -> String {
    var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let first = lines.first {
        let line = first.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#!") || line.hasPrefix("#") || line == "set -e" || line.hasPrefix("set -") {
            lines.removeFirst()
            continue
        }
        break
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

func isShellPreamble(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return true }
    if t.hasPrefix("#!") { return true }
    if t == "set -e" || t.hasPrefix("set -") { return true }
    if t.hasPrefix("# AppAttic") { return true }
    if t.hasPrefix("# Review every path") { return true }
    if t.hasPrefix("# Update section") { return true }
    return false
}

func stripShellPreambleOnly(_ script: String) -> String {
    var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let first = lines.first, isShellPreamble(first) {
        lines.removeFirst()
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

public func previewScript(cleanup: String, update: String) -> String {
    let hasClean = scriptHasActionableCommands(cleanup)
    let hasUpdate = scriptHasActionableCommands(update)
    let cleanupNotes = stripShellPreambleOnly(cleanup).trimmingCharacters(in: .whitespacesAndNewlines)
    let hasCleanupContent = hasClean || !cleanupNotes.isEmpty
    func terminated(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
    if hasCleanupContent && hasUpdate {
        var body = cleanup
        while body.hasSuffix("\n") { body.removeLast() }
        let extra = stripShellHeader(update)
        if extra.isEmpty { return terminated(cleanup) }
        return body + "\n\n# Update section. Delete in the UI does not run these lines.\n" + extra + "\n"
    }
    if hasUpdate { return terminated(update) }
    return terminated(cleanup)
}

func commentedOutdatedLines(_ pkgs: [OutdatedPkg]) -> [String] {
    pkgs.map { pkg in
        let quoted = shellQuote(pkg.name)
        switch pkg.manager {
        case "brew-formula":
            return "# brew upgrade \(quoted)"
        case "brew-cask":
            return "# brew upgrade --cask \(quoted)"
        case "flatpak":
            return "# flatpak update \(quoted)"
        case "snap":
            return "# snap refresh \(quoted)"
        case "apt":
            return "# apt install --only-upgrade \(quoted)"
        case "pacman":
            return "# pacman -S \(quoted)"
        case "dnf":
            return "# dnf upgrade \(quoted)"
        case "zypper":
            return "# zypper update \(quoted)"
        case "app-store":
            return "# App Store: \(quoted)"
        default:
            return "# \(pkg.manager) \(quoted)"
        }
    }
}

public func outdatedReportScript(_ pkgs: [OutdatedPkg], scannedAt: Date) -> String {
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic outdated report generated \(scriptStamp(scannedAt))",
        "# Report only. These upgrades are not run. Use update --dry-run to review a live script.",
    ]
    if pkgs.isEmpty {
        lines.append("")
        lines.append("# No outdated packages.")
    } else {
        lines.append("")
        lines.append(contentsOf: commentedOutdatedLines(pkgs))
    }
    return lines.joined(separator: "\n") + "\n"
}

func linuxUninstallId(source: String, path: String, pkgId: String?) -> String {
    if let pkgId, !pkgId.isEmpty { return pkgId }
    let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return linuxPkgId(source: source, desktopId: base, exec: "")
}

/// Packaged OS prefixes that leftover/uninstall scripts must not `rm`.
/// Matches Qt `isProtectedPackagedPath`, plus `/etc` `/System` `/Library` and kernel roots.
public func isProtectedPackagedPath(_ path: String) -> Bool {
    if path.isEmpty { return false }
    let roots = [
        "/usr", "/bin", "/sbin", "/etc", "/System", "/lib", "/lib64",
        "/boot", "/dev", "/proc", "/sys", "/private", "/Library",
    ]
    return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
}

public func leftoverRemoveCommand(path: String, rootLabel: String, extraPaths: [String] = []) -> String {
    if rootLabel == "LaunchAgents" {
        if isProtectedPackagedPath(path) {
            return "# skipped packaged path \(shellQuote(path))"
        }
        let q = shellQuote(path)
        return "launchctl bootout gui/$(id -u) \(q) 2>/dev/null || true\nrm -rf \(q)"
    }
    var seen = Set<String>()
    let paths = ([path] + extraPaths).filter { seen.insert($0).inserted && !isProtectedPackagedPath($0) }
    if paths.isEmpty {
        return "# skipped packaged path \(shellQuote(path))"
    }
    return "rm -rf " + paths.map(shellQuote).joined(separator: " ")
}

public func leftoverRemoveCommand(for item: LeftoverItem) -> String {
    leftoverRemoveCommand(path: item.path, rootLabel: item.root, extraPaths: item.extra_paths ?? [])
}

public func uninstallCommand(for item: SoftwareItem) -> String {
    uninstallCommand(
        source: item.source,
        name: item.name,
        path: item.path,
        caskName: item.cask_name,
        steamAppId: item.steam_appid,
        pkgId: item.pkg_id
    )
}

func scriptStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = TimeZone.current
    return f.string(from: date)
}

func leftoverDryRunItems(_ result: ScanResult, category: [String], top: Int?) -> [DataItem] {
    var orphans = result.orphanedItems.sorted { $0.sizeBytes > $1.sizeBytes }
    if !category.isEmpty {
        orphans = orphans.filter { leftoverMatchesCategory($0, categories: category) }
    }
    if let top {
        orphans = Array(orphans.prefix(max(0, top)))
    }
    return orphans
}

func appendLeftoverCommands(_ lines: inout [String], items: [DataItem]) {
    guard !items.isEmpty else { return }
    lines.append("")
    lines.append("# Leftover data and PATH overlays")
    for i in items {
        lines.append(leftoverRemoveCommand(path: i.path, rootLabel: i.rootLabel, extraPaths: i.extraPaths))
    }
}

func appendRemoveVerdicts(_ lines: inout [String], result: ScanResult) {
    for v in result.verdicts where v.tier == "remove" {
        let s = v.software
        lines.append("")
        lines.append("# \(s.name) (\(s.source)) not used for a long time")
        lines.append(uninstallCommand(
            source: s.source,
            name: s.name,
            path: s.path,
            caskName: s.caskName,
            steamAppId: s.extra["steam_appid"],
            pkgId: s.pkgId
        ))
        if s.dataBytes > 0 {
            lines.append("# (its user data, if any, is listed in the report)")
        }
    }
}

func leftoverCleanupScript(_ items: [DataItem], scannedAt: Date) -> String {
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic leftover cleanup script generated \(scriptStamp(scannedAt))",
        "# Review every path before running. Nothing here is deleted automatically.",
    ]
    if items.isEmpty {
        lines.append("")
        lines.append("# No leftover data matched.")
    } else {
        appendLeftoverCommands(&lines, items: items)
    }
    return lines.joined(separator: "\n") + "\n"
}

func staleCleanupScript(_ result: ScanResult) -> String {
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic stale uninstall script generated \(scriptStamp(result.scannedAt))",
        "# Review every path before running. Nothing here is deleted automatically.",
    ]
    let before = lines.count
    appendRemoveVerdicts(&lines, result: result)
    if lines.count == before {
        lines.append("")
        lines.append("# No remove-tier unused software.")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Printable `/bin/sh` for this CLI command. `outdated` is commented report-only; `update` is live Homebrew/Flatpak.
/// `report` / `leftovers` / `stale` emit leftovers and REMOVE-tier uninstalls, not packages.
public func dryRunScript(
    command: String,
    result: ScanResult,
    category: [String] = [],
    top: Int? = nil,
    leftoversOnly: Bool = false,
    staleOnly: Bool = false
) -> String {
    switch command {
    case "leftovers":
        return leftoverCleanupScript(
            leftoverDryRunItems(result, category: category, top: top),
            scannedAt: result.scannedAt
        )
    case "stale":
        return staleCleanupScript(result)
    case "outdated":
        return outdatedReportScript(result.outdated, scannedAt: result.scannedAt)
    case "packages":
        return packageActionScript(remove: result.packages, markManual: [])
    case "update":
        return updateScript(result.outdated)
    default:
        if leftoversOnly && !staleOnly {
            return leftoverCleanupScript(
                leftoverDryRunItems(result, category: category, top: top),
                scannedAt: result.scannedAt
            )
        }
        if staleOnly && !leftoversOnly {
            return staleCleanupScript(result)
        }
        return cleanupScript(result, category: category, top: top)
    }
}

public func cleanupScript(_ result: ScanResult, category: [String] = [], top: Int? = nil) -> String {
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic cleanup script generated \(scriptStamp(result.scannedAt))",
        "# Review every path before running. Nothing here is deleted automatically.",
    ]
    appendLeftoverCommands(&lines, items: leftoverDryRunItems(result, category: category, top: top))
    appendRemoveVerdicts(&lines, result: result)
    if !result.outdated.isEmpty {
        lines.append("")
        lines.append("# Outdated packages (report only; not run)")
        lines.append(contentsOf: commentedOutdatedLines(result.outdated))
    }
    return lines.joined(separator: "\n") + "\n"
}

public func scanResult(from data: ScanData, ignoringLeftovers: Set<String> = [], now: Date = Date()) -> ScanResult {
    let result = ScanResult()
    result.scannedAt = parseISODate(data.scanned_at) ?? now
    result.durationS = data.duration_s
    result.brewAvailable = data.brew_available
    result.incomplete = data.incomplete == true
    result.appsInstalled = data.totals.apps_installed
    let ignoredKeys = Set(ignoringLeftovers.map(pathIdentityKey))
    result.dataItems = data.leftovers.compactMap { item in
        if leftoverIgnorePaths(item).contains(where: { ignoredKeys.contains(pathIdentityKey($0)) }) { return nil }
        return DataItem(
            path: item.path,
            name: item.name,
            rootLabel: item.root,
            kind: item.kind,
            status: item.status,
            owner: item.owner,
            shadows: item.shadows,
            sizeBytes: item.size_bytes ?? 0,
            sizeMeasured: item.size_measured,
            mtime: parseISODate(item.mtime),
            reason: item.reason,
            summary: item.summary,
            extraPaths: item.extra_paths ?? []
        )
    }
    result.software = data.software.map { item in
        var extra: [String: String] = [:]
        if let id = item.steam_appid, !id.isEmpty {
            extra["steam_appid"] = id
        } else if item.source == "steam", item.name.compare("Steam", options: .caseInsensitive) == .orderedSame {
            extra["steam_client"] = "1"
        }
        if item.source == "crossover" {
            extra["crossover_bottle"] = "1"
        }
        return Software(
            name: item.name,
            kind: item.kind,
            path: item.path,
            source: item.source,
            sizeBytes: item.size_bytes ?? 0,
            sizeMeasured: item.size_measured ?? true,
            lastUsed: parseISODate(item.last_used),
            usageSource: item.usage_source,
            installedAt: parseISODate(item.installed_at),
            dataBytes: item.data_bytes ?? 0,
            dataPaths: item.data_paths ?? [],
            runningService: item.running_service ?? false,
            version: item.version ?? item.current_version,
            caskName: item.cask_name,
            isLeaf: item.is_leaf ?? true,
            outdated: item.outdated ?? false,
            latestVersion: item.latest_version,
            pkgId: item.pkg_id,
            bundleId: item.bundle_id,
            summary: item.summary,
            extra: extra
        )
    }
    result.verdicts = zip(result.software, data.software).map { sw, item in
        Verdict(software: sw, tier: item.tier ?? "", reason: item.reason ?? "")
    }
    result.outdated = (data.outdated ?? []).map {
        OutdatedPkg(
            name: $0.name,
            manager: $0.manager,
            currentVersion: $0.current_version,
            latestVersion: $0.latest_version,
            title: $0.title,
            summary: $0.summary,
            reason: $0.reason,
            kind: $0.kind,
            bundleId: $0.bundle_id
        )
    }
    result.packages = data.packages ?? []
    return result
}

public func isHandoffUninstallCommand(_ command: String) -> Bool {
    command.contains("steam://uninstall")
}

public func remainingPendingAppPaths(selected: Set<String>, software: [SoftwareItem]) -> Set<String> {
    Set(software.compactMap { item in
        guard selected.contains(item.path) else { return nil }
        let cmd = uninstallCommand(for: item)
        if isHandoffUninstallCommand(cmd) { return item.path }
        if scriptHasActionableCommands("#!/bin/sh\nset -e\n\(cmd)\n") { return nil }
        return item.path
    })
}

public func cleanupScript(from data: ScanData, ignoringLeftovers: Set<String> = [], now: Date = Date()) -> String {
    cleanupScript(scanResult(from: data, ignoringLeftovers: ignoringLeftovers, now: now))
}

public func exportedScanData(
    from data: ScanData,
    ignoringLeftovers: Set<String> = [],
    fromCache: Bool = false,
    now: Date = Date()
) -> ScanData {
    var payload = scanResult(from: data, ignoringLeftovers: ignoringLeftovers, now: now).toScanData()
    payload.from_cache = fromCache
    return payload
}
