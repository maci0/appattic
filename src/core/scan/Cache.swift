import Foundation

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
        let home = fm.homeDirectoryForCurrentUser.path
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? ((home as NSString).appendingPathComponent(".local") as NSString).appendingPathComponent("share")
        base = URL(fileURLWithPath: xdg).appendingPathComponent("appattic", isDirectory: true)
    } else {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        base = support.appendingPathComponent("AppAttic", isDirectory: true)
    }
    return base.appendingPathComponent("last-scan.json")
}

public func loadScanCache(from url: URL = defaultScanCacheURL()) -> ScanCacheFile? {
    guard let raw = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ScanCacheFile.self, from: raw)
}

public func saveScanCache(_ cache: ScanCacheFile, to url: URL = defaultScanCacheURL()) {
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var copy = cache
    copy.data.from_cache = false
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let raw = try? encoder.encode(copy) else { return }
    try? raw.write(to: url, options: .atomic)
}

public func isScanCacheStale(
    _ cache: ScanCacheFile,
    includeSystem: Bool,
    fingerprint: String,
    now: Date = Date(),
    maxAge: TimeInterval = scanCacheMaxAge
) -> Bool {
    if cache.includeSystem != includeSystem { return true }
    if cache.fingerprint != fingerprint { return true }
    guard let when = parseISODate(cache.data.scanned_at) else { return true }
    return now.timeIntervalSince(when) > maxAge
}

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
                lines.append("desk:\(dir):\(desktops.joined(separator: ","))")
            }
        }
    } else {
        let homeApps = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Applications")
        for root in ["/Applications", homeApps] {
            let names = iterApps(in: root).map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
            lines.append("apps:\(root):\(names.joined(separator: ","))")
        }
    }
    if let brew = which("brew") {
        let (_, formulas, _) = run([brew, "list", "--formula", "--versions"], 30)
        let (_, casks, _) = run([brew, "list", "--cask", "--versions"], 30)
        lines.append("brew-f:\(formulas.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("brew-c:\(casks.trimmingCharacters(in: .whitespacesAndNewlines))")
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
        lines.append("mas:\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return lines.joined(separator: "\n")
}

public func linuxPkgStampPaths(home: String) -> [(String, String)] {
    [
        ("flatpak-user", (home as NSString).appendingPathComponent(".local/share/flatpak")),
        ("flatpak-system", "/var/lib/flatpak"),
        ("snap", "/var/lib/snapd"),
        ("dpkg", "/var/lib/dpkg/status"),
        ("pacman", "/var/lib/pacman/local"),
        ("dnf", "/var/lib/dnf"),
        ("rpm", "/var/lib/rpm"),
        ("zypp", "/var/lib/zypp"),
    ]
}

func rootInventoryStamp(_ label: String, _ path: String) -> String {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return "root:\(label):missing"
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    let ents = names.filter { !$0.hasPrefix(".") }.sorted().joined(separator: ",")
    return "root:\(label):\(ents)"
}

func dirNameStamp(_ label: String, _ dir: String) -> String {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return "" }
    let ents = names.filter { !$0.hasPrefix(".") }.sorted().map { stampName(dir: dir, name: $0) }.joined(separator: ",")
    if ents.isEmpty { return "" }
    return "\(label):\(ents)"
}

func stampName(dir: String, name: String) -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return name }
    let resolved = dest.hasPrefix("/") ? dest : (dir as NSString).appendingPathComponent(dest)
    if FileManager.default.fileExists(atPath: resolved) { return name }
    return name + "?"
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

public func resolveScan(
    includeSystem: Bool,
    fresh: Bool,
    forceLive: Bool,
    cacheURL: URL = defaultScanCacheURL(),
    now: Date = Date(),
    fingerprintFn: () -> String = { scanFingerprint() },
    liveScan: (Bool) -> ScanData = { runFullScan(includeSystem: $0) }
) -> ResolvedScan {
    if !forceLive && !fresh, let cache = loadScanCache(from: cacheURL) {
        let fingerprint = fingerprintFn()
        if !isScanCacheStale(cache, includeSystem: includeSystem, fingerprint: fingerprint, now: now) {
            var data = cache.data
            data.from_cache = true
            return ResolvedScan(data: data, fromCache: true)
        }
    }
    let data = liveScan(includeSystem)
    saveScanCache(
        ScanCacheFile(fingerprint: fingerprintFn(), includeSystem: includeSystem, data: data),
        to: cacheURL
    )
    var out = data
    out.from_cache = false
    return ResolvedScan(data: out, fromCache: false)
}
