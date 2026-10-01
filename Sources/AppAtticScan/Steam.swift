import Foundation

struct SteamAppManifest {
    var appId: String
    var name: String
    var installDir: String
    var lastPlayed: Date?
    var sizeOnDisk: Int
    var isInstalled: Bool
}

/// The quoted strings on one VDF line, in order, with the escapes resolved.
///
/// VDF escapes `\"` and `\\` inside a string, so a closing quote is found by
/// scanning for the next `"` that is not preceded by an odd run of
/// backslashes. Finding the raw next `"` instead truncated the first value at
/// an escaped quote and read the text after it as a value of its own: a game
/// named `He said "hi"` came out of `"name"\t\t"He said \"hi\""` as `He said \`
/// plus a stray `""`, and that name is the row a person reads and the argument
/// the uninstall script is built from.
///
/// An unterminated string ends the line rather than swallowing the rest of the
/// file: the value it would have held is not knowable, and the pair reader
/// already refuses a line that does not give it two.
func vdfQuotedStrings(_ line: String) -> [String] {
    var out: [String] = []
    var i = line.startIndex
    while i < line.endIndex {
        guard let q = line[i...].firstIndex(of: "\"") else { break }
        var start = line.index(after: q)
        var value = String.UnicodeScalarView()
        var closed = false
        while start < line.endIndex {
            let c = line[start]
            if c == "\\" {
                let next = line.index(after: start)
                guard next < line.endIndex else { break }
                // The format defines two escapes, `\\` and `\"`, and both take
                // the character after the backslash. Any other `\x` is not an
                // escape: the backslash is the character and the next one
                // follows it, so a name holding `\a` keeps both and every value
                // is still a span of the file with the quotes taken off. A
                // trailing backslash ends the value as unterminated.
                if line[next] == "\\" || line[next] == "\"" {
                    value.append(line[next])
                    start = line.index(after: next)
                } else {
                    value.append(c)
                    start = line.index(after: start)
                }
                continue
            }
            if c == "\"" {
                closed = true
                break
            }
            value.append(c)
            start = line.index(after: start)
        }
        guard closed else { break }
        out.append(String(value))
        i = line.index(after: start)
    }
    return out
}

/// A VDF comment, `//` to the end of the line, off the line it is on.
///
/// The comment is not a `//` inside a quoted string: a path or a name may hold
/// two slashes (`/usr/`, `C://games`), and those are content. So the scan is
/// over the quote-delimited runs only, and it stops at the first `//` that
/// starts one.
func vdfStripComment(_ line: String) -> Substring {
    var inString = false
    var escaped = false
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if escaped {
            escaped = false
        } else if inString, c == "\\" {
            escaped = true
        } else if c == "\"" {
            inString.toggle()
        } else if !inString, c == "/", line.index(after: i) < line.endIndex,
                  line[line.index(after: i)] == "/"
        {
            return line[..<i]
        }
        i = line.index(after: i)
    }
    return line[...]
}

func vdfPairs(_ text: String, depth wanted: Int) -> [String: String] {
    var out: [String: String] = [:]
    var depth = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(vdfStripComment(String(raw).trimmingCharacters(in: .whitespaces)))
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let quoted = vdfQuotedStrings(line)
        if depth == wanted, quoted.count >= 2 {
            out[quoted[0]] = quoted[1]
        }
        // The count is over the comment-free line, so a `}` a comment holds
        // cannot close a block and a `{` it holds cannot open one. An
        // unbalanced brace in prose otherwise desynchronises every later line:
        // `// installer: }` above `"name"` dropped the rest of the manifest, so
        // an installed game read as not installed and never reached the report.
        depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        if depth < 0 { depth = 0 }
    }
    return out
}

/// Bit 2 of `StateFlags` in appmanifest_*.acf. A game without it is not
/// installed, so it is not reported at all.
private let steamFlagInstalled = 4

func parseSteamAppManifest(_ text: String) -> SteamAppManifest? {
    let pairs = vdfPairs(text, depth: 1)
    let appId = pairs["appid"] ?? ""
    let name = pairs["name"] ?? ""
    let installDir = pairs["installdir"] ?? ""
    guard !appId.isEmpty, !name.isEmpty, !installDir.isEmpty else { return nil }
    let flags = Int(pairs["StateFlags"] ?? "0") ?? 0
    guard flags & steamFlagInstalled != 0 else { return nil }
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
        // Comment-stripped for the same reason `vdfPairs` strips it: a quoted
        // string in a `//` line is not a path this reader may act on.
        let line = String(vdfStripComment(String(raw).trimmingCharacters(in: .whitespaces)))
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let quoted = vdfQuotedStrings(line)
        if quoted.count >= 2, quoted[0].posixLowercased() == "path" {
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
    let n = name.posixLowercased()
    if n.contains("steamworks") { return true }
    if n.contains("steam linux runtime") { return true }
    if n.hasPrefix("proton ") {
        let rest = n.dropFirst(7)
        // ASCII digits only, so `Proton ٩` is not read as a numbered build.
        if rest.hasPrefix("experimental") || rest.hasPrefix("hotfix")
            || (rest.first.map { $0.isNumber && $0.isASCII } ?? false) {
            return true
        }
    }
    return false
}

func isBrowserAppShortcut(_ path: String) -> Bool {
    let p = path.posixLowercased()
    return p.contains("/chrome apps.localized/")
        || p.contains("/brave browser apps.localized/")
        || p.contains("/microsoft edge apps.localized/")
}

/// A Steam game whose manifest carried a size is never measured with `du`.
/// The manifest value is kept instead, so a stale `SizeOnDisk` from a moved
/// or partially deleted install is what gets reported.
func skipLiveDu(_ a: AppRecord) -> Bool {
    a.extra["steam_appid"] != nil && a.sizeBytes > 0
}

func steamBundles(in dir: String, depth: Int) -> [String] {
    guard depth >= 1 else { return [] }
    var out: [String] = []
    // `directoryEntryNames` sorts, which `steamGameBundle` needs: it takes the
    // first bundle matching a manifest name, and readdir order would pick a
    // different survivor on every process.
    for name in directoryEntryNames(dir) {
        let child = (dir as NSString).appendingPathComponent(name)
        if name.hasSuffix(".app") {
            if !name.posixLowercased().contains("helper") {
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
    let wants = Set(names.compactMap(normKey))
    if let match = bundles.first(where: {
        normKey(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
            .map { wants.contains($0) } ?? false
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
    // The manifest name comes from an `appmanifest_*.acf` on disk, so it is as
    // attacker-controlled as a bundle name, and it lands in the generated
    // script's `#` comment. `makeApp` filters bidi and zero-width scalars from
    // every other name source; the overwrite below was undoing that filter.
    let name = stripBidiControls(manifest.name)
    var app: AppRecord
    if let bundle, let made = makeApp(from: bundle) {
        app = made
        app.displayName = name
    } else {
        app = AppRecord(
            path: install,
            displayName: name,
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
        // `directoryEntryNames` sorts, which `seenIds` needs: it keeps the
        // first record of an app id, and readdir order would pick a different
        // library's copy of a shared app on each run.
        for name in directoryEntryNames(steamapps) where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
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
    apps.sort {
        collatedBefore($0.displayName, $1.displayName, tieBreak: $0.path, $1.path)
    }
    return apps
}

func steamManifestStamp(libraryRoots: [String]? = nil) -> String {
    var lines: [String] = []
    visitSteamLibraries(libraryRoots: libraryRoots) { real in
        let steamapps = (real as NSString).appendingPathComponent("steamapps")
        let acfs = directoryEntryNames(steamapps)
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
        lines.append("steam:\(stampEscape(real)):\(stampJoin(acfs))")
    }
    return lines.sorted().joined(separator: "\n")
}

func appendSteamApps(_ apps: inout [AppRecord], seen: inout Set<String>, libraryRoots: [String]? = nil) {
    let steam = findSteamApps(libraryRoots: libraryRoots)
    let steamNames = Set(steam.compactMap { normKey($0.displayName) })
    let steamBids = Set(steam.compactMap { $0.bundleId?.posixLowercased() }.filter { !$0.isEmpty })
    apps.removeAll { existing in
        guard isBrowserAppShortcut(existing.path) else { return false }
        let drop = normKey(existing.displayName).map { steamNames.contains($0) } == true
            || (existing.bundleId.map { steamBids.contains($0.posixLowercased()) } ?? false)
        if drop { seen.remove(existing.path) }
        return drop
    }
    for app in steam {
        if seen.insert(app.path).inserted {
            apps.append(app)
        }
    }
}
