import Foundation

public let appAliases: [String: [String]] = [
    "firefox": ["mozilla"],
    "firefoxwebbrowser": ["mozilla", "firefox"],
    "iterm": ["iterm2"],
    "iterm2": ["iterm"],
    "visualstudiocode": ["code", "vscode"],
    "vscode": ["code", "visualstudiocode"],
    "googlechrome": ["chrome"],
    "chromium": ["chrome"],
    "brave": ["bravesoftware"],
    "bravebrowser": ["bravesoftware", "brave"],
    "braveorigin": ["bravesoftware", "brave"],
    "zoom": ["zoomus", "zoomclient3rd", "zoomphone", "zoomchat"],
    "zoomus": ["zoom", "zoomclient3rd", "zoomphone", "zoomchat"],
    "kagi": ["orion", "kagimacos"],
    "orion": ["kagi", "kagimacos"],
    "kagimacos": ["kagi", "orion"],
]

let homeDotData = [
    ".mozilla", ".thunderbird", ".steam", ".wine", ".java",
    ".gradle", ".docker", ".kube", ".aws", ".gnupg", ".ssh",
    ".npm", ".cargo", ".rustup", ".android", ".m2",
]

let linuxSystemNames: Set<String> = [
    "fontconfig", "dconf", "gconf", "gtk-2.0", "gtk-3.0", "gtk-4.0", "glib-2.0",
    "pulse", "pipewire", "systemd", "user-dirs.dirs", "user-dirs.locale",
    "xdg", "mime", "icons", "themes", "applications", "desktop-directories",
    "ibus", "fcitx", "fcitx5", "environment.d", "procps", "tracker3",
    "upstart", "kde", "plasma", "xfce4", "recently-used.xbel", "flatpak",
    "containers", "Trash", "xorg", "session", "update-notifier",
    "dbus", "gvfs", "xdg-desktop-portal", "gnome-shell", "gnome-session",
    "snap", "fish", "zsh", "bash", "git", "nvim", "vim", "ssh", "gnupg",
    "aws", "docker",
    "tmux", "direnv", "starship", "asdf", "nvm", "pyenv", "rbenv", "rustup",
    "cargo", "npm", "yarn", "pnpm", "pip", "conda", "htop", "curl",
    "thumbnails", "mesa_shader_cache", "mesa_shader_cache_db", "nvidia",
    "gnome-software", "evolution", "update-manager", "gvfs-metadata",
    "man",
    "uv", "bun", "go", "helm", "gh", "virtualenv", "configstore",
    "node", "node-gyp", "bazelisk", "black", "pythonentrypoints",
    "swift", "gcloud", "btop", "wasmtime", "zls",
    "kube", "kubectl", "kubebuilder", "jetpack", "jetpackcache",
    "pacman", "yay", "paru", "makepkg", "dnf", "dnf5", "yum", "zypper", "rpm",
]

let snapSystemNames: Set<String> = [
    "bare", "core", "snapd", "gtk-common-themes", "gtk3-common-themes",
    "cups", "mesa-2404",
]

let appleServiceNames: Set<String> = [
    "cloudkit", "familycircle", "gamekit", "geoservices", "passkit",
    "animoji", "energykit", "temporaryitems", "sentrycrash",
    "apple", "icloud", "mobilesync",
    "crashreporter", "clouddocs", "callhistorydb", "callhistorytransactions",
    "callhistory", "fileprovider", "askpermission", "differentialprivacy",
    "diskimages", "knowledge", "icdd", "networkserviceproxy", "instruments",
    "addressbook", "ubiquity", "facetime", "messages", "syncservices",
    "applemediaservices", "appstore", "protectedcloudstorage", "replaykit",
    "screensharing", "controlcenter", "notificationcenter", "spotlight",
    "suggestions", "metadata", "ilifemediabrowser", "cloudsubscriptionfeatures",
    "studentd", "trustedpeers", "commerce", "corefollowup", "scripteditor",
    "systemprofiler", "dock", "windowmanager", "textinput", "batchsettings",
    "homebrew", "softwareupdate",
    "diagnosticreports", "diagnosticreportsfornewhardware", "coresimulator",
    "baseband", "loginwindow", "pbs", "sharedfilelist", "sharedfilelistd",
    "contextstoreagent", "mobilemeaccounts", "corespotlight", "corespotlightd",
    "cups", "printingprefs", "databases", "privacypreservingmeasurement",
    "sirittsservice", "familycircled", "diagnosticsagent", "icloudmailagent",
    "mbuseragent", "assistant", "tokenbucketratelimiter", "amsdatamigratortool",
    "tvappservices",
]

let sharedRuntimeNames: Set<String> = [
    "cef", "sentry", "branch", "qtproject", "wasmtime", "biome",
]

let genericDnsLabels: Set<String> = [
    "com", "org", "net", "edu", "gov", "mil", "int", "io", "me", "co",
    "uk", "de", "jp", "au", "us", "ca", "app", "dev", "info", "biz",
    "tv", "cc", "xyz", "id", "in", "eu", "ai",
]

let genericOwnerTokens: Set<String> = [
    "python", "python2", "python3", "node", "nodejs", "java", "ruby", "perl",
    "php", "lua", "bash", "sh", "zsh", "fish", "env", "electron", "helper",
    "app", "bin", "usr", "snap", "flatpak", "dialog", "agent", "desktop",
]

let genericVendorLabels: Set<String> = [
    "github", "gitlab",
]

let toolLeftoverAliases: [String: [String]] = [
    "wine": ["wineprefixes"],
    "playwright": ["minibrowser", "msplaywrightmcp"],
]

let teamIdVendors: [String: Set<String>] = [
    "ubf8t346g9": ["microsoft", "office"],
    "g69scx94xu": ["duckduckgo", "duck"],
]

let skipDescend: Set<String> = [
    "node_modules", ".git", "__pycache__", "Caches", "Cache",
    "DerivedData", ".cache",
]

let skipNestedRoots: Set<String> = ["Containers", "Group Containers", "WebKit"]

let bundleIdRE = try! NSRegularExpression(pattern: #"^[a-z0-9]+(\.[a-z0-9_\-]+)+$"#)
let daemonRE = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9]{8,}d$"#)
let teamIdRE = try! NSRegularExpression(pattern: #"^(?=.*[0-9])[A-Z0-9]{8,12}$"#, options: [.caseInsensitive])
let uuidRE = try! NSRegularExpression(pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: [.caseInsensitive])

func fullMatch(_ re: NSRegularExpression, _ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: range) else { return false }
    return m.range.location == 0 && m.range.length == (s as NSString).length
}

func isGenericOwnerToken(_ token: String) -> Bool {
    let t = posixLowercased(token.trimmingCharacters(in: .whitespaces))
    if t.isEmpty { return true }
    if genericOwnerTokens.contains(t) || t.hasPrefix("python") { return true }
    return false
}

public func expandNameAliases(_ n: String) -> Set<String> {
    let token = norm(n)
    if token.isEmpty { return [] }
    var out: Set<String> = [token]
    if let aliases = appAliases[token] {
        out.formUnion(aliases)
    }
    return out
}

public func classifyLinuxSystemName(_ name: String) -> (String, String?) {
    let n = posixLowercased(name)
    let nn = norm(name)
    if linuxSystemNames.contains(n) || linuxSystemNames.contains(nn) || n.hasPrefix("gtk-") || n.hasPrefix("xdg") {
        return ("system", nil)
    }
    if snapSystemNames.contains(n) {
        return ("system", nil)
    }
    if n.hasPrefix("core") && (n == "core" || n.dropFirst(4).allSatisfy(\.isNumber)) {
        return ("system", nil)
    }
    let parts = n.split(separator: "-")
    if n.hasPrefix("gnome-"), let last = parts.last, last.allSatisfy(\.isNumber) {
        return ("system", nil)
    }
    let stem = n.split { $0 == "-" || $0 == "_" }.first.map(String.init) ?? ""
    if linuxSystemNames.contains(stem), stem.count >= 2 {
        return ("system", nil)
    }
    return ("orphaned", nil)
}

public func xdgScanRoots(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [(String, String, String)] {
    let cfg = xdgConfigHome(home: home, env: env)
    let share = xdgDataHome(home: home, env: env)
    let cache = xdgCacheHome(home: home, env: env)
    let state = xdgStateHome(home: home, env: env)
    let lib = ((home as NSString).appendingPathComponent(".local") as NSString).appendingPathComponent("lib")
    return [
        (".config", cfg, "dir"),
        (".local/share", share, "dir"),
        (".cache", cache, "dir"),
        (".local/state", state, "dir"),
        (".local/lib", lib, "dir"),
    ]
}

public func scanRootsForPlatform() -> [(String, String, String)] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let xdg = xdgScanRoots(home: home)
    if PlatformOverride.isLinux {
        return xdg + [
            (".var/app", (home as NSString).appendingPathComponent(".var/app"), "dir"),
            ("snap", (home as NSString).appendingPathComponent("snap"), "dir"),
        ]
    }
    let lib = (home as NSString).appendingPathComponent("Library")
    return [
        ("Application Support", (lib as NSString).appendingPathComponent("Application Support"), "dir"),
        ("Caches", (lib as NSString).appendingPathComponent("Caches"), "dir"),
        ("Preferences", (lib as NSString).appendingPathComponent("Preferences"), "plist"),
        ("Saved Application State", (lib as NSString).appendingPathComponent("Saved Application State"), "savedstate"),
        ("Containers", (lib as NSString).appendingPathComponent("Containers"), "bundleid"),
        ("Group Containers", (lib as NSString).appendingPathComponent("Group Containers"), "group"),
        ("Logs", (lib as NSString).appendingPathComponent("Logs"), "dir"),
        ("WebKit", (lib as NSString).appendingPathComponent("WebKit"), "bundleid"),
        ("HTTPStorages", (lib as NSString).appendingPathComponent("HTTPStorages"), "mixed"),
    ] + xdg
}

public func homeDataLeaves() -> [(String, String)] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return homeDotData.map { ((home as NSString).appendingPathComponent($0), "leaf") }
}

public func includeScanEntry(_ path: String, kind: String) -> Bool {
    let base = URL(fileURLWithPath: path).lastPathComponent
    if base == ".DS_Store" || base == ".localized" { return false }
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if kind == "dir" || kind == "bundleid" || kind == "group" {
        return exists && isDir.boolValue
    }
    if kind == "plist" {
        return exists && !isDir.boolValue && path.hasSuffix(".plist")
    }
    if kind == "mixed" || kind == "leaf" {
        return exists
    }
    return exists
}

public final class DataItem {
    public var path: String
    public var name: String
    public var rootLabel: String
    public var kind: String
    public var status: String
    public var owner: String?
    public var sizeBytes: Int
    public var sizeMeasured: Bool
    public var mtime: Date?
    public var activityMtime: Date?
    public var reason: String?
    public var summary: String?
    public var extraPaths: [String]
    public var shadows: String?

    public init(
        path: String,
        name: String,
        rootLabel: String,
        kind: String,
        status: String = "orphaned",
        owner: String? = nil,
        shadows: String? = nil,
        sizeBytes: Int = 0,
        sizeMeasured: Bool = true,
        mtime: Date? = nil,
        activityMtime: Date? = nil,
        reason: String? = nil,
        summary: String? = nil,
        extraPaths: [String] = []
    ) {
        self.path = path
        self.name = name
        self.rootLabel = rootLabel
        self.kind = kind
        self.status = status
        self.owner = owner
        self.shadows = shadows
        self.sizeBytes = sizeBytes
        self.sizeMeasured = sizeMeasured
        self.mtime = mtime
        self.activityMtime = activityMtime
        self.reason = reason
        self.summary = summary
        self.extraPaths = extraPaths
    }

    public var leftoverStatus: LeftoverStatus? { LeftoverStatus(rawValue: status) }

    public func toLeftoverItem() -> LeftoverItem {
        LeftoverItem(
            name: name,
            path: path,
            root: rootLabel,
            kind: kind,
            status: status,
            owner: owner,
            size_bytes: sizeBytes,
            size_measured: sizeMeasured,
            mtime: isoString(activityMtime ?? mtime),
            reason: reason,
            summary: summary,
            extra_paths: extraPaths.isEmpty ? nil : extraPaths,
            shadows: shadows
        )
    }
}

public struct OrphanAgent {
    public var path: String
    public var label: String
    public var program: String
    public init(path: String, label: String, program: String) {
        self.path = path
        self.label = label
        self.program = program
    }
}

func dataItem(from agent: OrphanAgent, ident: Identity? = nil) -> DataItem {
    var status = "orphaned"
    var owner: String?
    if let ident {
        let base = URL(fileURLWithPath: agent.program).lastPathComponent
        if !isGenericOwnerToken(base) {
            let (st, own) = ident.classify(base, kind: "dir")
            if st == "owned" || st == "system" {
                status = "owned"
                owner = own
            }
        }
    }
    return DataItem(
        path: agent.path,
        name: agent.label,
        rootLabel: "LaunchAgents",
        kind: "plist",
        status: status,
        owner: owner
    )
}

public func skipNestedProbe(_ item: DataItem) -> Bool {
    if item.status == "system" { return true }
    if item.kind == "bundleid" || item.kind == "group" { return true }
    if skipNestedRoots.contains(item.rootLabel) { return true }
    return false
}

public func probeActivityMtime(
    _ path: String,
    maxEntries: Int = 80,
    maxDepth: Int = 2,
    timeout: TimeInterval = 0.2
) -> Date? {
    let start = monotonicSeconds()
    var best: Date?
    var seen = 0
    var stack: [(String, Int)] = [(path, 0)]
    while !stack.isEmpty {
        if monotonicSeconds() - start > timeout || seen >= maxEntries { break }
        let (current, depth) = stack.removeLast()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: current),
              let mtime = attrs[.modificationDate] as? Date
        else { continue }
        seen += 1
        if best == nil || mtime > best! { best = mtime }
        if depth >= maxDepth { continue }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: current, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
        for name in children.sorted() {
            if monotonicSeconds() - start > timeout || seen >= maxEntries { break }
            if name.hasPrefix(".") { continue }
            let child = (current as NSString).appendingPathComponent(name)
            if skipDescend.contains(name) {
                if let st = try? FileManager.default.attributesOfItem(atPath: child),
                   let mt = st[.modificationDate] as? Date {
                    seen += 1
                    if best == nil || mt > best! { best = mt }
                }
                continue
            }
            if depth + 1 <= maxDepth {
                stack.append((child, depth + 1))
            }
        }
    }
    return best
}

public func applyRecentActivity(_ items: [DataItem], now: Date = Date()) {
    for item in items {
        if item.status != "orphaned" { continue }
        if item.rootLabel == "LaunchAgents" { continue }
        if item.kind == "symlink" { continue }
        guard let dt = item.activityMtime ?? item.mtime else { continue }
        if let age = daysSince(dt, now: now), age <= Double(activeDays) {
            item.status = "active"
        }
    }
}

private let orphanKind: [String: String] = [
    "plist": "Preference leftover.",
    "savedstate": "Saved window leftover.",
    "bundleid": "Sandbox leftover.",
    "group": "App group leftover.",
    "leaf": "Home-directory leftover.",
    "symlink": "Broken PATH command. The tool is gone.",
]

private let orphanRoot: [String: String] = [
    "Application Support": "Application Support leftover.",
    "Caches": "Cache leftover.",
    "Logs": "Log leftover.",
    "WebKit": "WebKit leftover.",
    "HTTPStorages": "HTTP storage leftover.",
    ".config": "Config leftover.",
    ".local/share": "Share leftover.",
    ".cache": "Cache leftover.",
    ".local/state": "State leftover.",
    ".local/lib": ".local/lib leftover.",
    ".var/app": "Flatpak leftover.",
    "snap": "Snap leftover.",
    "home": "Home-directory leftover.",
    ".local/bin": "Broken PATH command. The tool is gone.",
    "Preferences": "Preference leftover.",
    "Saved Application State": "Saved window leftover.",
    "Containers": "Sandbox leftover.",
    "Group Containers": "App group leftover.",
]

private let summaryKind: [String: String] = [
    "plist": "Preference file",
    "savedstate": "Saved window state",
    "bundleid": "Sandbox container",
    "group": "App group container",
    "leaf": "Home-directory app data",
    "symlink": "Broken command",
]

private let summaryRoot: [String: String] = [
    "Application Support": "Application Support folder",
    "Caches": "Cache folder",
    "Logs": "Log folder",
    "WebKit": "WebKit data",
    "HTTPStorages": "HTTP storage",
    "Preferences": "Preference file",
    "Saved Application State": "Saved window state",
    "Containers": "Sandbox container",
    "Group Containers": "App group container",
    ".config": ".config data",
    ".local/share": ".local/share data",
    ".cache": "Cache folder",
    ".local/state": "State data",
    ".local/lib": ".local/lib data",
    ".var/app": "Flatpak data folder",
    "snap": "Snap data folder",
    "home": "Home-directory app data",
    ".local/bin": "Broken command",
]

let leftoverNameSuffixes = [".savedstate", ".plist", ".binarycookies"]

func stripLeftoverNameSuffix(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let low = posixLowercased(trimmed)
    for suffix in leftoverNameSuffixes {
        if low.hasSuffix(suffix) {
            return String(trimmed.dropLast(suffix.count))
        }
    }
    return trimmed
}

func entryLabel(_ name: String) -> String {
    stripLeftoverNameSuffix(name)
}

public func leftoverLocationLabel(rootLabel: String, extraCount: Int) -> String {
    extraCount <= 0 ? rootLabel : "\(rootLabel) +\(extraCount)"
}

let leftoverDisplaySkipTokens: Set<String> = [
    "helper", "agent", "family", "safari", "chrome", "desktop",
    "updater", "shipit", "plist", "group",
]

func leftoverTitleCase(_ name: String) -> String {
    if name.contains(".") || name.contains("_") || name.contains("-") { return name }
    if name.contains(where: { $0.isUppercase }) { return name }
    guard let first = name.first else { return name }
    return String(first).uppercased() + name.dropFirst()
}

func isSimpleLeftoverLabel(_ label: String) -> Bool {
    if label.hasPrefix("@") || label.contains(".") { return false }
    return label.count >= 2
}

func prettyDnsLeftoverLabel(_ label: String) -> String? {
    var core = label
    if core.hasPrefix("@") {
        core = String(core.dropFirst())
        if let canon = leftoverProductAliases[norm(core)] { return leftoverTitleCase(canon) }
        return nil
    }
    if !core.contains(".") { return core }
    let parts = core.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    for part in parts.reversed() {
        let low = part.lowercased()
        if genericDnsLabels.contains(low) { continue }
        if genericVendorLabels.contains(norm(part)) { continue }
        if isGenericOwnerToken(part) { continue }
        if leftoverDisplaySkipTokens.contains(low) { continue }
        if fullMatch(teamIdRE, part) { continue }
        if part.count < 3 { continue }
        return part
    }
    return nil
}

public func leftoverDisplayName(name: String, extraPaths: [String] = []) -> String {
    let labels = ([name] + extraPaths.map { URL(fileURLWithPath: $0).lastPathComponent }).map(entryLabel)
    if let simple = labels.first(where: isSimpleLeftoverLabel) {
        return simple
    }
    for label in labels {
        if let pretty = prettyDnsLeftoverLabel(label) {
            return leftoverTitleCase(pretty)
        }
    }
    return leftoverTitleCase(entryLabel(name))
}

func isUserBinLeftoverPath(_ path: String) -> Bool {
    path.contains("/.local/bin/")
        || path.contains("/usr/local/bin/")
        || path.contains("/opt/homebrew/bin/")
        || path.contains("/.linuxbrew/bin/")
}

private func leftoverMatchesCategory(
    name: String,
    path: String,
    rootLabel: String,
    status: String,
    extraPaths: [String],
    shadows: String?,
    categories: [String]
) -> Bool {
    guard !categories.isEmpty else { return true }
    let cats = categories.map { $0.lowercased() }
    let fields = [
        name,
        leftoverDisplayName(name: name, extraPaths: extraPaths),
        path,
        rootLabel,
        status,
        shadows ?? "",
    ] + extraPaths
    return fields.contains { field in
        let low = field.lowercased()
        return cats.contains { low.contains($0) }
    }
}

public func leftoverMatchesCategory(_ item: DataItem, categories: [String]) -> Bool {
    leftoverMatchesCategory(
        name: item.name,
        path: item.path,
        rootLabel: item.rootLabel,
        status: item.status,
        extraPaths: item.extraPaths,
        shadows: item.shadows,
        categories: categories
    )
}

public func leftoverMatchesCategory(_ item: LeftoverItem, categories: [String]) -> Bool {
    leftoverMatchesCategory(
        name: item.name,
        path: item.path,
        rootLabel: item.root,
        status: item.status,
        extraPaths: item.extra_paths ?? [],
        shadows: item.shadows,
        categories: categories
    )
}

func shadowSummary(name: String, kind: String, packaged: String) -> String {
    let overlay = kind == "desktop" ? "desktop overlay" : "PATH overlay"
    if name.isEmpty {
        return "\(overlay.prefix(1).uppercased())\(overlay.dropFirst()). Hides the packaged \(packaged)."
    }
    return "\(name) is a \(overlay). Hides the packaged \(packaged)."
}

func shadowReason(kind: String, packaged: String) -> String {
    if kind == "desktop" {
        return "This .desktop file takes precedence over the package-manager file \(packaged)."
    }
    return "This file is earlier on PATH than the package-manager file \(packaged)."
}

public func leftoverSummary(
    rootLabel: String,
    kind: String,
    name: String = "",
    extraPaths: [String] = [],
    appBlurb: String? = nil,
    shadows: String? = nil
) -> String {
    if let shadows, !shadows.isEmpty {
        return shadowSummary(name: name, kind: kind, packaged: shadows)
    }
    let what: String
    if rootLabel == "LaunchAgents" {
        what = "LaunchAgent"
    } else {
        what = summaryKind[kind] ?? summaryRoot[rootLabel] ?? "\(rootLabel) data"
    }
    let label = leftoverDisplayName(name: name, extraPaths: extraPaths)
    let extra = extraPaths.isEmpty ? "" : " and \(extraPaths.count) more"
    if let blurb = shortDesc(appBlurb ?? leftoverAppBlurb(name: name, extraPaths: extraPaths)), !blurb.isEmpty {
        let who = label.isEmpty ? "" : "\(label): "
        return "\(who)\(blurb). Leftover \(what)\(extra)."
    }
    if label.isEmpty {
        return "Leftover \(what) from an uninstalled app\(extra)."
    }
    return "\(label) is no longer installed. Leftover \(what)\(extra)."
}

/// Stored leftover "what" text is usable as-is (mentions leftover or a packaged overlay).
public func leftoverWhatLooksCurrent(_ summary: String) -> Bool {
    summary.localizedCaseInsensitiveContains("leftover ")
        || summary.localizedCaseInsensitiveContains("hides the packaged")
}

public func leftoverWhatText(
    rootLabel: String,
    kind: String,
    name: String,
    extraPaths: [String] = [],
    storedSummary: String? = nil,
    shadows: String? = nil
) -> String {
    if let shadows, !shadows.isEmpty {
        if let storedSummary, storedSummary.localizedCaseInsensitiveContains("hides the packaged") {
            return storedSummary
        }
        return leftoverSummary(rootLabel: rootLabel, kind: kind, name: name, extraPaths: extraPaths, shadows: shadows)
    }
    if let storedSummary, leftoverWhatLooksCurrent(storedSummary) {
        return storedSummary
    }
    return leftoverSummary(rootLabel: rootLabel, kind: kind, name: name, extraPaths: extraPaths)
}

public func orphanReason(rootLabel: String, kind: String) -> String {
    if rootLabel == "LaunchAgents" {
        return "LaunchAgent whose target program is no longer installed."
    }
    if let t = orphanKind[kind] { return t }
    if let t = orphanRoot[rootLabel] { return t }
    return "\(rootLabel) data that no installed app or brew package claims."
}

/// Stored leftover "why" text is usable as-is (overlay, broken PATH, leftover, LaunchAgent, or unclaimed).
public func leftoverWhyLooksCurrent(_ reason: String) -> Bool {
    reason.localizedCaseInsensitiveContains("package-manager file")
        || reason.localizedCaseInsensitiveContains("Broken PATH")
        || reason.localizedCaseInsensitiveContains("leftover")
        || reason.localizedCaseInsensitiveContains("LaunchAgent")
        || reason.localizedCaseInsensitiveContains("no installed app")
}

public func leftoverWhyText(
    rootLabel: String,
    kind: String,
    extraPaths: [String] = [],
    storedReason: String? = nil,
    shadows: String? = nil
) -> String {
    if let storedReason, leftoverWhyLooksCurrent(storedReason) {
        return storedReason
    }
    if let shadows, !shadows.isEmpty {
        return shadowReason(kind: kind, packaged: shadows)
    }
    if kind == "symlink" {
        if extraPaths.isEmpty {
            return orphanReason(rootLabel: rootLabel, kind: kind)
        }
        let n = 1 + extraPaths.count
        return "Broken PATH command. \(n) leftover names. The tool is gone."
    }
    var reason = orphanReason(rootLabel: rootLabel, kind: kind)
    if extraPaths.isEmpty { return reason }
    let pathN = extraPaths.filter(isUserBinLeftoverPath).count
    if extraPaths.count > pathN {
        reason = "Leftover data in \(1 + extraPaths.count) places."
    }
    if pathN > 0 {
        reason = "\(reason) Also \(pathN) leftover name\(pathN == 1 ? "" : "s") on PATH."
    }
    return reason
}

public func applyOrphanReasons(_ items: [DataItem], catalog: [String: String] = [:]) {
    for item in items {
        if item.status == "orphaned" {
            item.reason = leftoverWhyText(rootLabel: item.rootLabel, kind: item.kind, extraPaths: item.extraPaths)
            item.summary = leftoverSummary(
                rootLabel: item.rootLabel,
                kind: item.kind,
                name: item.name,
                extraPaths: item.extraPaths,
                appBlurb: leftoverAppBlurb(name: item.name, extraPaths: item.extraPaths, catalog: catalog)
            )
        } else if item.status == "shadow" {
            item.reason = leftoverWhyText(
                rootLabel: item.rootLabel,
                kind: item.kind,
                extraPaths: item.extraPaths,
                shadows: item.shadows
            )
            item.summary = leftoverSummary(
                rootLabel: item.rootLabel,
                kind: item.kind,
                name: item.name,
                extraPaths: item.extraPaths,
                shadows: item.shadows
            )
        } else {
            item.reason = nil
            item.summary = nil
        }
    }
}

func groupOrphanedLeftovers(_ items: [DataItem]) -> [DataItem] {
    var buckets: [String: [DataItem]] = [:]
    for item in items {
        guard item.status == "orphaned", item.rootLabel != "LaunchAgents" else { continue }
        let key = leftoverGroupKey(item.name)
        guard !key.isEmpty else { continue }
        buckets[key, default: []].append(item)
    }
    collapseBundleIdChildBuckets(&buckets)
    collapseVendorPrefixBuckets(&buckets)
    let mergeKeys = Set(buckets.compactMap { $0.value.count > 1 ? $0.key : nil })
    var consumed = Set<ObjectIdentifier>()
    var out: [DataItem] = []
    for item in items {
        let id = ObjectIdentifier(item)
        if consumed.contains(id) { continue }
        let key = leftoverBucketKey(item, buckets: buckets)
        if item.status == "orphaned", item.rootLabel != "LaunchAgents", mergeKeys.contains(key),
           let group = buckets[key]
        {
            out.append(mergeOrphanGroup(group))
            for member in group { consumed.insert(ObjectIdentifier(member)) }
            continue
        }
        out.append(item)
    }
    return out
}

let leftoverProductAliases: [String: String] = [
    "orion": "kagi",
    "mmxagentelectronupdater": "minimax",
    "betterdisplay": "betterdisplay",
]

let leftoverProductBlurbs: [String: String] = [
    "orion": "Web browser from Kagi",
    "kagi": "Web browser from Kagi",
    "kagimacos": "Web browser from Kagi",
    "betterdisplay": "Display manager for Mac",
    "whisky": "Wine wrapper for Windows games",
    "minimax": "MiniMax desktop agent",
    "mmxagentelectronupdater": "MiniMax desktop agent",
]

let leftoverLookupSkip: Set<String> = leftoverDisplaySkipTokens.union([
    "com", "org", "net", "io", "app", "www", "macos", "mac", "osx",
])

public func leftoverLookupTokens(name: String, extraPaths: [String] = []) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    func add(_ raw: String) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix(".") { t = String(t.dropFirst()) }
        t = stripLeftoverNameSuffix(t)
        let low = posixLowercased(t)
        if low.count < 2 { return }
        if leftoverLookupSkip.contains(low) { return }
        if leftoverLookupSkip.contains(norm(t)) { return }
        if genericDnsLabels.contains(low) { return }
        if seen.insert(low).inserted { out.append(low) }
        let dashed = low.replacingOccurrences(of: " ", with: "-")
        if dashed != low, seen.insert(dashed).inserted { out.append(dashed) }
    }
    add(leftoverDisplayName(name: name, extraPaths: extraPaths))
    add(entryLabel(name))
    for part in entryLabel(name).split(separator: ".") {
        add(String(part))
    }
    for path in extraPaths {
        add(URL(fileURLWithPath: path).lastPathComponent)
    }
    let grouped = leftoverGroupKey(name)
    add(grouped)
    if let canon = leftoverProductAliases[grouped] {
        add(canon)
    }
    return out
}

public func leftoverAppBlurb(name: String, extraPaths: [String] = [], catalog: [String: String] = [:]) -> String? {
    for token in leftoverLookupTokens(name: name, extraPaths: extraPaths) {
        if let blurb = leftoverProductBlurbs[norm(token)] { return shortDesc(blurb) }
        if let blurb = catalog[token] { return shortDesc(blurb) }
        if let blurb = catalog[norm(token)] { return shortDesc(blurb) }
    }
    return nil
}

public func leftoverBlurbsFromSnapshot(_ brew: BrewSnapshot) -> [String: String] {
    var catalog: [String: String] = [:]
    func put(_ key: String, _ desc: String?) {
        guard let desc, !desc.isEmpty else { return }
        catalog[key.lowercased()] = desc
        catalog[norm(key)] = desc
    }
    for f in brew.formulas { put(f.name, f.desc) }
    for c in brew.casks {
        put(c.name, c.desc)
        for title in c.titles { put(title, c.desc) }
        for app in c.appNames {
            put(URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent, c.desc)
        }
    }
    return catalog
}

public func leftoverBlurbsFromBrew(
    tokens: [String],
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand,
    limit: Int = 24
) -> [String: String] {
    guard let brew = which("brew") else { return [:] }
    var seen = Set<String>()
    let names = tokens.filter { token in
        guard token.count >= 2 else { return false }
        return seen.insert(token.lowercased()).inserted
    }.prefix(limit).map { $0 }
    guard !names.isEmpty else { return [:] }
    let data = infoJSONForNames(brew: brew, names: names, run: run)
    let (summaries, titles) = brewPackageMeta(data)
    var catalog: [String: String] = [:]
    for (name, desc) in summaries {
        catalog[name.lowercased()] = desc
        catalog[norm(name)] = desc
    }
    for (token, title) in titles {
        if let desc = summaries[token] {
            catalog[title.lowercased()] = desc
            catalog[norm(title)] = desc
        }
    }
    return catalog
}

public func applyLeftoverAppBlurbs(
    _ items: [DataItem],
    brew: BrewSnapshot = BrewSnapshot(available: false),
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand,
    progress: (String) -> Void = { _ in }
) {
    var catalog = leftoverBlurbsFromSnapshot(brew)
    let needed = items.filter { $0.status == "orphaned" }.compactMap { item -> String? in
        leftoverLookupTokens(name: item.name, extraPaths: item.extraPaths).first { token in
            leftoverProductBlurbs[norm(token)] == nil && catalog[token] == nil && catalog[norm(token)] == nil
        }
    }
    if !needed.isEmpty, brew.available, which("brew") != nil {
        progress("  · looking up leftover app descriptions…")
        for (key, desc) in leftoverBlurbsFromBrew(tokens: needed, which: which, run: run) {
            catalog[key] = desc
        }
    }
    applyOrphanReasons(items, catalog: catalog)
}

func leftoverGroupKey(_ name: String) -> String {
    let label = entryLabel(name)
    let n = norm(label)
    if let canon = leftoverProductAliases[n] { return canon }
    if leftoverProductAliases.values.contains(n) { return n }
    for part in posixLowercased(label).split(separator: ".") {
        let p = norm(String(part))
        if let canon = leftoverProductAliases[p] { return canon }
        if leftoverProductAliases.values.contains(p) { return p }
    }
    return n
}

func leftoverBucketKey(_ item: DataItem, buckets: [String: [DataItem]]) -> String {
    let own = leftoverGroupKey(item.name)
    if buckets[own] != nil { return own }
    for (key, group) in buckets where group.contains(where: { $0 === item }) {
        return key
    }
    return own
}

func isBundleIdChild(_ childName: String, of parentName: String) -> Bool {
    let child = entryLabel(childName)
    let parent = entryLabel(parentName)
    guard parent.contains(".") else { return false }
    return posixLowercased(child).hasPrefix(posixLowercased(parent) + ".")
}

func collapseBundleIdChildBuckets(_ buckets: inout [String: [DataItem]]) {
    let keys = buckets.keys.sorted { $0.count > $1.count }
    for childKey in keys {
        guard let childItems = buckets[childKey] else { continue }
        var bestParent: String?
        var bestLen = 0
        for (parentKey, parentItems) in buckets where parentKey != childKey {
            let hit = childItems.contains { child in
                parentItems.contains { parent in isBundleIdChild(child.name, of: parent.name) }
            }
            guard hit else { continue }
            let plen = parentItems.map { entryLabel($0.name).count }.max() ?? 0
            if plen > bestLen {
                bestLen = plen
                bestParent = parentKey
            }
        }
        if let parentKey = bestParent, let moving = buckets.removeValue(forKey: childKey) {
            buckets[parentKey, default: []].append(contentsOf: moving)
        }
    }
}

func dnsVendorPrefix(_ name: String) -> String? {
    let parts = entryLabel(name).split(separator: ".").map { $0.lowercased() }.filter { !$0.isEmpty }
    guard parts.count >= 3, genericDnsLabels.contains(parts[0]), parts[1].count >= 3 else { return nil }
    if genericVendorLabels.contains(norm(parts[1])) { return nil }
    return parts[0] + "." + parts[1]
}

func collapseVendorPrefixBuckets(_ buckets: inout [String: [DataItem]]) {
    var byPrefix: [String: [String]] = [:]
    for (key, items) in buckets {
        let prefixes = Set(items.compactMap { dnsVendorPrefix($0.name) })
        guard prefixes.count == 1, let prefix = prefixes.first else { continue }
        byPrefix[prefix, default: []].append(key)
    }
    for keys in byPrefix.values where keys.count > 1 {
        let primary = keys.max { a, b in
            (buckets[a]?.reduce(0) { addBytes($0, $1.sizeBytes) } ?? 0)
                < (buckets[b]?.reduce(0) { addBytes($0, $1.sizeBytes) } ?? 0)
        }!
        for key in keys where key != primary {
            if let moving = buckets.removeValue(forKey: key) {
                buckets[primary, default: []].append(contentsOf: moving)
            }
        }
    }
}

func preferredLeftoverPrimary(_ group: [DataItem]) -> DataItem {
    group.max { a, b in
        let aSym = a.kind == "symlink"
        let bSym = b.kind == "symlink"
        if aSym != bSym { return aSym && !bSym }
        if a.sizeBytes != b.sizeBytes { return a.sizeBytes < b.sizeBytes }
        return a.path > b.path
    }!
}

func mergeOrphanGroup(_ group: [DataItem]) -> DataItem {
    let primary = preferredLeftoverPrimary(group)
    var seen = Set([primary.path])
    var extras: [String] = []
    for item in group {
        if seen.insert(item.path).inserted { extras.append(item.path) }
        for path in item.extraPaths where seen.insert(path).inserted {
            extras.append(path)
        }
    }
    primary.extraPaths = extras.sorted()
    primary.sizeBytes = group.reduce(0) { addBytes($0, $1.sizeBytes) }
    primary.sizeMeasured = group.contains { $0.sizeMeasured }
    primary.mtime = group.compactMap(\.mtime).max() ?? primary.mtime
    primary.activityMtime = group.compactMap(\.activityMtime).max() ?? primary.activityMtime
    return primary
}

func vendorFromBid(_ bundleId: String) -> String? {
    let labels = bundleId.lowercased().split(separator: ".").map(String.init).filter { !$0.isEmpty }
    if labels.isEmpty { return nil }
    var i = 0
    if genericDnsLabels.contains(labels[0]) {
        i = 1
    }
    guard i < labels.count else { return nil }
    if genericVendorLabels.contains(norm(labels[i])) {
        i += 1
    }
    guard i < labels.count else { return nil }
    let vendor = norm(labels[i])
    if vendor.count < 3 || genericDnsLabels.contains(vendor) || genericVendorLabels.contains(vendor) {
        return nil
    }
    return vendor
}

public final class Identity {
    public var names: Set<String> = []
    public var bundleIds: Set<String> = []
    public var shortIds: Set<String> = []
    public var affinity: Set<String> = []
    public var brewNames: Set<String> = []
    public var brewRaw: Set<String> = []
    public var appByBid: [String: String] = [:]
    public var nameOwner: [String: String] = [:]
    public var stems: Set<String> = []

    public init(apps: [AppRecord], brew: BrewSnapshot, toolNames: [String] = []) {
        for a in apps {
            let base: String
            if a.path.hasSuffix(".app") {
                base = URL(fileURLWithPath: a.path).deletingPathExtension().lastPathComponent
            } else {
                base = a.displayName
            }
            for candidate in [a.displayName, base] {
                addName(candidate, owner: a.displayName)
            }
            if let bidRaw = a.bundleId {
                let b = bidRaw.lowercased()
                bundleIds.insert(b)
                appByBid[b] = a.displayName
                if !b.contains("."), b.count >= 4 {
                    shortIds.insert(b)
                }
                let last = b.split(separator: ".").last.map(String.init) ?? ""
                if norm(last).count >= 4, !isGenericOwnerToken(last) {
                    addName(last, owner: a.displayName)
                }
                if let vendor = vendorFromBid(b) {
                    affinity.insert(vendor)
                }
            }
            ingestDesktop(a)
            if a.extra["steam_appid"] != nil || a.extra["steam_client"] == "1" {
                addName("steam", owner: "Steam")
                if let dir = a.extra["steam_installdir"], !dir.isEmpty {
                    addName(dir, owner: a.displayName)
                }
                if let steamName = a.extra["steam_name"], !steamName.isEmpty {
                    addName(steamName, owner: a.displayName)
                }
            }
            if a.extra["crossover_bottle"] == "1" {
                addName(a.displayName, owner: a.displayName)
                addName("crossover", owner: "CrossOver")
            }
        }
        if brew.available {
            for name in brew.allNames {
                let n = norm(name)
                if !n.isEmpty { brewNames.insert(n) }
                brewRaw.insert(name.lowercased())
            }
        }
        for raw in toolNames {
            let base = URL(fileURLWithPath: raw).lastPathComponent
            if isGenericOwnerToken(base) { continue }
            let n = norm(base)
            if n.count < 2 { continue }
            brewNames.insert(n)
            brewRaw.insert(base.lowercased())
            for alias in toolLeftoverAliases[n] ?? [] {
                brewNames.insert(alias)
            }
        }
    }

    func addStem(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return }
        s = URL(fileURLWithPath: s).deletingPathExtension().lastPathComponent
        if s.hasSuffix(".app") { s = String(s.dropLast(4)) }
        if s.count >= 5 { stems.insert(s) }
        let first = s.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if first.count >= 5 { stems.insert(first) }
    }

    func addName(_ raw: String, owner: String? = nil) {
        addStem(raw)
        for token in expandNameAliases(raw) {
            names.insert(token)
            if token.count >= 5 { stems.insert(token) }
            if let owner, nameOwner[token] == nil {
                nameOwner[token] = owner
            }
        }
    }

    func ownedByStem(_ entry: String) -> Bool {
        let e = stripLeftoverNameSuffix(entry).lowercased()
        for stem in stems {
            if stem.count < 5 { continue }
            if e == stem { return true }
            for sep in ["-", "_", "."] {
                if e.hasPrefix(stem + sep) { return true }
            }
        }
        return false
    }

    func ingestDesktop(_ app: AppRecord) {
        let extra = app.extra
        var stem = extra["desktop_id"] ?? ""
        let desktop = extra["desktop"] ?? ""
        if stem.isEmpty, !desktop.isEmpty {
            stem = URL(fileURLWithPath: desktop).deletingPathExtension().lastPathComponent
        }
        for key in ["wmclass", "executable"] {
            guard let val = extra[key], !val.isEmpty else { continue }
            let token = URL(fileURLWithPath: val).deletingPathExtension().lastPathComponent
            if !token.isEmpty, !isGenericOwnerToken(token) {
                addName(token, owner: app.displayName)
            }
        }
        if stem.isEmpty { return }
        let d = stem.lowercased()
        if fullMatch(bundleIdRE, d) {
            bundleIds.insert(d)
            if appByBid[d] == nil { appByBid[d] = app.displayName }
            if let vendor = vendorFromBid(d) { affinity.insert(vendor) }
            let last = d.split(separator: ".").last.map(String.init) ?? ""
            if norm(last).count >= 4, !isGenericOwnerToken(last) {
                addName(last, owner: app.displayName)
            }
            if !last.contains("."), last.count >= 4, !isGenericOwnerToken(last) {
                shortIds.insert(last)
            }
        } else {
            addName(d, owner: app.displayName)
            if d.contains("_") {
                for part in d.split(separator: "_") {
                    let p = String(part)
                    if p.count >= 4, !isGenericOwnerToken(p) {
                        addName(p, owner: app.displayName)
                    }
                }
            }
        }
    }

    public func classify(_ name: String, kind: String) -> (String, String?) {
        let core = stripLeftoverNameSuffix(name)
        let low = core.lowercased()
        let n = norm(core)
        let bidLike = ["bundleid", "group", "savedstate", "plist"].contains(kind) || fullMatch(bundleIdRE, low)
        if bidLike {
            var b = low
            if b.hasPrefix("group.") { b = String(b.dropFirst("group.".count)) }
            if let res = classifyBid(b) { return res }
        }
        if names.contains(n) { return ("owned", nameOwner[n]) }
        if brewNames.contains(n) { return ("owned", nil) }
        if affinity.contains(n) { return ("owned", nil) }
        let first = core.split { " \t._-".contains($0) }.first.map(String.init) ?? ""
        let fn = norm(first)
        if affinity.contains(fn), fn.count >= 5 { return ("owned", nil) }
        if ownedByStem(core) { return ("owned", nameOwner[n]) }
        var brewKey = low
        let scoped = brewKey.hasPrefix("@")
        if scoped {
            brewKey = String(brewKey.dropFirst())
        }
        for b in brewRaw {
            if isGenericOwnerToken(b) { continue }
            if !scoped, !b.contains("-") { continue }
            if b.count >= 2, brewKey.hasPrefix(b) {
                let rest = brewKey.dropFirst(b.count)
                if rest.isEmpty || !(rest.first?.isLetter == true || rest.first?.isNumber == true) {
                    return ("owned", nil)
                }
            }
        }
        if fullMatch(uuidRE, core) { return ("system", nil) }
        let user = currentUsername()
        if !user.isEmpty, (low == user || n == norm(user)) { return ("system", nil) }
        if appleServiceNames.contains(n) || fullMatch(daemonRE, low) || n.contains("ratelimiter") || n.contains("loginwindow") {
            return ("system", nil)
        }
        if sharedRuntimeNames.contains(n) || sharedRuntimeNames.contains(low) { return ("system", nil) }
        let (st, owner) = classifyLinuxSystemName(name)
        if st == "system" { return (st, owner) }
        return ("orphaned", nil)
    }

    func classifyBid(_ b: String) -> (String, String?)? {
        let labels = b.split(separator: ".").map(String.init)
        if bundleIds.contains(b) { return ("owned", appByBid[b]) }
        if b.hasPrefix("com.apple.")
            || b == "com.appattic"
            || b.hasPrefix("com.appattic.")
            || b.hasPrefix("org.swift.")
            || b.hasPrefix("org.cups.")
            || b.hasPrefix("is.workflow.")
            || labels.contains(where: { sharedRuntimeNames.contains($0) })
            || labels.contains(where: {
                let token = norm($0)
                return token != "apple" && appleServiceNames.contains(token)
            })
        {
            return ("system", nil)
        }
        if let vendor = vendorFromBid(b),
           affinity.contains(vendor) || names.contains(vendor) || stems.contains(vendor) || brewNames.contains(vendor) {
            return ("owned", nil)
        }
        let last = labels.last ?? ""
        let lastN = norm(last)
        if vendorFromBid(b) == nil, !isGenericOwnerToken(last) {
            if shortIds.contains(last) || bundleIds.contains(last) {
                return ("owned", appByBid[last] ?? appByBid[b])
            }
            if !lastN.isEmpty, names.contains(lastN) {
                return ("owned", nameOwner[lastN])
            }
            if !last.isEmpty, ownedByStem(last) {
                return ("owned", nameOwner[lastN])
            }
        }
        if lastN.count >= 5, brewNames.contains(lastN), !isGenericOwnerToken(lastN) {
            return ("owned", nil)
        }
        if labels.count >= 2, fullMatch(teamIdRE, labels[0]) {
            let tokens = teamIdVendors[labels[0].lowercased()] ?? []
            let known = affinity.union(names).union(stems)
            if !tokens.isDisjoint(with: known) { return ("owned", nil) }
            return classifyBid(labels.dropFirst().joined(separator: "."))
        }
        if labels.count > 2 {
            return classifyBid(labels.dropFirst().joined(separator: "."))
        }
        return nil
    }
}

func listEntries(_ root: String) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    return names.filter { !$0.hasPrefix(".") }.sorted().map { (root as NSString).appendingPathComponent($0) }
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
    var dirs = [(home as NSString).appendingPathComponent(".local/bin")]
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
            name: primary.name,
            rootLabel: userBinRootLabel(URL(fileURLWithPath: primary.path).deletingLastPathComponent().path),
            kind: "symlink",
            status: "orphaned",
            extraPaths: extra
        ))
    }
    return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        for name in names where !name.hasPrefix(".") {
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
                status: "shadow",
                shadows: packaged
            ))
        }
    }
    return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func preferredBrokenLinkName(_ names: [String], toolFolder: String) -> String {
    let variants = [
        toolFolder,
        toolFolder.replacingOccurrences(of: "-", with: "_"),
        toolFolder.replacingOccurrences(of: "_", with: "-"),
    ]
    if let hit = names.first(where: { variants.contains($0) }) { return hit }
    let sorted = names.sorted { $0.count < $1.count }
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
    return (noDot.isEmpty ? names : noDot).max(by: { $0.count < $1.count }) ?? names[0]
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

public func appsFromPathBinaries(dirs: [String]? = nil) -> [AppRecord] {
    let fm = FileManager.default
    var out: [AppRecord] = []
    var seen = Set<String>()
    for dir in dirs ?? defaultUserToolDirs() {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { continue }
            guard fm.isExecutableFile(atPath: path) else { continue }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard let bundle = enclosingAppBundle(real), seen.insert(bundle).inserted else { continue }
            if let app = makeApp(from: bundle) { out.append(app) }
        }
    }
    return out
}

public func listUserToolNames(
    dirs: [String]? = nil,
    which: WhichFn = whichCommand,
    sdkDirs: [String]? = nil
) -> [String] {
    let fm = FileManager.default
    var out: [String] = []
    var seen = Set<String>()
    for dir in dirs ?? defaultUserToolDirs() {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { continue }
            guard fm.isExecutableFile(atPath: path) else { continue }
            if seen.insert(name).inserted { out.append(name) }
        }
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

public func scanLeftovers(
    apps: [AppRecord],
    brew: BrewSnapshot,
    progress: (String) -> Void = { _ in },
    roots: [(String, String, String)]? = nil,
    measureSizes: Bool = true,
    now: Date = Date()
) -> ([DataItem], [OrphanAgent]) {
    let ident = Identity(apps: apps + appsFromPathBinaries(), brew: brew, toolNames: listUserToolNames())
    var allRoots = roots ?? scanRootsForPlatform()
    if roots == nil {
        for (path, kind) in homeDataLeaves() {
            allRoots.append(("home", path, kind))
        }
    }
    progress("  · scanning data locations for \(allRoots.count) roots…")
    var items: [DataItem] = []
    for (label, root, kind) in allRoots {
        if kind == "leaf" {
            if !includeScanEntry(root, kind: kind) { continue }
            var name = URL(fileURLWithPath: root).lastPathComponent
            if name.hasPrefix(".") { name = String(name.dropFirst()) }
            let (status, owner) = ident.classify(name, kind: "dir")
            items.append(DataItem(path: root, name: name, rootLabel: label, kind: kind, status: status, owner: owner))
            continue
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
        for path in listEntries(root) {
            if !includeScanEntry(path, kind: kind) { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            if kind == "plist", !name.hasSuffix(".plist") { continue }
            let (status, owner) = ident.classify(name, kind: kind)
            items.append(DataItem(path: path, name: name, rootLabel: label, kind: kind, status: status, owner: owner))
        }
    }

    let agents: [OrphanAgent]
    if roots == nil {
        agents = scanLaunchAgents(progress: progress)
        for agent in agents {
            items.append(dataItem(from: agent, ident: ident))
        }
        items.append(contentsOf: listBrokenUserBinLinks())
        items.append(contentsOf: listShadowingOverlays())
    } else {
        agents = []
    }

    if measureSizes {
        let toMeasure = items.filter { isListedLeftoverStatus($0.status) && !skipNestedProbe($0) }
        progress("  · measuring sizes for \(toMeasure.count) leftover folders…")
        let sizes = pmap(items, workers: 4) { item -> (Int, Bool) in
            if skipNestedProbe(item) { return (0, false) }
            if !isListedLeftoverStatus(item.status) { return (0, true) }
            return duSize(item.path, timeout: 6)
        }
        for (item, pair) in zip(items, sizes) {
            item.sizeBytes = pair.0
            item.sizeMeasured = pair.1
            if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path),
               let mt = attrs[.modificationDate] as? Date {
                item.mtime = mt
            }
        }
        progress("  · checking nested mtimes for \(items.filter { $0.status != "system" }.count) entries…")
        let acts = pmap(items, workers: 8) { item -> Date? in
            if skipNestedProbe(item) { return item.mtime }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                return probeActivityMtime(item.path) ?? item.mtime
            }
            return item.mtime
        }
        for (item, act) in zip(items, acts) {
            item.activityMtime = act
        }
        applyRecentActivity(items, now: now)
    }
    items = groupOrphanedLeftovers(items)
    applyOrphanReasons(items)
    return (items, agents)
}

public func scanLaunchAgents(
    progress: (String) -> Void = { _ in },
    roots: [String]? = nil
) -> [OrphanAgent] {
    if PlatformOverride.isLinux { return [] }
    progress("  · checking LaunchAgents…")
    var orphans: [OrphanAgent] = []
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dirs = roots ?? [
        (home as NSString).appendingPathComponent("Library/LaunchAgents"),
        "/Library/LaunchAgents",
    ]
    for root in dirs {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
        for path in listEntries(root) where path.hasSuffix(".plist") {
            let info = loadPlist(path)
            if info.isEmpty { continue }
            let label = (info["Label"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
            var program: String?
            if let args = info["ProgramArguments"] as? [Any], let first = args.first {
                program = "\(first)"
            } else if let p = info["Program"] {
                program = "\(p)"
            }
            guard let program, !program.isEmpty else { continue }
            if program.hasPrefix("/usr/bin/") || program.hasPrefix("/bin/") || program.hasPrefix("/usr/sbin/") || program.hasPrefix("/sbin/") {
                continue
            }
            if !FileManager.default.fileExists(atPath: program) {
                orphans.append(OrphanAgent(path: path, label: label, program: program))
            } else if program.contains(".app/") {
                let bundle = program.components(separatedBy: ".app/").first.map { $0 + ".app" } ?? ""
                if !bundle.isEmpty, !FileManager.default.fileExists(atPath: bundle) {
                    orphans.append(OrphanAgent(path: path, label: label, program: program))
                }
            }
        }
    }
    return orphans
}
