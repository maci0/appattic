import Foundation

/// The live scan, kept as the objects the collectors produced. `runFullScan`
/// hands back the `ScanData` form of this, which `toScanData()` builds; a
/// caller that wants the leftover, software, and verdict objects themselves
/// asks `performScan` for them directly.
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
    /// A check that ran and failed: the Homebrew update query, any manager or
    /// store update query, or a package listing. The rest of the scan ran, so
    /// this is not "the scan was cut short": it gates scan-cache reuse and
    /// writes, so a cached scan is retried instead of serving an outdated or
    /// unused-package list that is missing everything the failed check would
    /// have reported.
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

    /// Seconds for the report: one decimal, never negative, never non-finite.
    ///
    /// `JSON` has no spelling for an infinity or a NaN, and `JSONEncoder`
    /// throws `EncodingError.invalidValue` rather than writing one, so a
    /// non-finite duration fails the whole `--json` report instead of printing
    /// a duration. The freshly measured value is clamped where it is taken
    /// (`performScan`), and `scanResult(from:)` clamps the `duration_s` it
    /// decodes from `last-scan.json` the same way, so a `1e999` or a negative
    /// in that file reads as 0 rather than reaching the UI as an infinity or as
    /// "-3.5s" for a scan that took no time at all.
    func reportDuration() -> Double {
        guard durationS.isFinite, durationS > 0 else { return 0 }
        return (durationS * 10).rounded() / 10
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
            duration_s: reportDuration(),
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
                    bundle_id: sw.bundleId,
                    data_measured: sw.dataMeasured
                )
            },
            outdated: outdated.map { $0.toEntry() },
            packages: packages,
            from_cache: false,
            incomplete: incomplete ? true : nil
        )
    }
}

/// Give an app with no last-used evidence the mtime of its own preferences
/// file, tagged `"prefs-mtime"`. Apps that already have a `lastUsed` are left
/// alone, and a preferences mtime within `indexWindowS` of the install date is
/// discarded by `effectiveLastUsed` rather than reported as use.
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

/// A scan resets and reads the process-global `failedCheckSources` set and
/// stamps the single scan cache file. Two scans in one process interleave both, so one
/// scan's failures are attributed to the other and a cache commit can mix
/// them. One scan at a time, enforced here rather than left to each caller. The
/// lock is not recursive, so a `progress` callback must not start a scan: it
/// would block forever on the scan already in flight.
private let scanLock = NSLock()

/// Serialises `progress`. Collectors emit from `pmap` worker threads (up to 16
/// in a full scan), so without this the callback runs on many threads at once
/// and any state behind it (a progress label, a counter) is read and written
/// unsynchronised.
/// The lock is held across the emit: a callback that called back into a
/// collector would deadlock on it, which is why `emit` must not be reentrant.
private final class SerialProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (String) -> Void

    init(_ emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    func callAsFunction(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        emit(message)
    }
}

/// Full scan, returning the live objects instead of the `ScanData` form.
///
/// The `apps`, `brew`, `leftoverItems`, `leftoverAgents`, `leftoverRoots`,
/// `linuxOutdated`, `appStoreOutdated`, `packages`, and `history` parameters
/// are the collectors: leave one nil to run it against the system, pass a value
/// to supply it. That is the seam a consumer's tests use, so a scan can run
/// from fixtures with no live package manager, Spotlight, or home directory.
/// `which` and `run` replace every subprocess. `skipLiveUsage` leaves the
/// usage probes out, and `clock` replaces the monotonic clock that times the
/// scan, so both are testable.
///
/// The same one-scan-at-a-time rule as `runFullScan` applies: the lock is not
/// reentrant, and a `progress` callback must not start another scan.
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
    progress: @escaping @Sendable (String) -> Void = { _ in }
) -> ScanResult {
    scanLock.lock()
    defer { scanLock.unlock() }
    let serialProgress = SerialProgress(progress)
    // Every collector below takes `(String) -> Void`, so shadowing the
    // parameter here routes all of them, and their `pmap` workers, through the
    // serialising wrapper.
    let progress = serialProgress.callAsFunction
    let t0 = clock()
    let result = ScanResult(scannedAt: now)
    resetScanCheckFailures()
    // The `whichCommand` search list holds PATH and the installed nvm
    // versions as of the last time it was built, and a long lived UI has run
    // scans since. Every collector below resolves its tool through it, so a
    // list from launch is a scan that misses what was installed since.
    resetWhichSearchDirectories()

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
    // A check that ran and failed is an unknown, not an empty list. It reaches
    // the scan cache through `incomplete`, so the next run retries instead of
    // serving "up to date", or "no unused packages", for a day. Read after
    // every check has run, update and package listing alike. Only the ones that
    // were actually attempted count: a tool that is not installed never failed.
    let failed = scanCheckFailures()
    if !failed.isEmpty {
        progress("  · check unavailable: \(failed.joined(separator: ", "))")
    }
    result.incomplete = brewInfo.outdatedFailed || !failed.isEmpty
    result.durationS = max(0, clock() - t0)
    return result
}

/// Live scan of leftovers, stale software, outdated packages, and unused distro/language packages.
///
/// One scan at a time per process. A scan resets and reads a process-global
/// failed-check set, so two overlapping scans attribute each other's failures.
/// The wait is not reentrant: a `progress` callback must not start a scan, or
/// it blocks on the scan already in flight. The callback runs on collector
/// worker threads, serialized but not moved to your thread, so anything it
/// touches needs its own lock.
public func runFullScan(
    includeSystem: Bool = false,
    now: Date = Date(),
    clock: MonotonicFn = monotonicSeconds,
    progress: @escaping @Sendable (String) -> Void = { _ in }
) -> ScanData {
    performScan(includeSystem: includeSystem, now: now, clock: clock, progress: progress).toScanData()
}
