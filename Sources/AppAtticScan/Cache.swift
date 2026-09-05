import Foundation

/// Max age before a fingerprint-matching cache is treated as stale (24 hours).
public let scanCacheMaxAge: TimeInterval = 24 * 3600

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

/// Swallow read/decode errors. Prefer `readScanCache` when the caller must distinguish missing vs corrupt.
public func loadScanCache(from url: URL = defaultScanCacheURL()) -> ScanCacheFile? {
    try? readScanCache(from: url)
}

public func readScanCache(from url: URL = defaultScanCacheURL()) throws -> ScanCacheFile {
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

/// Swallow write errors. Prefer `writeScanCache` when failure must surface.
public func saveScanCache(_ cache: ScanCacheFile, to url: URL = defaultScanCacheURL()) {
    try? writeScanCache(cache, to: url)
}

public func writeScanCache(_ cache: ScanCacheFile, to url: URL = defaultScanCacheURL()) throws {
    let dir = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if dir.lastPathComponent.lowercased() == "appattic" {
            try restrictOwnerOnlyDirectory(at: dir)
        }
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
        try raw.write(to: url, options: .atomic)
        try restrictPrivateDataFile(at: url)
    } catch {
        throw AppAtticIOError.writeFailed(path: url.path, message: error.localizedDescription)
    }
}

/// True when includeSystem, fingerprint, or age (default 24h) no longer match.
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
    guard let when = parseISODate(cache.data.scanned_at) else { return true }
    let age = now.timeIntervalSince(when)
    return age < 0 || age > maxAge
}

public func clearScanCache(at url: URL = defaultScanCacheURL()) {
    try? FileManager.default.removeItem(at: url)
}

/// Save only when the inventory stamp is unchanged across the scan and the
/// result is complete. Otherwise a later hit would serve a mixed snapshot.
@discardableResult
public func commitScanCache(
    includeSystem: Bool,
    data: ScanData,
    before: String,
    after: String,
    to url: URL = defaultScanCacheURL()
) -> Bool {
    if data.incomplete == true { return false }
    guard before == after else { return false }
    do {
        try writeScanCache(
            ScanCacheFile(fingerprint: after, includeSystem: includeSystem, data: data),
            to: url
        )
        return true
    } catch {
        return false
    }
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
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case ",": out += "\\,"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        default: out.append(ch)
        }
    }
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
    guard FileManager.default.fileExists(atPath: path),
          let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date
    else { return "" }
    return "\(label):\(Int(mtime.timeIntervalSince1970))"
}

func userToolDirStamps(_ dirs: [(String, String)]) -> [String] {
    dirs.compactMap { label, dir in
        let line = dirNameStamp(label, dir)
        return line.isEmpty ? nil : line
    }
}

func androidSdkStamp(sdkDirs: [String]? = nil) -> String {
    for sdk in sdkDirs ?? defaultAndroidSdkDirs() where androidSdkLooksReal(sdk) {
        return "android-sdk"
    }
    return ""
}

public struct ResolvedScan: Sendable {
    public var data: ScanData
    public var fromCache: Bool

    public init(data: ScanData, fromCache: Bool) {
        self.data = data
        self.fromCache = fromCache
    }
}

/// Return the last scan if it is still current, otherwise scan live and save the cache.
/// `fresh` ignores the cache. `forceLive` always scans (CLI `update`).
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
    }
    let data = (liveScan ?? { runFullScan(includeSystem: $0, now: now) })(includeSystem)
    let after = fingerprintFn()
    _ = commitScanCache(
        includeSystem: includeSystem,
        data: data,
        before: before,
        after: after,
        to: cacheURL
    )
    var out = data
    out.from_cache = false
    return ResolvedScan(data: out, fromCache: false)
}
