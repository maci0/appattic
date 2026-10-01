import Foundation

public struct AppRecord: Sendable {
    public var path: String
    public var displayName: String
    public var bundleId: String?
    public var sourceDir: String
    public var isSystem: Bool
    public var sizeBytes: Int
    public var sizeMeasured: Bool
    public var lastUsed: Date?
    public var lastUsedSource: String?
    public var installedAt: Date?
    public var extra: [String: String]

    public init(
        path: String,
        displayName: String,
        bundleId: String? = nil,
        sourceDir: String = "other",
        isSystem: Bool = false,
        sizeBytes: Int = 0,
        sizeMeasured: Bool = true,
        lastUsed: Date? = nil,
        lastUsedSource: String? = nil,
        installedAt: Date? = nil,
        extra: [String: String] = [:]
    ) {
        self.path = path
        self.displayName = displayName
        self.bundleId = bundleId
        self.sourceDir = sourceDir
        self.isSystem = isSystem
        self.sizeBytes = sizeBytes
        self.sizeMeasured = sizeMeasured
        self.lastUsed = lastUsed
        self.lastUsedSource = lastUsedSource
        self.installedAt = installedAt
        self.extra = extra
    }
}

private let fakeAppMarkers = [
    "/Library/WebKit/",
    "/Library/Containers/",
    "/Library/Application Support/",
    "/Library/Caches/",
    "/Library/Application Scripts/",
    "/Library/Group Containers/",
    "/Library/Saved Application State/",
    "/WebKitBuild/",
    "/DerivedData/",
    "/Build/Products/",
    "/node_modules/",
    "/.build/",
    "/Pods/",
]

private let appCategories: [String: String] = [
    "public.app-category.business": "Business app",
    "public.app-category.developer-tools": "Developer tools",
    "public.app-category.education": "Education app",
    "public.app-category.entertainment": "Entertainment app",
    "public.app-category.finance": "Finance app",
    "public.app-category.games": "Game",
    "public.app-category.graphics-design": "Graphics and design",
    "public.app-category.healthcare-fitness": "Health and fitness",
    "public.app-category.lifestyle": "Lifestyle app",
    "public.app-category.medical": "Medical app",
    "public.app-category.music": "Music app",
    "public.app-category.news": "News app",
    "public.app-category.photography": "Photography app",
    "public.app-category.productivity": "Productivity app",
    "public.app-category.reference": "Reference app",
    "public.app-category.social-networking": "Social networking",
    "public.app-category.sports": "Sports app",
    "public.app-category.travel": "Travel app",
    "public.app-category.utilities": "Utilities",
    "public.app-category.video": "Video app",
    "public.app-category.weather": "Weather app",
]

public func isRealAppPath(_ path: String) -> Bool {
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    if real.isEmpty { return false }
    if real.hasPrefix("/System/") || real.hasPrefix("/usr/") || real.hasPrefix("/private/var/") {
        return false
    }
    for marker in fakeAppMarkers where real.contains(marker) {
        return false
    }
    let apps = real.split(separator: "/").filter { $0.hasSuffix(".app") }
    return apps.count <= 1
}

public func appBundleBases(_ appPath: String) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    func add(_ path: String) {
        guard !path.isEmpty, !seen.contains(path) else { return }
        seen.insert(path)
        out.append(path)
    }
    add(appPath)
    let wrapped = (appPath as NSString).appendingPathComponent("WrappedBundle")
    if FileManager.default.fileExists(atPath: wrapped) {
        add(URL(fileURLWithPath: wrapped).resolvingSymlinksInPath().path)
    }
    let wrapper = (appPath as NSString).appendingPathComponent("Wrapper")
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: wrapper, isDirectory: &isDir), isDir.boolValue {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: wrapper) {
            // Sorted: readdir order decides which of several wrapped bundles
            // is reported first, and it varies between processes.
            for name in names.sorted() where name.hasSuffix(".app") {
                add((wrapper as NSString).appendingPathComponent(name))
            }
        }
    }
    return out
}

public func linuxDesktopDirs(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    func add(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let abs = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if seen.insert(abs).inserted { out.append(abs) }
    }
    let xdgHome = xdgDataHome(home: home, env: env)
    add((xdgHome as NSString).appendingPathComponent("applications"))
    add(((xdgHome as NSString).appendingPathComponent("flatpak/exports/share") as NSString).appendingPathComponent("applications"))
    for d in xdgSystemDirList(env: env) {
        add((d as NSString).appendingPathComponent("applications"))
    }
    for d in [
        "/usr/share/applications",
        "/usr/local/share/applications",
        (home as NSString).appendingPathComponent(".local/share/applications"),
        "/var/lib/flatpak/exports/share/applications",
        (home as NSString).appendingPathComponent(".local/share/flatpak/exports/share/applications"),
        "/var/lib/snapd/desktop/applications",
    ] {
        add(d)
    }
    return out
}

public func categoryLabel(_ uti: String?) -> String? {
    guard let uti, !uti.isEmpty else { return nil }
    if let mapped = appCategories[uti] { return mapped }
    let token = uti.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
    if token.isEmpty || token == uti { return nil }
    return token.prefix(1).uppercased() + token.dropFirst()
}

public func isJunkAppBlurb(_ text: String) -> Bool {
    let low = text.posixLowercased()
    if low.contains("all rights reserved") { return true }
    if low.contains("unity player") { return true }
    return false
}

public func plistDescription(_ info: [String: Any], appName: String) -> String? {
    let raw = (info["NSHumanReadableDescription"] as? String) ?? (info["CFBundleGetInfoString"] as? String)
    guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    if isJunkAppBlurb(text) { return nil }
    let low = text.posixLowercased()
    for marker in [", copyright", " copyright", ", ©", " ©", " (c)", "(c)"] {
        if let r = low.range(of: marker), r.lowerBound > low.startIndex {
            let idx = text.index(text.startIndex, offsetBy: low.distance(from: low.startIndex, to: r.lowerBound))
            text = String(text[..<idx]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
            break
        }
    }
    if text.isEmpty || isJunkAppBlurb(text) { return nil }
    func fullMatch(_ s: String) -> Bool {
        // `^[\d.]+$` as a byte check: non-empty, digits and dots only.
        s.utf8.withContiguousStorageIfAvailable { u -> Bool in
            guard !u.isEmpty else { return false }
            for k in 0..<u.count {
                let c = u[k]
                guard (c >= 0x30 && c <= 0x39) || c == 0x2E else { return false }
            }
            return true
        } ?? false
    }
    if fullMatch(text) { return nil }
    if text.posixLowercased().contains("project group") { return nil }
    let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
    if let last = parts.last, fullMatch(last) { return nil }
    let nameC = normKey(appName)
    let textC = norm(text)
    if let nameC, textC == nameC || textC == nameC + "formac" { return nil }
    if parts.count < 3 { return nil }
    return text
}

func loadPlist(_ path: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
    var fmt = PropertyListSerialization.PropertyListFormat.xml
    guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt) as? [String: Any] else {
        return [:]
    }
    return obj
}

/// The `.lproj` locale a `LANG` value names: the part before the first `.`,
/// with `-` folded to `_`, so `pt_BR.UTF-8` and `pt-BR` both name `pt_BR`.
/// Empty when the value names no locale, including one that is only an
/// encoding (`.UTF-8`): the split keeps the empty part before the dot, where
/// the default split would drop it and read the encoding as the locale.
func lprojLocale(lang: String) -> String {
    String(lang.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
        .replacingOccurrences(of: "-", with: "_")
}

func lprojCandidates(lang raw: String) -> [String] {
    var out: [String] = []
    let lang = lprojLocale(lang: raw)
    if !lang.isEmpty {
        out.append(lang)
        if lang.contains("_") { out.append(String(lang.split(separator: "_")[0])) }
    }
    for extra in ["en", "English", "Base"] where !out.contains(extra) {
        out.append(extra)
    }
    return out
}

func readInfoPlist(_ appPath: String, bases: [String]? = nil) -> [String: Any] {
    var data: [String: Any] = [:]
    let resolved = bases ?? appBundleBases(appPath)
    for base in resolved {
        for rel in ["Contents/Info.plist", "Info.plist"] {
            let loaded = loadPlist((base as NSString).appendingPathComponent(rel))
            if !loaded.isEmpty {
                data = loaded
                break
            }
        }
        if !data.isEmpty { break }
    }
    // Reading `LANG` copies the whole process environment.
    // Resolved once per app instead of once per base and resource directory.
    let locs = lprojCandidates(lang: ProcessInfo.processInfo.environment["LANG"] ?? "")
    for base in resolved {
        for resName in ["Contents/Resources", "Resources"] {
            let res = (base as NSString).appendingPathComponent(resName)
            for loc in locs {
                let path = ((res as NSString).appendingPathComponent("\(loc).lproj") as NSString)
                    .appendingPathComponent("InfoPlist.strings")
                let strings = loadPlist(path)
                for key in ["NSHumanReadableDescription", "CFBundleGetInfoString"] {
                    if let val = strings[key] as? String, !val.trimmingCharacters(in: .whitespaces).isEmpty {
                        data[key] = val
                    }
                }
                if !strings.isEmpty { return data }
            }
        }
    }
    return data
}

public func hasMasReceipt(_ appPath: String, bases: [String]? = nil) -> Bool {
    for base in bases ?? appBundleBases(appPath) {
        for rel in ["Contents/_MASReceipt/receipt", "_MASReceipt/receipt"] {
            if FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(rel)) {
                return true
            }
        }
    }
    return false
}

func stripBidiControls(_ s: String) -> String {
    // Every stripped scalar is non-ASCII: pure-ASCII names (the common case)
    // return as-is without the filter/rebuild churn.
    if s.utf8.allSatisfy({ $0 < 0x80 }) { return s }
    return String(s.unicodeScalars.filter { scalar in
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x180E,
             0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F,
             0xFE00...0xFE0F, 0xFEFF,
             0xE0100...0xE01EF:
            return false
        default:
            return true
        }
    })
}

public func makeApp(from appPath: String) -> AppRecord? {
    let real = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
    // One bundle-base resolution, which stats and lists `WrappedBundle` and
    // `Wrapper`.
    let bases = appBundleBases(real)
    let info = readInfoPlist(real, bases: bases)
    let name = stripBidiControls(
        (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    )
    var sourceDir = "other"
    var isSystem = false
    if real.hasPrefix("/System/") {
        sourceDir = "/System/Applications"
        isSystem = true
    } else {
        let homeApps = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Applications")
        for root in ["/Applications", homeApps] {
            let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            if real.hasPrefix(realRoot + "/") {
                sourceDir = root
                break
            }
        }
    }
    let bid = info["CFBundleIdentifier"] as? String
    if let bid, bid.posixLowercased().hasPrefix("com.apple.") {
        isSystem = true
    }
    var extra: [String: String] = [:]
    if let exe = info["CFBundleExecutable"] as? String { extra["executable"] = exe }
    if let ver = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) {
        extra["version"] = ver
    }
    if hasMasReceipt(real, bases: bases) { extra["mas_receipt"] = "1" }
    if let desc = plistDescription(info, appName: name) { extra["comment"] = desc }
    if let cat = categoryLabel(info["LSApplicationCategoryType"] as? String) { extra["category"] = cat }
    return AppRecord(path: real, displayName: name, bundleId: bid, sourceDir: sourceDir, isSystem: isSystem, extra: extra)
}

/// Desktop Entry string escapes (`\s` `\n` `\t` `\r` `\\`). `readDesktop`
/// skips them for the Exec, TryExec, and URL keys.
/// Byte walk: escapes are ASCII, and UTF-8 trail bytes never contain 0x5C,
/// so non-ASCII passes through untouched.
func unescapeDesktopValue(_ raw: String) -> String {
    guard raw.contains("\\") else { return raw }
    let bytes = Array(raw.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x5C, i + 1 < bytes.count {
            switch bytes[i + 1] {
            case 0x73: out.append(0x20) // s
            case 0x6E: out.append(0x0A) // n
            case 0x74: out.append(0x09) // t
            case 0x72: out.append(0x0D) // r
            case 0x5C: out.append(0x5C)
            default:
                out.append(bytes[i])
                out.append(bytes[i + 1])
            }
            i += 2
            continue
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

func readDesktop(_ path: String) -> [String: String] {
    guard let text = readUTF8File(path) else { return [:] }
    // Byte scan: `trimmingCharacters` bridges to NSString (UTF-16 decode +
    // retain churn, ~4% of a full scan in profiles). Keys are ASCII.
    let bytes = Array(text.utf8)
    let n = bytes.count
    var data: [String: String] = [:]
    var inEntry = false
    var i = 0
    func trim(_ s: Int, _ e: Int) -> (Int, Int) {
        var a = s
        var b = e
        while a < b, bytes[a] == 0x20 || bytes[a] == 0x09 || bytes[a] == 0x0D { a += 1 }
        while b > a, bytes[b - 1] == 0x20 || bytes[b - 1] == 0x09 || bytes[b - 1] == 0x0D { b -= 1 }
        return (a, b)
    }
    func str(_ s: Int, _ e: Int) -> String {
        String(decoding: bytes[s..<e], as: UTF8.self)
    }
    while i < n {
        var j = i
        while j < n, bytes[j] != 0x0A { j += 1 }
        let (s, e) = trim(i, j)
        // One CRLF (or run of breaks) is one boundary.
        while j < n, bytes[j] == 0x0A || bytes[j] == 0x0D { j += 1 }
        i = j
        guard s < e, bytes[s] != 0x23 /* # */ else { continue }
        if bytes[s] == 0x5B /* [ */ {
            // "[Desktop Entry]", matched on the trimmed line like before.
            inEntry = e - s == 15 &&
                bytes[s + 1] == 0x44 && bytes[s + 2] == 0x65 && bytes[s + 3] == 0x73 &&
                bytes[s + 4] == 0x6B && bytes[s + 5] == 0x74 && bytes[s + 6] == 0x6F &&
                bytes[s + 7] == 0x70 && bytes[s + 8] == 0x20 && bytes[s + 9] == 0x45 &&
                bytes[s + 10] == 0x6E && bytes[s + 11] == 0x74 && bytes[s + 12] == 0x72 &&
                bytes[s + 13] == 0x79 && bytes[s + 14] == 0x5D
            continue
        }
        guard inEntry else { continue }
        var eq = s
        while eq < e, bytes[eq] != 0x3D /* = */ { eq += 1 }
        guard eq < e else { continue }
        let (ks, ke) = trim(s, eq)
        guard ks < ke else { continue }
        let key = str(ks, ke)
        if data[key] != nil { continue }
        let (vs, ve) = trim(eq + 1, e)
        var val = str(vs, ve)
        if key != "Exec", key != "TryExec", key != "URL" {
            val = unescapeDesktopValue(val)
        }
        data[key] = val
    }
    return data
}

let linuxWrapperNames: Set<String> = [
    "flatpak", "snap", "env", "sh", "bash", "dash", "python", "python3",
]

/// Split an `Exec=` value the way the desktop entry spec does: a double-quoted
/// argument may contain spaces, a backslash escapes the next character inside a
/// quoted run, and leading `NAME=value` assignments are dropped so
/// `Exec=GDK_BACKEND=x myapp %U` resolves to `myapp`.
func execTokens(_ exec: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inQuotes = false
    var escaped = false
    var started = false
    for ch in exec {
        if escaped {
            current.append(ch)
            escaped = false
            continue
        }
        if ch == "\\", inQuotes {
            escaped = true
            continue
        }
        if ch == "\"" {
            inQuotes.toggle()
            started = true
            continue
        }
        if ch.isWhitespace, !inQuotes {
            if started {
                tokens.append(current)
                current = ""
                started = false
            }
            continue
        }
        current.append(ch)
        started = true
    }
    if started { tokens.append(current) }
    while let first = tokens.first, isEnvAssignment(first) {
        tokens.removeFirst()
    }
    return tokens
}

/// `NAME=value`, the shape a desktop entry puts before the command in an
/// `env`-launched `Exec` line. The name is non-empty and carries no `=`.
func isEnvAssignment(_ token: String) -> Bool {
    guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
    let name = token[token.startIndex..<eq]
    guard let first = name.unicodeScalars.first else { return false }
    guard first == "_" || CharacterSet.letters.contains(first) else { return false }
    return name.unicodeScalars.allSatisfy { $0 == "_" || $0 == "." || CharacterSet.alphanumerics.contains($0) }
}

func linuxDesktopSource(sourceDir: String, exec: String) -> String? {
    let dir = posixLowercased(sourceDir)
    let ex = posixLowercased(exec)
    if ex.contains(".appimage") { return "appimage" }
    if dir.contains("flatpak") || ex.contains("flatpak") { return "flatpak" }
    if dir.contains("snapd") { return "snap" }
    if dir.contains("/snap/") || dir.hasSuffix("/snap") { return "snap" }
    if let first = execTokens(exec).first {
        let base = posixLowercased(URL(fileURLWithPath: first).lastPathComponent)
        if base == "snap" { return "snap" }
    }
    return nil
}

func flatpakIdFromExec(_ exec: String) -> String? {
    let tokens = execTokens(exec)
    guard let run = tokens.firstIndex(of: "run") else { return nil }
    for t in tokens.dropFirst(run + 1) {
        if t.hasPrefix("-") { continue }
        return t
    }
    return nil
}

func linuxPkgId(source: String, desktopId: String, exec: String) -> String {
    switch source {
    case "flatpak":
        return flatpakIdFromExec(exec) ?? desktopId
    case "snap":
        if let head = desktopId.split(separator: "_").first, !head.isEmpty {
            return String(head)
        }
        return desktopId
    default:
        return desktopId
    }
}

/// The path a `.desktop` record names: the entry itself, except for an
/// AppImage, which is a single file the entry launches and the only one of the
/// two a removal can take with it.
///
/// The `Exec` binary is deliberately not the record's path. It is a path the
/// scan never listed — often a shared system binary, where the removal can only
/// be skipped — and `findLinuxApps` dedupes, sorts, and measures the record by
/// this path, so it has to be the file that was found. A wrapper's own name is
/// not the app either; that rule is in the identity below, which the dedupe
/// key depends on.
func linuxDesktopAppPath(source: String?, desktopPath: String, exec: String) -> String {
    if source == "appimage",
       let image = execTokens(exec).first(where: { posixLowercased($0).contains(".appimage") }),
       FileManager.default.fileExists(atPath: image) {
        return image
    }
    return desktopPath
}

public func parseDesktopFile(_ path: String, sourceDir: String = "") -> AppRecord? {
    let info = readDesktop(path)
    if info.isEmpty { return nil }
    if (info["Type"] ?? "Application") != "Application" { return nil }
    if posixLowercased(info["NoDisplay"] ?? "") == "true" || posixLowercased(info["Hidden"] ?? "") == "true" {
        return nil
    }
    let name = stripBidiControls(info["Name"] ?? "")
    guard !name.isEmpty else { return nil }
    var exe = ""
    let execLine = (info["Exec"] ?? "").trimmingCharacters(in: .whitespaces)
    if !execLine.isEmpty {
        exe = execTokens(execLine).first ?? ""
    }
    let wmclass = (info["StartupWMClass"] ?? "").trimmingCharacters(in: .whitespaces)
    let desktopId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let exeBase = URL(fileURLWithPath: exe).deletingPathExtension().lastPathComponent
    // A wrapper launches whatever it is told to, so its own name is not the
    // app's identity: every `flatpak run` export would answer `flatpak`, and
    // `findLinuxApps` dedupes on this value, so all but one would be dropped
    // from the scan. The desktop id names the entry that launched it.
    let identity = wmclass.isEmpty
        ? (exeBase.isEmpty || linuxWrapperNames.contains(posixLowercased(exeBase)) ? desktopId : exeBase)
        : wmclass
    // `StartupWMClass` is a `.desktop` key, so it is attacker-controlled the
    // same way `Name=` is, and this is the value `findLinuxApps` dedupes on.
    // The controls come out first, so the identity is spelled out of a string
    // that never held an invisible character: the fold passes a bidi override
    // through unchanged today, so the two orders agree, but only one of them
    // still agrees if a later fold ever acts on one.
    var bundleId = posixLowercased(stripBidiControls(identity))
    let linuxSource = linuxDesktopSource(sourceDir: sourceDir, exec: execLine)
    let appPath = linuxDesktopAppPath(source: linuxSource, desktopPath: path, exec: execLine)
    let isSystem = linuxSource == nil && sourceDir.hasPrefix("/usr/")
    var extra: [String: String] = [
        "desktop": path,
        "desktop_id": desktopId,
        "exec": execLine,
        "wmclass": wmclass,
        "executable": exe.isEmpty ? wmclass : URL(fileURLWithPath: exe).lastPathComponent,
    ]
    if let linuxSource {
        extra["linux_source"] = linuxSource
        extra["pkg_id"] = linuxPkgId(source: linuxSource, desktopId: desktopId, exec: execLine)
    }
    if let comment = info["Comment"]?.trimmingCharacters(in: .whitespaces), !comment.isEmpty {
        extra["comment"] = comment
    }
    let resolved = FileManager.default.fileExists(atPath: appPath)
        ? URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
        : appPath
    if bundleId.isEmpty { bundleId = posixLowercased(desktopId) }
    return AppRecord(
        path: resolved,
        displayName: name,
        bundleId: bundleId,
        sourceDir: sourceDir.isEmpty ? URL(fileURLWithPath: path).deletingLastPathComponent().path : sourceDir,
        isSystem: isSystem,
        extra: extra
    )
}

/// `steamLibraryRoots` and `bottlesDir` are the same injection points
/// `appendSteamApps` and `appendCrossOverBottles` already take, forwarded so a
/// caller that scopes the desktop directories can scope the game libraries too:
/// otherwise the games installed on the machine running the caller land in a
/// result that was asked to describe one directory.
private func finishAppDiscovery(
    _ apps: inout [AppRecord],
    seen: inout Set<String>,
    progress: (String) -> Void,
    steamLibraryRoots: [String]? = nil,
    bottlesDir: String? = nil
) {
    progress("  · discovering Steam games…")
    appendSteamApps(&apps, seen: &seen, libraryRoots: steamLibraryRoots)
    appendCrossOverBottles(&apps, seen: &seen, bottlesDir: bottlesDir)
    progress("  · measuring sizes for \(apps.count) apps…")
    let sizes = duSizes(apps.filter { !skipLiveDu($0) }.map(\.path))
    for i in apps.indices {
        if skipLiveDu(apps[i]) { continue }
        let pair = sizes[apps[i].path] ?? (0, false)
        apps[i].sizeBytes = pair.0
        apps[i].sizeMeasured = pair.1
    }
    apps.sort {
        collatedBefore($0.displayName, $1.displayName, tieBreak: $0.path, $1.path)
    }
}

public func findApps(progress: (String) -> Void = { _ in }) -> [AppRecord] {
    if PlatformOverride.isLinux {
        return findLinuxApps(progress: progress)
    }
    return findMacApps(progress: progress)
}

func findLinuxApps(
    progress: (String) -> Void,
    desktopDirs: [String]? = nil,
    steamLibraryRoots: [String]? = nil,
    bottlesDir: String? = nil
) -> [AppRecord] {
    progress("  · discovering .desktop applications…")
    var apps: [AppRecord] = []
    var seen = Set<String>()
    for root in desktopDirs ?? linuxDesktopDirs() {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for name in names.sorted() where name.hasSuffix(".desktop") {
            if name.hasPrefix("steam_app_") { continue }
            let path = (root as NSString).appendingPathComponent(name)
            guard let app = parseDesktopFile(path, sourceDir: root) else { continue }
            let key = app.bundleId ?? app.path
            if seen.insert(key).inserted { apps.append(app) }
        }
    }
    finishAppDiscovery(
        &apps,
        seen: &seen,
        progress: progress,
        steamLibraryRoots: steamLibraryRoots,
        bottlesDir: bottlesDir
    )
    return apps
}

private let mdfindMax = 400

func findViaMdfind(existing: Set<String>) -> [String] {
    let (rc, out, _) = runCommand(["mdfind", "kMDItemFSName == '*.app'"], timeout: 30)
    guard rc == 0 else { return [] }
    var found: [String] = []
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path.hasSuffix("/") { continue }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if existing.contains(real) { continue }
        if !isRealAppPath(real) { continue }
        found.append(real)
        if found.count >= mdfindMax { break }
    }
    return found
}

func findMacApps(progress: (String) -> Void) -> [AppRecord] {
    progress("  · discovering installed apps…")
    var paths: [String] = []
    var seen = Set<String>()
    let homeApps = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Applications")
    for root in ["/Applications", homeApps, "/System/Applications"] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
        for p in iterApps(in: root) {
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            if seen.insert(real).inserted { paths.append(real) }
        }
    }
    for p in findViaMdfind(existing: seen) {
        if seen.insert(p).inserted { paths.append(p) }
    }
    var apps = pmap(paths, workers: 16) { makeApp(from: $0) }.compactMap { $0 }
    finishAppDiscovery(&apps, seen: &seen, progress: progress)
    return apps
}

func dirContainsAppBundle(_ path: String) -> Bool {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
    return names.contains { $0.hasSuffix(".app") }
}

/// Drops leading and trailing `/` without allocating a `CharacterSet`.
func trimmedSlashes(_ s: String) -> String {
    var start = s.startIndex
    var end = s.endIndex
    while start < end, s[start] == "/" { start = s.index(after: start) }
    while start < end, s[s.index(before: end)] == "/" { end = s.index(before: end) }
    return String(s[start..<end])
}

/// Every directory that strictly contains one of `paths`, bare (no trailing
/// slash), so a lookup is a single `Set` probe instead of a prefix comparison
/// against every path. Cost is O(paths x depth) rather than O(paths x entries).
/// `""` and `"/"` are members because both spell the filesystem root, which
/// contains every path.
func strictAncestorDirs(of paths: [String]) -> Set<String> {
    var out: Set<String> = ["", "/"]
    for path in paths {
        var dir = (path as NSString).deletingLastPathComponent
        while dir != "/", !dir.isEmpty {
            out.insert(dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
    return out
}

public func nonAppEntriesIn(_ root: String) -> [String] {
    let skip: Set<String> = ["utilities"]
    var out: [String] = []
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    for name in names.sorted() {
        if name.hasSuffix(".app") || name.hasPrefix(".") { continue }
        if skip.contains(name.posixLowercased()) { continue }
        let path = (root as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, dirContainsAppBundle(path) {
            continue
        }
        out.append(path)
    }
    return out
}

func iterApps(in root: String, maxDepth: Int = 3) -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: root) else { return out }
    while let rel = enumerator.nextObject() as? String {
        let depth = rel.split(separator: "/").count
        if depth > maxDepth {
            enumerator.skipDescendants()
            continue
        }
        if rel.contains(".app/") {
            enumerator.skipDescendants()
            continue
        }
        if rel.hasSuffix(".app") {
            out.append((root as NSString).appendingPathComponent(rel))
            enumerator.skipDescendants()
        }
    }
    // The enumerator yields in filesystem order, which differs between runs and
    // between filesystems. Callers dedup on first sight, so an unsorted walk
    // picks a different survivor of the same bundle name each time.
    return out.sorted()
}
