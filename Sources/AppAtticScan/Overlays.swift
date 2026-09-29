import Foundation

// The PATH and overlay directories: which ones are scanned, the broken
// symlinks in them, what a package dir shadows, and the tool names they ship.

/// The entries of `root`, as paths, dot files excluded.
///
/// Reads `d_name` as raw bytes rather than through
/// `FileManager.contentsOfDirectory`, which decodes with the platform default
/// and substitutes U+FFFD. The paths returned here are the arguments of the
/// guarded `rm -rf` the leftover scan generates, so a lossy name is not a
/// cosmetic loss: the U+FFFD path names a *different* entry, and the report
/// claims an entry was removed that is still on disk. An entry whose bytes are
/// not UTF-8 has no path a UTF-8 API can name, so `direntName` returns nil for
/// it and it is left out, the same rule the disk walk follows.
func listEntries(_ root: String) -> [String] {
    guard let dir = opendir(root) else { return [] }
    defer { closedir(dir) }
    var paths: [String] = []
    while let ent = readdir(dir) {
        guard let name = direntName(ent), !name.hasPrefix(".") else { continue }
        paths.append((root as NSString).appendingPathComponent(name))
    }
    return paths.sorted()
}

func shouldScanUserBinDir(
    _ dir: String,
    brewPrefixBin: String? = nil,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> Bool {
    guard fileExists(dir) else { return false }
    if let brewPrefixBin {
        let a = URL(fileURLWithPath: dir).standardizedFileURL.path
        let b = URL(fileURLWithPath: brewPrefixBin).standardizedFileURL.path
        if a == b { return false }
    }
    return true
}

func defaultUserBinDirs(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    usrLocalBin: String = "/usr/local/bin",
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    which: WhichFn = whichCommand
) -> [String] {
    var dirs = [
        (home as NSString).appendingPathComponent(".local/bin"),
        (home as NSString).appendingPathComponent("bin"),
    ]
    let brewPrefixBin = which("brew").map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    if shouldScanUserBinDir(usrLocalBin, brewPrefixBin: brewPrefixBin, fileExists: fileExists) {
        dirs.append(usrLocalBin)
    }
    return dirs
}

func userBinRootLabel(_ dir: String) -> String {
    let path = URL(fileURLWithPath: dir).standardizedFileURL.path
    if path.hasSuffix("/usr/local/bin") { return "/usr/local/bin" }
    if path.hasSuffix("/opt/homebrew/bin") { return "homebrew/bin" }
    if path.contains("/.linuxbrew/bin") { return "linuxbrew/bin" }
    if path.hasSuffix("/.cargo/bin") { return ".cargo/bin" }
    if path.hasSuffix("/.local/share/applications") { return ".local/share/applications" }
    if path.hasSuffix("/.local/bin") { return ".local/bin" }
    if URL(fileURLWithPath: path).lastPathComponent == "bin" { return "bin" }
    return ".local/bin"
}

public func listBrokenUserBinLinks(dirs: [String]? = nil) -> [DataItem] {
    let fm = FileManager.default
    var grouped: [String: [(path: String, name: String, dest: String)]] = [:]
    for dir in dirs ?? defaultUserBinDirs() {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
            if fm.fileExists(atPath: path) { continue }
            let absDest: String
            if dest.hasPrefix("/") {
                absDest = dest
            } else {
                absDest = (dir as NSString).appendingPathComponent(dest)
            }
            let key = URL(fileURLWithPath: absDest).deletingLastPathComponent().path
            grouped[key, default: []].append((path, name, absDest))
        }
    }
    var items: [DataItem] = []
    for (destDir, links) in grouped {
        let names = links.map(\.name)
        let toolFolder = URL(fileURLWithPath: destDir).deletingLastPathComponent().lastPathComponent
        let pick = preferredBrokenLinkName(names, toolFolder: toolFolder)
        let primary = links.first { $0.name == pick } ?? links[0]
        let extra = links.map(\.path).filter { $0 != primary.path }.sorted()
        items.append(DataItem(
            path: primary.path,
            // Every other name source strips bidi and zero-width scalars; this
            // one reads the name straight off the filesystem, so a symlink
            // called `Evil<U+202E>gnits` was the last way a reversed name
            // reached the report. `path` and `extraPaths` keep the raw bytes:
            // they are what the generated script deletes.
            name: stripBidiControls(primary.name),
            rootLabel: userBinRootLabel(URL(fileURLWithPath: primary.path).deletingLastPathComponent().path),
            kind: "symlink",
            status: LeftoverStatus.orphaned.rawValue,
            extraPaths: extra
        ))
    }
    // `grouped` iterates in hash order, so the path breaks case-insensitive
    // name ties: without it two links called `Foo` and `foo` swap places
    // between processes.
    return items.sorted {
        let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
        return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
    }
}

public func defaultOverlayShadowRoots(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [(dir: String, label: String, kind: String)] {
    let ns = home as NSString
    let data = xdgDataHome(home: home, env: env)
    let xdgDesktop = (data as NSString).appendingPathComponent("applications")
    let legacyDesktop = ns.appendingPathComponent(".local/share/applications")
    var roots: [(dir: String, label: String, kind: String)] = [
        (ns.appendingPathComponent(".local/bin"), ".local/bin", "file"),
        (ns.appendingPathComponent("bin"), "bin", "file"),
        (ns.appendingPathComponent(".cargo/bin"), ".cargo/bin", "file"),
        (xdgDesktop, ".local/share/applications", "desktop"),
    ]
    if URL(fileURLWithPath: legacyDesktop).standardizedFileURL.path
        != URL(fileURLWithPath: xdgDesktop).standardizedFileURL.path
    {
        roots.append((legacyDesktop, ".local/share/applications", "desktop"))
    }
    return roots
}

public func defaultPackageShadowDirs(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment,
    which: WhichFn = whichCommand
) -> [String] {
    var dirs = [
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/sbin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/snap/bin",
        "/usr/share/applications",
        "/usr/local/share/applications",
        "/var/lib/flatpak/exports/bin",
        "/var/lib/flatpak/exports/share/applications",
    ]
    if let brew = which("brew") {
        dirs.append(URL(fileURLWithPath: brew).deletingLastPathComponent().path)
    }
    let data = xdgDataHome(home: home, env: env) as NSString
    dirs.append(data.appendingPathComponent("flatpak/exports/bin"))
    dirs.append(data.appendingPathComponent("flatpak/exports/share/applications"))
    let legacy = home as NSString
    dirs.append(legacy.appendingPathComponent(".local/share/flatpak/exports/bin"))
    dirs.append(legacy.appendingPathComponent(".local/share/flatpak/exports/share/applications"))
    var seen = Set<String>()
    return dirs.filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
}

public func listShadowingOverlays(
    overlays: [(dir: String, label: String, kind: String)]? = nil,
    packageDirs: [String]? = nil
) -> [DataItem] {
    let fm = FileManager.default
    let overlayRoots = overlays ?? defaultOverlayShadowRoots()
    let pkgs = packageDirs ?? defaultPackageShadowDirs()
    let pkgSet = Set(pkgs.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    var items: [DataItem] = []
    for (dir, label, kind) in overlayRoots {
        let dirStd = URL(fileURLWithPath: dir).standardizedFileURL.path
        if pkgSet.contains(dirStd) { continue }
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { continue }
            if kind == "desktop", !name.hasSuffix(".desktop") { continue }
            if kind == "file", !fm.isExecutableFile(atPath: path) { continue }
            let resolvedOverlay = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var packaged: String?
            var sameFile = false
            for pkgDir in pkgs {
                let candidate = (pkgDir as NSString).appendingPathComponent(name)
                guard fm.fileExists(atPath: candidate) else { continue }
                let resolvedPkg = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                if resolvedOverlay == resolvedPkg {
                    sameFile = true
                    break
                }
                if packaged == nil {
                    packaged = candidate
                }
            }
            if sameFile { continue }
            guard let packaged else { continue }
            items.append(DataItem(
                path: path,
                name: name,
                rootLabel: label,
                kind: kind,
                status: LeftoverStatus.shadow.rawValue,
                shadows: packaged
            ))
        }
    }
    // Path breaks the case-insensitive name tie, so two overlays called `Foo`
    // and `foo` keep the same order between processes.
    return items.sorted {
        let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
        return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
    }
}

func preferredBrokenLinkName(_ names: [String], toolFolder: String) -> String {
    // Callers hand in `contentsOfDirectory` order, which the filesystem is
    // free to vary; the first-match and longest-name picks below must not.
    let names = names.sorted()
    let variants = [
        toolFolder,
        toolFolder.replacingOccurrences(of: "-", with: "_"),
        toolFolder.replacingOccurrences(of: "_", with: "-"),
    ]
    if let hit = names.first(where: { variants.contains($0) }) { return hit }
    // `sort` is unstable, so an equal-length pair could come out either way.
    // Name breaks the tie in both picks below, lowest first, matching the
    // order `names` already arrived in.
    let sorted = names.sorted { a, b in a.count == b.count ? a < b : a.count < b.count }
    if let short = sorted.first,
       names.allSatisfy({
           $0 == short
               || $0.hasPrefix(short + "-")
               || $0.hasPrefix(short + "_")
               || $0.hasPrefix(short + ".")
       })
    {
        return short
    }
    let noDot = names.filter { !$0.contains(".") }
    return (noDot.isEmpty ? names : noDot).max { a, b in
        a.count == b.count ? a > b : a.count < b.count
    } ?? names[0]
}

func defaultUserToolDirs() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        (home as NSString).appendingPathComponent(".local/bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
    ]
}

func enclosingAppBundle(_ path: String) -> String? {
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    var acc = ""
    for part in real.split(separator: "/").map(String.init) {
        acc += "/" + part
        if part.hasSuffix(".app") { return acc }
    }
    return nil
}

/// One executable found while walking the user tool directories.
public typealias ToolEntry = (name: String, path: String)

func executableToolEntries(in dirs: [String]?) -> [ToolEntry] {
    let fm = FileManager.default
    var out: [ToolEntry] = []
    for dir in dirs ?? defaultUserToolDirs() {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        // `contentsOfDirectory` hands back readdir order, which the filesystem
        // is free to vary between runs. Callers below keep the first entry per
        // bundle or per name, so an unsorted read picks a different survivor
        // on every process.
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { continue }
            guard fm.isExecutableFile(atPath: path) else { continue }
            out.append((name, path))
        }
    }
    return out
}

public func appsFromPathBinaries(dirs: [String]? = nil, entries: [ToolEntry]? = nil) -> [AppRecord] {
    var out: [AppRecord] = []
    var seen = Set<String>()
    for entry in entries ?? executableToolEntries(in: dirs) {
        let real = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path
        guard let bundle = enclosingAppBundle(real), seen.insert(bundle).inserted else { continue }
        if let app = makeApp(from: bundle) { out.append(app) }
    }
    return out
}

public func listUserToolNames(
    dirs: [String]? = nil,
    which: WhichFn = whichCommand,
    sdkDirs: [String]? = nil,
    entries: [ToolEntry]? = nil
) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for entry in entries ?? executableToolEntries(in: dirs) where seen.insert(entry.name).inserted {
        out.append(entry.name)
    }
    for extra in ["wine", "docker"] {
        if which(extra) != nil, seen.insert(extra).inserted { out.append(extra) }
    }
    for sdk in sdkDirs ?? defaultAndroidSdkDirs() where androidSdkLooksReal(sdk) {
        if seen.insert("android").inserted { out.append("android") }
        break
    }
    return out
}

func defaultAndroidSdkDirs() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let env = ProcessInfo.processInfo.environment
    return [
        env["ANDROID_HOME"],
        env["ANDROID_SDK_ROOT"],
        (home as NSString).appendingPathComponent("Library/Android"),
        (home as NSString).appendingPathComponent("Android/Sdk"),
        (home as NSString).appendingPathComponent("Android"),
        "/opt/android-sdk",
        "/usr/lib/android-sdk",
    ].compactMap { dir in
        guard let dir, !dir.isEmpty else { return nil }
        return dir
    }
}

func androidSdkLooksReal(_ path: String) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
    for sub in ["emulator", "platform-tools", "cmdline-tools", "platforms"] {
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent(sub)) {
            return true
        }
    }
    return false
}
