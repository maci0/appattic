import Foundation

public final class ScanResult {
    public var scannedAt: Date
    public var durationS: Double
    public var apps: [AppRecord]
    public var dataItems: [DataItem]
    public var orphanAgents: [OrphanAgent]
    public var software: [Software]
    public var verdicts: [Verdict]
    public var brewAvailable: Bool
    public var outdated: [OutdatedPkg]
    public var packages: [PackageEntry]
    public var appsInstalled: Int
    /// A package check that could not run: the Homebrew query, any manager or
    /// store query below, or a package-manager listing that returned a failure
    /// status. The rest of the scan ran, so this is not "the scan was cut
    /// short": it gates scan-cache reuse and writes, so a cached scan is retried
    /// instead of serving an outdated or package list that is missing every
    /// entry the failed check would have reported.
    public var incomplete: Bool

    public init(
        scannedAt: Date = Date(),
        durationS: Double = 0,
        apps: [AppRecord] = [],
        dataItems: [DataItem] = [],
        orphanAgents: [OrphanAgent] = [],
        software: [Software] = [],
        verdicts: [Verdict] = [],
        brewAvailable: Bool = false,
        outdated: [OutdatedPkg] = [],
        packages: [PackageEntry] = [],
        appsInstalled: Int = 0,
        incomplete: Bool = false
    ) {
        self.scannedAt = scannedAt
        self.durationS = durationS
        self.apps = apps
        self.dataItems = dataItems
        self.orphanAgents = orphanAgents
        self.software = software
        self.verdicts = verdicts
        self.brewAvailable = brewAvailable
        self.outdated = outdated
        self.packages = packages
        self.appsInstalled = appsInstalled
        self.incomplete = incomplete
    }

    public var orphanedItems: [DataItem] {
        dataItems.filter { $0.isListedLeftover }
    }

    public func toScanData() -> ScanData {
        var orphanedCount = 0
        var orphanedBytes = 0
        var systemLeftoverBytes = 0
        for item in dataItems {
            if item.isListedLeftover {
                orphanedCount += 1
                orphanedBytes = addBytes(orphanedBytes, item.sizeBytes)
            } else if item.leftoverStatus == .system {
                systemLeftoverBytes = addBytes(systemLeftoverBytes, item.sizeBytes)
            }
        }
        var stale = 0
        var reclaimableBytes = orphanedBytes
        var verdictBySoftware: [ObjectIdentifier: Verdict] = [:]
        verdictBySoftware.reserveCapacity(verdicts.count)
        for verdict in verdicts {
            let id = ObjectIdentifier(verdict.software)
            if verdictBySoftware[id] == nil { verdictBySoftware[id] = verdict }
            if StaleTier.isSelectable(verdict.tierKind) { stale += 1 }
            if verdict.tierKind == .remove {
                reclaimableBytes = addBytes(
                    reclaimableBytes,
                    addBytes(verdict.software.sizeBytes, verdict.software.dataBytes)
                )
            }
        }
        return ScanData(
            scanned_at: isoString(scannedAt) ?? "",
            duration_s: (durationS * 10).rounded() / 10,
            brew_available: brewAvailable,
            totals: ScanTotals(
                apps_installed: apps.isEmpty ? appsInstalled : apps.count,
                orphaned_items: orphanedCount,
                orphaned_bytes: orphanedBytes,
                system_leftover_bytes: systemLeftoverBytes,
                reclaimable_bytes: reclaimableBytes,
                stale_apps: stale,
                outdated_apps: outdated.count
            ),
            leftovers: dataItems.map { $0.toLeftoverItem() },
            software: software.map { sw in
                let v = verdictBySoftware[ObjectIdentifier(sw)]
                return SoftwareItem(
                    name: sw.name,
                    kind: sw.kind,
                    path: sw.path,
                    source: sw.source,
                    version: sw.version,
                    size_bytes: sw.sizeBytes,
                    size_measured: sw.sizeMeasured,
                    data_bytes: sw.dataBytes,
                    data_paths: sw.dataPaths.isEmpty ? nil : sw.dataPaths,
                    last_used: isoString(sw.lastUsed),
                    installed_at: isoString(sw.installedAt),
                    usage_source: sw.usageSource,
                    running_service: sw.runningService,
                    tier: v?.tier,
                    reason: v?.reason,
                    cask_name: sw.caskName,
                    is_leaf: sw.isLeaf,
                    outdated: sw.outdated,
                    current_version: sw.version,
                    latest_version: sw.latestVersion,
                    summary: softwareDisplaySummary(sw),
                    steam_appid: sw.extra["steam_appid"],
                    pkg_id: sw.pkgId,
                    bundle_id: sw.bundleId
                )
            },
            outdated: outdated.map { $0.toEntry() },
            packages: packages,
            from_cache: false,
            incomplete: incomplete ? true : nil
        )
    }
}

public func applyPrefsFallback(_ apps: inout [AppRecord], items: [DataItem]) {
    var prefs: [String: Date] = [:]
    for i in items where i.rootLabel == "Preferences" {
        guard let mt = i.mtime else { continue }
        var bid = i.name.posixLowercased()
        if bid.hasSuffix(".plist") { bid = String(bid.dropLast(6)) }
        if let prev = prefs[bid], prev >= mt { continue }
        prefs[bid] = mt
    }
    for i in apps.indices {
        if apps[i].lastUsed != nil { continue }
        guard let bid = apps[i].bundleId else { continue }
        guard let dt = prefs[bid.posixLowercased()] else { continue }
        if let used = effectiveLastUsed(dt, apps[i].installedAt) {
            apps[i].lastUsed = used
            apps[i].lastUsedSource = "prefs-mtime"
        }
    }
}

/// Full scan. Optional collectors are for tests; omit them to hit the live system.
public func performScan(
    includeSystem: Bool = false,
    apps: [AppRecord]? = nil,
    brew: BrewSnapshot? = nil,
    leftoverItems: [DataItem]? = nil,
    leftoverAgents: [OrphanAgent]? = nil,
    leftoverRoots: [(String, String, String)]? = nil,
    linuxOutdated: [OutdatedPkg]? = nil,
    appStoreOutdated: [OutdatedPkg]? = nil,
    packages: [PackageEntry]? = nil,
    history: HistoryIndex? = nil,
    which: @escaping WhichFn = whichCommand,
    run: @escaping CommandRun = runCommand,
    skipLiveUsage: Bool = false,
    now: Date = Date(),
    clock: MonotonicFn = monotonicSeconds,
    progress: @escaping (String) -> Void = { _ in }
) -> ScanResult {
    let t0 = clock()
    let result = ScanResult(scannedAt: now)
    resetScanCheckFailures()

    progress("Scanning installed applications…")
    var found = apps ?? findApps(progress: progress)
    let leftoverApps = found
    if !includeSystem {
        found = found.filter { !$0.isSystem }
    }
    result.apps = found

    progress("Checking usage metadata…")
    if !skipLiveUsage {
        fillAppUsage(&result.apps, progress: progress, run: run, now: now)
    }

    let brewInfo = brew ?? collectBrew(progress: progress, which: which, run: run)
    result.brewAvailable = brewInfo.available

    progress("Checking for outdated packages…")
    let linuxPkgs = linuxOutdated ?? collectLinux(progress: progress, which: which, run: run)
    let masPkgs = appStoreOutdated ?? queryAppstore(result.apps, progress: progress, which: which, run: run)
    result.outdated = applyUntrustedCasks(brewInfo.outdated + linuxPkgs + masPkgs, refused: brewInfo.untrustedCasks)

    progress("Scanning for leftover data…")
    if let leftoverItems {
        result.dataItems = leftoverItems
        result.orphanAgents = leftoverAgents ?? []
    } else {
        let (items, agents) = scanLeftovers(
            apps: leftoverApps,
            brew: brewInfo,
            progress: progress,
            roots: leftoverRoots,
            now: now,
            clock: clock,
            run: run
        )
        result.dataItems = items
        result.orphanAgents = agents
    }

    applyLeftoverAppBlurbs(
        result.dataItems,
        brew: brewInfo,
        which: which,
        run: run,
        progress: progress
    )

    applyPrefsFallback(&result.apps, items: result.dataItems)

    progress("Building recommendations…")
    result.software = buildSoftware(
        apps: result.apps,
        brew: brewInfo,
        dataItems: result.dataItems,
        progress: progress,
        history: history,
        now: now
    )
    applyOutdated(result.software, pkgs: result.outdated)
    attachSummariesFromSoftware(result.software, pkgs: result.outdated)
    result.verdicts = evaluateAll(result.software, now: now)
    progress("Listing unused distro packages and language globals…")
    result.packages = packages ?? collectPackages(progress: progress, which: which, run: run)
    // A check that could not run is an unknown, not an empty list. It reaches
    // the scan cache through `incomplete`, so the next run retries instead of
    // serving "up to date" or "no orphans" for a day. Read after the package
    // collector, which reports its own failures here. Only the ones that were
    // actually attempted count: a manager that is not installed never failed.
    let failed = scanCheckFailures()
    if !failed.isEmpty {
        progress("  · check unavailable: \(failed.joined(separator: ", "))")
    }
    result.incomplete = brewInfo.outdatedFailed || !failed.isEmpty
    result.durationS = max(0, clock() - t0)
    return result
}

/// Live scan of leftovers, stale software, outdated packages, and unused distro/language packages.
public func runFullScan(
    includeSystem: Bool = false,
    now: Date = Date(),
    clock: MonotonicFn = monotonicSeconds,
    progress: @escaping (String) -> Void = { _ in }
) -> ScanData {
    performScan(includeSystem: includeSystem, now: now, clock: clock, progress: progress).toScanData()
}
