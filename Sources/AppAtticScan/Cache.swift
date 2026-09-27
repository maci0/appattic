import Foundation

/// Max age before a fingerprint-matching cache is treated as stale (24 hours).
public let scanCacheMaxAge: TimeInterval = 24 * 3600

/// Ceiling on the snapshot file, checked before it is read. The snapshot is a
/// whole-inventory JSON, so its size scales with the number of leftovers and
/// software rows: a home in the tens of thousands of rows is a few megabytes,
/// and a few hundred thousand is still well inside this. Nothing a scan writes
/// reaches it. A file past the ceiling is not a snapshot (a truncated write, a
/// full disk, something else parked at that path), and reading it would pull
/// the whole thing into memory before the decoder could reject it.
public let scanCacheMaxBytes: Int = 256 * 1024 * 1024

public struct ScanCacheFile: Codable, Sendable {
    public var fingerprint: String
    public var includeSystem: Bool
    public var data: ScanData

    public init(fingerprint: String, includeSystem: Bool, data: ScanData) {
        self.fingerprint = fingerprint
        self.includeSystem = includeSystem
        self.data = data
    }
}

/// Where the scan cache lives: `last-scan.json` beside `settings.json`, under
/// the XDG data directory on Linux and Application Support on macOS. Every
/// cache function defaults to this path, so a caller only passes a URL when it
/// keeps its own cache somewhere else.
public func defaultScanCacheURL() -> URL {
    let fm = FileManager.default
    let base: URL
    if PlatformOverride.isLinux {
        let xdg = xdgDataHome()
        base = URL(fileURLWithPath: xdg).appendingPathComponent("appattic", isDirectory: true)
    } else {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        base = support.appendingPathComponent("AppAttic", isDirectory: true)
    }
    return base.appendingPathComponent("last-scan.json")
}

/// Swallow read/decode errors, and delete a file that decodes to nothing: it is
/// read in full and rejected on every launch until a scan overwrites it, and a
/// machine whose scans keep failing leaves it on disk holding the account's
/// own paths. A missing or unreadable file is not corrupt, so it stays.
/// Prefer `readScanCache` when the caller must report which it hit.
public func loadScanCache(from url: URL = defaultScanCacheURL()) -> ScanCacheFile? {
    do {
        return try readScanCache(from: url)
    } catch AppAtticIOError.decodeFailed {
        clearScanCache(at: url)
        return nil
    } catch {
        return nil
    }
}

public func readScanCache(
    from url: URL = defaultScanCacheURL(),
    maxBytes: Int = scanCacheMaxBytes
) throws -> ScanCacheFile {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    if let size = (attrs?[.size] as? Int), size > maxBytes {
        throw AppAtticIOError.readFailed(
            path: url.path,
            message: "cache file is \(size) bytes, past the \(maxBytes) byte bound"
        )
    }
    let raw: Data
    do {
        raw = try Data(contentsOf: url)
    } catch {
        throw AppAtticIOError.readFailed(path: url.path, message: error.localizedDescription)
    }
    do {
        return try JSONDecoder().decode(ScanCacheFile.self, from: raw)
    } catch {
        throw AppAtticIOError.decodeFailed(path: url.path, message: error.localizedDescription)
    }
}

/// Write the cache, creating its directory and restricting the file to the
/// account. The write is atomic and `from_cache` is forced to false, so what
/// lands on disk is a live snapshot whatever the caller had set. Throws
/// `AppAtticIOError` for every failure; a cache that is never written is a
/// rescan, not a wrong answer.
public func writeScanCache(_ cache: ScanCacheFile, to url: URL = defaultScanCacheURL()) throws {
    let dir = url.deletingLastPathComponent()
    do {
        try prepareStateDirectory(dir)
    } catch {
        throw AppAtticIOError.createDirectoryFailed(path: dir.path, message: error.localizedDescription)
    }
    var copy = cache
    copy.data.from_cache = false
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let raw: Data
    do {
        raw = try encoder.encode(copy)
    } catch {
        throw AppAtticIOError.encodeFailed(message: error.localizedDescription)
    }
    do {
        // cordis-boundary: emission. The scan cache is the app's own state file
        // and the sole writer, so an atomic overwrite is the commit; there is no
        // inverse to hold (a stale cache only costs a rescan).
        //
        // `writeOwnerOnlyFile`, not `write(to:options:.atomic)` plus a chmod
        // after it: the snapshot is every app path and every leftover path
        // under the home directory, and the atomic rename publishes the file at
        // the umask default before the mode is narrowed. That window is closed
        // by `prepareStateDirectory` only for the app's own state directory, and
        // a caller-supplied `to:` can name any parent. mkstemp creates at
        // `0600`, so there is no window at any destination.
        try writeOwnerOnlyFile(raw, to: url)
    } catch {
        throw AppAtticIOError.writeFailed(path: url.path, message: error.localizedDescription)
    }
}

/// True when the snapshot carries no usable timestamp, a timestamp in the
/// future, or one older than `maxAge`. Age alone, so a caller that cannot pay
/// for an inventory stamp still enforces the same bound.
public func isScanCacheExpired(
    _ cache: ScanCacheFile,
    now: Date = Date(),
    maxAge: TimeInterval = scanCacheMaxAge
) -> Bool {
    guard let when = parseISODate(cache.data.scanned_at) else { return true }
    let age = now.timeIntervalSince(when)
    return age < 0 || age > maxAge
}

/// True when the cached scan is marked incomplete, or when includeSystem,
/// fingerprint, or age (default 24h) no longer match.
public func isScanCacheStale(
    _ cache: ScanCacheFile,
    includeSystem: Bool,
    fingerprint: String,
    now: Date = Date(),
    maxAge: TimeInterval = scanCacheMaxAge
) -> Bool {
    if cache.data.incomplete == true { return true }
    if cache.includeSystem != includeSystem { return true }
    if cache.fingerprint != fingerprint { return true }
    return isScanCacheExpired(cache, now: now, maxAge: maxAge)
}

/// Remove the stored snapshot. True when a file was there and is now gone.
///
/// A removal that failed is false, not a silent success: the snapshot is a full
/// inventory of the account's paths, and a caller that tells the user it is off
/// the disk while it is still there is worse than one that says the removal did
/// not land. Nothing was there to delete, so that is false too, never a failure.
@discardableResult
public func clearScanCache(at url: URL = defaultScanCacheURL()) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        return false
    }
    return true
}

/// Delete the stored snapshot on request, whatever its age, and report whether
/// a file was there to delete.
///
/// Age already drops a snapshot past `scanCacheMaxAge`, and a run that changes
/// the machine drops it after it acts. Neither is a deletion the user asked
/// for: this is the one that takes the account's own paths off the disk now,
/// so it does not read the snapshot first (reading it is what would put the
/// paths back in memory to decide whether they may go) and it treats absent as
/// the wanted state. A removal that fails throws, because a snapshot that
/// survived the erase is not an erased snapshot.
@discardableResult
public func eraseScanCache(at url: URL = defaultScanCacheURL()) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        throw AppAtticIOError.writeFailed(path: url.path, message: error.localizedDescription)
    }
    return true
}

/// What an erase did, as the `--json` payload: the snapshot's own path, and
/// whether one was there to delete. `erased: false` is a snapshot that was
/// already gone, not a failure.
public struct EraseResult: Codable, Sendable {
    public let path: String
    public let erased: Bool

    public init(path: String, erased: Bool) {
        self.path = path
        self.erased = erased
    }
}

/// Delete a snapshot past the retention bound, and report whether it did.
///
/// The file is a full inventory of the account: every app path, every leftover
/// path under the home directory. Past `maxAge` no run serves it, so leaving it
/// on disk keeps the account's own paths around for a snapshot that is never
/// read again. Only age is a reason: a snapshot whose fingerprint no longer
/// matches is one rescan from usable, and it is the only copy left when a scan
/// races an install and `commitScanCache` refuses to write over it.
///
/// False covers both "not expired" and "the removal did not land"; either way
/// the snapshot is still on disk, which is what a caller has to know.
@discardableResult
public func deleteExpiredScanCache(
    _ cache: ScanCacheFile,
    now: Date = Date(),
    maxAge: TimeInterval = scanCacheMaxAge,
    at url: URL = defaultScanCacheURL()
) -> Bool {
    guard isScanCacheExpired(cache, now: now, maxAge: maxAge) else { return false }
    return clearScanCache(at: url)
}

/// Save only when the inventory stamp is unchanged across the scan and the
/// result is complete. Otherwise a later hit would serve a mixed snapshot.
/// `false` means the scan was dropped on purpose; a write that failed throws,
/// because a scan that never reached disk is not the same as one that was
/// deliberately not kept.
@discardableResult
public func commitScanCache(
    includeSystem: Bool,
    data: ScanData,
    before: String,
    after: String,
    to url: URL = defaultScanCacheURL()
) throws -> Bool {
    if data.incomplete == true { return false }
    guard before == after else { return false }
    try writeScanCache(
        ScanCacheFile(fingerprint: after, includeSystem: includeSystem, data: data),
        to: url
    )
    return true
}

/// Inventory stamp for cache invalidation: apps, brew lists, leftover roots, and package-manager state.
/// Changing evaluator version (`eval:`) or packages collector version (`packages:`) also busts the cache.
public func scanFingerprint(
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> String {
    var lines: [String] = ["ver:\(appAtticVersion)", "eval:20", "packages:1"]
    if PlatformOverride.isLinux {
        for dir in linuxDesktopDirs() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let desktops = names.filter { $0.hasSuffix(".desktop") }.sorted()
            if !desktops.isEmpty {
                lines.append("desk:\(stampEscape(dir)):\(stampJoin(desktops.map { inventoryEntryStamp(dir: dir, name: $0) }))")
            }
        }
    } else {
        let homeApps = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Applications")
        for root in ["/Applications", homeApps] {
            let names = iterApps(in: root).map {
                inventoryEntryStamp(
                    dir: URL(fileURLWithPath: $0).deletingLastPathComponent().path,
                    name: URL(fileURLWithPath: $0).lastPathComponent
                )
            }.sorted()
            lines.append("apps:\(stampEscape(root)):\(stampJoin(names))")
        }
    }
    if let brew = which("brew") {
        let (_, formulas, _) = run([brew, "list", "--formula", "--versions"], 30)
        let (_, casks, _) = run([brew, "list", "--cask", "--versions"], 30)
        lines.append("brew-f:\(stampEscape(formulas.trimmingCharacters(in: .whitespacesAndNewlines)))")
        lines.append("brew-c:\(stampEscape(casks.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
    let steam = steamManifestStamp()
    if !steam.isEmpty {
        lines.append(steam)
    }
    let cx = crossoverBottleStamp()
    if !cx.isEmpty {
        lines.append(cx)
    }
    if which("wine") != nil { lines.append("path:wine") }
    if which("docker") != nil { lines.append("path:docker") }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var toolDirs: [(String, String)] = [
        ("localbin", (home as NSString).appendingPathComponent(".local/bin")),
        ("homebin", (home as NSString).appendingPathComponent("bin")),
        ("usrlocalbin", "/usr/local/bin"),
        ("homebrewbin", "/opt/homebrew/bin"),
        ("linuxbrewbin", "/home/linuxbrew/.linuxbrew/bin"),
        ("launchagents", ((home as NSString).appendingPathComponent("Library") as NSString).appendingPathComponent("LaunchAgents")),
    ]
    if let brew = which("brew") {
        let brewBin = URL(fileURLWithPath: brew).deletingLastPathComponent().path
        if !toolDirs.contains(where: { $0.1 == brewBin }) {
            toolDirs.append(("brewbin", brewBin))
        }
    }
    lines.append(contentsOf: userToolDirStamps(toolDirs))
    let android = androidSdkStamp()
    if !android.isEmpty {
        lines.append(android)
    }
    for (label, path, _) in scanRootsForPlatform() {
        lines.append(rootInventoryStamp(label, path))
    }
    for (path, _) in homeDataLeaves() {
        let name = URL(fileURLWithPath: path).lastPathComponent
        lines.append(rootInventoryStamp("home-\(name)", path))
    }
    if PlatformOverride.isDarwin {
        lines.append(rootInventoryStamp("launchagents-system", "/Library/LaunchAgents"))
    }
    let homeShare = FileManager.default.homeDirectoryForCurrentUser.path
    for (label, path) in linuxPkgStampPaths(home: homeShare) {
        let line = pathMtimeStamp(label, path)
        if !line.isEmpty { lines.append(line) }
    }
    if let mas = which("mas") {
        let (_, out, _) = run([mas, "list"], 30)
        lines.append("mas:\(stampEscape(out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
    return lines.joined(separator: "\n")
}

public func linuxPkgStampPaths(
    home: String,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [(String, String)] {
    let data = xdgDataHome(home: home, env: env)
    return [
        ("flatpak-user", (data as NSString).appendingPathComponent("flatpak")),
        ("flatpak-system", "/var/lib/flatpak"),
        ("snap", "/var/lib/snapd"),
        ("dpkg", "/var/lib/dpkg/status"),
        ("pacman", "/var/lib/pacman/local"),
        ("dnf", "/var/lib/dnf"),
        ("rpm", "/var/lib/rpm"),
        ("zypp", "/var/lib/zypp"),
    ]
}

func stampEscape(_ s: String) -> String {
    // Runs of ordinary characters are appended as slices; only the handful of
    // separators are paid for individually. Appending every Character in turn
    // rebuilt the string once per input character, over every formula and cask
    // line of a `brew list` stamp.
    var out = ""
    out.reserveCapacity(s.count)
    var runStart = s.startIndex
    var i = s.startIndex
    while i < s.endIndex {
        let escaped: String
        switch s[i] {
        case "\\": escaped = "\\\\"
        case ",": escaped = "\\,"
        case "\n": escaped = "\\n"
        case "\r": escaped = "\\r"
        default:
            i = s.index(after: i)
            continue
        }
        if runStart < i { out += s[runStart..<i] }
        out += escaped
        i = s.index(after: i)
        runStart = i
    }
    if runStart < s.endIndex { out += s[runStart...] }
    return out
}

func stampJoin(_ names: [String]) -> String {
    names.map(stampEscape).joined(separator: ",")
}

func rootInventoryStamp(_ label: String, _ path: String) -> String {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return "root:\(stampEscape(label)):missing"
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    let ents = stampJoin(names.filter { !$0.hasPrefix(".") }.sorted())
    return "root:\(stampEscape(label)):\(ents)"
}

func dirNameStamp(_ label: String, _ dir: String) -> String {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return "" }
    let ents = stampJoin(names.filter { !$0.hasPrefix(".") }.sorted().map { stampName(dir: dir, name: $0) })
    if ents.isEmpty { return "" }
    return "\(stampEscape(label)):\(ents)"
}

func stampName(dir: String, name: String) -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return name }
    let resolved = dest.hasPrefix("/") ? dest : (dir as NSString).appendingPathComponent(dest)
    if FileManager.default.fileExists(atPath: resolved) { return name }
    return name + "?"
}

func inventoryEntryStamp(dir: String, name: String) -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date
    else { return name }
    return "\(name.replacingOccurrences(of: "@", with: "\\@"))@\(mtime.timeIntervalSince1970.bitPattern)"
}

func pathMtimeStamp(_ label: String, _ path: String) -> String {
    // One `attributesOfItem` for the existence check and the mtime: a
    // `fileExists` first stat'ed every stamped path twice.
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date
    else { return "" }
    // bitPattern, like inventoryEntryStamp: the stamp is the fingerprint, so it
    // has to separate every mtime the filesystem can report. Truncating to whole
    // seconds gives two rewrites inside the same second the same stamp, and the
    // fingerprint misses a manager that changed a manifest mid-scan, or a
    // package tree touched twice inside one second, which a `flatpak install`
    // of a small app does, keeping the stamp it had before the change and
    // serving the pre-change package list from cache. Truncation is also toward
    // zero, so distinct pre-1970 mtimes collapse onto each other.
    return "\(label):\(mtime.timeIntervalSince1970.bitPattern)"
}

func userToolDirStamps(_ dirs: [(String, String)]) -> [String] {
    dirs.compactMap { label, dir in
        let line = dirNameStamp(label, dir)
        return line.isEmpty ? nil : line
    }
}

/// Cache stamp for an installed Android SDK. Presence only, by design: the
/// stamp says the SDK is there, not which version, so a cached scan of a
/// machine that later gains an SDK still has to be re-run for the apps in it.
func androidSdkStamp(sdkDirs: [String]? = nil) -> String {
    for sdk in sdkDirs ?? defaultAndroidSdkDirs() where androidSdkLooksReal(sdk) {
        return "android-sdk"
    }
    return ""
}

public struct ResolvedScan: Sendable {
    public var data: ScanData
    public var fromCache: Bool
    /// Why the live scan could not be saved, or nil when it was. The scan
    /// itself stands; the next run has no cache to start from.
    public var cacheWriteFailure: String?

    public init(data: ScanData, fromCache: Bool, cacheWriteFailure: String? = nil) {
        self.data = data
        self.fromCache = fromCache
        self.cacheWriteFailure = cacheWriteFailure
    }
}

/// Return the last scan if it is still current, otherwise scan live and save the cache.
/// `fresh` ignores the cache. `forceLive` always scans (CLI `update`).
///
/// The live scan goes through `runFullScan` unless `liveScan` replaces it, so
/// the one-scan-at-a-time rule there applies here too. The default
/// `fingerprintFn` shells out to the package managers twice per call, once
/// before the scan and once after, which is what makes a mid-scan change to
/// the inventory drop the snapshot instead of caching a mixture.
public func resolveScan(
    includeSystem: Bool,
    fresh: Bool,
    forceLive: Bool,
    cacheURL: URL = defaultScanCacheURL(),
    now: Date = Date(),
    fingerprintFn: () -> String = { scanFingerprint() },
    liveScan: ((Bool) -> ScanData)? = nil
) -> ResolvedScan {
    let before = fingerprintFn()
    if !forceLive && !fresh, let cache = loadScanCache(from: cacheURL) {
        if !isScanCacheStale(cache, includeSystem: includeSystem, fingerprint: before, now: now) {
            var data = cache.data
            data.from_cache = true
            return ResolvedScan(data: data, fromCache: true)
        }
        deleteExpiredScanCache(cache, now: now, at: cacheURL)
    }
    let data = (liveScan ?? { runFullScan(includeSystem: $0, now: now) })(includeSystem)
    let after = fingerprintFn()
    var cacheWriteFailure: String?
    do {
        let committed = try commitScanCache(
            includeSystem: includeSystem,
            data: data,
            before: before,
            after: after,
            to: cacheURL
        )
        if !committed, data.incomplete != true {
            cacheWriteFailure = "installed software changed while the scan was running"
        }
    } catch {
        cacheWriteFailure = error.localizedDescription
    }
    var out = data
    out.from_cache = false
    return ResolvedScan(data: out, fromCache: false, cacheWriteFailure: cacheWriteFailure)
}
