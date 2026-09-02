import Foundation

struct SteamAppManifest {
    var appId: String
    var name: String
    var installDir: String
    var lastPlayed: Date?
    var sizeOnDisk: Int
    var isInstalled: Bool
}

func vdfQuotedStrings(_ line: String) -> [String] {
    var out: [String] = []
    var i = line.startIndex
    while i < line.endIndex {
        guard let q = line[i...].firstIndex(of: "\"") else { break }
        let start = line.index(after: q)
        guard start < line.endIndex, let end = line[start...].firstIndex(of: "\"") else { break }
        out.append(String(line[start..<end]))
        i = line.index(after: end)
    }
    return out
}

func vdfPairs(_ text: String, depth wanted: Int) -> [String: String] {
    var out: [String: String] = [:]
    var depth = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let quoted = vdfQuotedStrings(String(line))
        if depth == wanted, quoted.count >= 2 {
            out[quoted[0]] = quoted[1]
        }
        depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        if depth < 0 { depth = 0 }
    }
    return out
}

func parseSteamAppManifest(_ text: String) -> SteamAppManifest? {
    let pairs = vdfPairs(text, depth: 1)
    let appId = pairs["appid"] ?? ""
    let name = pairs["name"] ?? ""
    let installDir = pairs["installdir"] ?? ""
    guard !appId.isEmpty, !name.isEmpty, !installDir.isEmpty else { return nil }
    let flags = Int(pairs["StateFlags"] ?? "0") ?? 0
    guard flags & 4 != 0 else { return nil }
    let playedRaw = Int(pairs["LastPlayed"] ?? "0") ?? 0
    let size = Int(pairs["SizeOnDisk"] ?? "0") ?? 0
    return SteamAppManifest(
        appId: appId,
        name: name,
        installDir: installDir,
        lastPlayed: playedRaw > 0 ? dateFromUnixEpoch(TimeInterval(playedRaw)) : nil,
        sizeOnDisk: size,
        isInstalled: true
    )
}

func parseSteamLibraryFolders(_ text: String) -> [String] {
    var paths: [String] = []
    var seen = Set<String>()
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let quoted = vdfQuotedStrings(String(line))
        if quoted.count >= 2, quoted[0].lowercased() == "path" {
            let path = quoted[1]
            if !path.isEmpty, seen.insert(path).inserted {
                paths.append(path)
            }
        }
    }
    return paths
}

func defaultSteamLibraryRoots(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    if PlatformOverride.isLinux {
        let data = xdgDataHome(home: home, env: env)
        return [
            (data as NSString).appendingPathComponent("Steam"),
            (home as NSString).appendingPathComponent(".local/share/Steam"),
            (home as NSString).appendingPathComponent(".steam/steam"),
            (home as NSString).appendingPathComponent(".steam/root"),
        ]
    }
    return [
        (home as NSString).appendingPathComponent("Library/Application Support/Steam"),
    ] + crossoverSteamLibraryRoots()
}

func visitSteamLibraries(libraryRoots: [String]?, body: (String) -> Void) {
    var pending = libraryRoots ?? defaultSteamLibraryRoots()
    var seenLibs = Set<String>()
    while let lib = pending.popLast() {
        let real = URL(fileURLWithPath: lib).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { continue }
        guard seenLibs.insert(real).inserted else { continue }
        for rel in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            let path = (real as NSString).appendingPathComponent(rel)
            if let text = readUTF8File(path) {
                pending.append(contentsOf: parseSteamLibraryFolders(text))
            }
        }
        body(real)
    }
}

func isSteamSupportPackage(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.contains("steamworks") { return true }
    if n.contains("steam linux runtime") { return true }
    if n.hasPrefix("proton ") {
        let rest = n.dropFirst(7)
        if rest.hasPrefix("experimental") || rest.hasPrefix("hotfix") || rest.first?.isNumber == true {
            return true
        }
    }
    return false
}

func isBrowserAppShortcut(_ path: String) -> Bool {
    let p = path.lowercased()
    return p.contains("/chrome apps.localized/")
        || p.contains("/brave browser apps.localized/")
        || p.contains("/microsoft edge apps.localized/")
}

func skipLiveDu(_ a: AppRecord) -> Bool {
    a.extra["steam_appid"] != nil && a.sizeBytes > 0
}

func steamBundles(in dir: String, depth: Int) -> [String] {
    guard depth >= 1, let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [String] = []
    for name in entries where !name.hasPrefix(".") {
        let child = (dir as NSString).appendingPathComponent(name)
        if name.hasSuffix(".app") {
            if !name.lowercased().contains("helper") {
                out.append(child)
            }
            continue
        }
        guard depth > 1 else { continue }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
            out.append(contentsOf: steamBundles(in: child, depth: depth - 1))
        }
    }
    return out
}

func steamGameBundle(in installDir: String, prefer names: [String]) -> String? {
    let bundles = steamBundles(in: installDir, depth: 2)
    guard !bundles.isEmpty else { return nil }
    let wants = Set(names.map(norm).filter { !$0.isEmpty })
    if let match = bundles.first(where: {
        wants.contains(norm(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent))
    }) {
        return match
    }
    return bundles.sorted()[0]
}

func steamClientRecord(library: String) -> AppRecord? {
    let candidates = [
        (library as NSString).appendingPathComponent("Steam.AppBundle/Steam"),
        (library as NSString).appendingPathComponent("Steam.AppBundle/Steam.app"),
    ]
    for path in candidates {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plist), var app = makeApp(from: path) else { continue }
        app.sourceDir = "steam"
        app.extra["steam_client"] = "1"
        app.sizeBytes = 0
        app.sizeMeasured = false
        return app
    }
    return nil
}

func steamAppRecord(library: String, manifest: SteamAppManifest) -> AppRecord? {
    let install = URL(fileURLWithPath: library)
        .appendingPathComponent("steamapps")
        .appendingPathComponent("common")
        .appendingPathComponent(manifest.installDir)
        .path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: install, isDirectory: &isDir), isDir.boolValue else {
        return nil
    }
    let bundle = steamGameBundle(in: install, prefer: [manifest.name, manifest.installDir])
    var app: AppRecord
    if let bundle, let made = makeApp(from: bundle) {
        app = made
        app.displayName = manifest.name
    } else {
        app = AppRecord(
            path: install,
            displayName: manifest.name,
            bundleId: "steam.\(manifest.appId)",
            sourceDir: "steam"
        )
    }
    app.sourceDir = "steam"
    app.extra["steam_appid"] = manifest.appId
    app.extra["steam_installdir"] = manifest.installDir
    app.extra["steam_name"] = manifest.name
    if let played = manifest.lastPlayed {
        app.lastUsed = played
        app.lastUsedSource = "steam"
    }
    if manifest.sizeOnDisk > 0 {
        app.sizeBytes = manifest.sizeOnDisk
        app.sizeMeasured = true
    }
    return app
}

public func findSteamApps(libraryRoots: [String]? = nil) -> [AppRecord] {
    var seenIds = Set<String>()
    var apps: [AppRecord] = []
    visitSteamLibraries(libraryRoots: libraryRoots) { real in
        if let client = steamClientRecord(library: real), seenIds.insert("client:\(client.path)").inserted {
            apps.append(client)
        }
        let steamapps = (real as NSString).appendingPathComponent("steamapps")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: steamapps) else { return }
        for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let acf = (steamapps as NSString).appendingPathComponent(name)
            guard let text = readUTF8File(acf),
                  let manifest = parseSteamAppManifest(text),
                  !isSteamSupportPackage(manifest.name),
                  seenIds.insert(manifest.appId).inserted,
                  let app = steamAppRecord(library: real, manifest: manifest)
            else { continue }
            apps.append(app)
        }
    }
    apps.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
    return apps
}

func steamManifestStamp(libraryRoots: [String]? = nil) -> String {
    var lines: [String] = []
    visitSteamLibraries(libraryRoots: libraryRoots) { real in
        let steamapps = (real as NSString).appendingPathComponent("steamapps")
        let acfs = ((try? FileManager.default.contentsOfDirectory(atPath: steamapps)) ?? [])
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            .sorted()
        lines.append("steam:\(stampEscape(real)):\(stampJoin(acfs))")
    }
    return lines.sorted().joined(separator: "\n")
}

func appendSteamApps(_ apps: inout [AppRecord], seen: inout Set<String>, libraryRoots: [String]? = nil) {
    let steam = findSteamApps(libraryRoots: libraryRoots)
    let steamNames = Set(steam.map { norm($0.displayName) }.filter { !$0.isEmpty })
    let steamBids = Set(steam.compactMap { $0.bundleId?.lowercased() }.filter { !$0.isEmpty })
    apps.removeAll { existing in
        guard isBrowserAppShortcut(existing.path) else { return false }
        let drop = steamNames.contains(norm(existing.displayName))
            || (existing.bundleId.map { steamBids.contains($0.lowercased()) } ?? false)
        if drop { seen.remove(existing.path) }
        return drop
    }
    for app in steam {
        if seen.insert(app.path).inserted {
            apps.append(app)
        }
    }
}
