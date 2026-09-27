import Foundation

// How a leftover is named and explained: display names, category filters,
// summaries, reasons, and the per-app blurbs.

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
    "bin": "Broken PATH command. The tool is gone.",
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
    "bin": "Broken command",
]

let leftoverNameSuffixes = [".savedstate", ".plist", ".binarycookies"]

func stripLeftoverNameSuffix(_ name: String) -> String {
    // Manual trim: `trimmingCharacters` bridges to NSString per call and this
    // runs on every classified entry. Space/tab/CR/LF covers real filenames.
    @inline(__always) func isTrim(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }
    var s = name[...]
    while let f = s.first, isTrim(f) { s = s.dropFirst() }
    while let l = s.last, isTrim(l) { s = s.dropLast() }
    guard !s.isEmpty else { return "" }
    let low = posixLowercased(String(s))
    for suffix in leftoverNameSuffixes {
        if low.hasSuffix(suffix) {
            return String(s.dropLast(suffix.count))
        }
    }
    return String(s)
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
    if asciiHasByte(name, 0x2E) || asciiHasByte(name, 0x5F) || asciiHasByte(name, 0x2D) { return name }
    if name.contains(where: { $0.isUppercase }) { return name }
    guard let first = name.first else { return name }
    return String(first).uppercased() + name.dropFirst()
}

func isSimpleLeftoverLabel(_ label: String) -> Bool {
    if label.hasPrefix("@") || asciiHasByte(label, 0x2E) { return false }
    return label.count >= 2
}

func prettyDnsLeftoverLabel(_ label: String) -> String? {
    var core = label
    if core.hasPrefix("@") {
        core = String(core.dropFirst())
        if let canon = leftoverProductAliases[norm(core)] { return leftoverTitleCase(canon) }
        return nil
    }
    if !asciiHasByte(core, 0x2E) { return core }
    let parts = core.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    for part in parts.reversed() {
        let low = part.posixLowercased()
        if genericDnsLabels.contains(low) { continue }
        if genericVendorLabels.contains(norm(part)) { continue }
        if isGenericOwnerToken(part) { continue }
        if leftoverDisplaySkipTokens.contains(low) { continue }
        if isTeamId(part) { continue }
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
    if path.contains("/.local/bin/")
        || path.contains("/usr/local/bin/")
        || path.contains("/opt/homebrew/bin/")
        || path.contains("/.linuxbrew/bin/")
    {
        return true
    }
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    guard dir.lastPathComponent == "bin" else { return false }
    let parent = dir.deletingLastPathComponent().lastPathComponent
    if parent == "usr" || parent == "local" || parent == "opt" { return false }
    if path.contains("/.local/") || path.contains("/.cargo/") { return false }
    if path.contains("/homebrew") || path.contains("/linuxbrew") { return false }
    return true
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
    // POSIX fold on both sides: the category comes from the command line and
    // the fields come from disk, so neither should be case-folded by the
    // user's locale. In tr_TR a plain lowercased() turns "--category FIREFOX"
    // into "fırefox" and matches nothing.
    let cats = categories.map { posixLowercased($0) }
    let fields = [
        name,
        leftoverDisplayName(name: name, extraPaths: extraPaths),
        path,
        rootLabel,
        status,
        shadows ?? "",
    ] + extraPaths
    return fields.contains { field in
        let low = posixLowercased(field)
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
        if item.leftoverStatus == .orphaned {
            item.reason = leftoverWhyText(rootLabel: item.rootLabel, kind: item.kind, extraPaths: item.extraPaths)
            item.summary = leftoverSummary(
                rootLabel: item.rootLabel,
                kind: item.kind,
                name: item.name,
                extraPaths: item.extraPaths,
                appBlurb: leftoverAppBlurb(name: item.name, extraPaths: item.extraPaths, catalog: catalog)
            )
        } else if item.leftoverStatus == .shadow {
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

/// The blurb a lookup token already resolves to, or nil when no table has
/// it. `normKey` is nil for a name that folds to "", so a name written in
/// another script never matches the first such entry that was indexed.
func leftoverBlurbLookup(token: String, catalog: [String: String]) -> String? {
    if let key = normKey(token), let blurb = leftoverProductBlurbs[key] { return blurb }
    if let blurb = catalog[token] { return blurb }
    if let key = normKey(token), let blurb = catalog[key] { return blurb }
    return nil
}

public func leftoverAppBlurb(name: String, extraPaths: [String] = [], catalog: [String: String] = [:]) -> String? {
    for token in leftoverLookupTokens(name: name, extraPaths: extraPaths) {
        if let blurb = leftoverBlurbLookup(token: token, catalog: catalog) { return shortDesc(blurb) }
    }
    return nil
}

public func leftoverBlurbsFromSnapshot(_ brew: BrewSnapshot) -> [String: String] {
    var catalog: [String: String] = [:]
    func put(_ key: String, _ desc: String?) {
        guard let desc, !desc.isEmpty else { return }
        catalog[key.posixLowercased()] = desc
        if let folded = normKey(key) { catalog[folded] = desc }
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
        return seen.insert(token.posixLowercased()).inserted
    }.prefix(limit).map { $0 }
    guard !names.isEmpty else { return [:] }
    let data = infoJSONForNames(brew: brew, names: names, run: run)
    let (summaries, titles) = brewPackageMeta(data)
    var catalog: [String: String] = [:]
    for (name, desc) in summaries {
        catalog[name.posixLowercased()] = desc
        if let folded = normKey(name) { catalog[folded] = desc }
    }
    for (token, title) in titles {
        if let desc = summaries[token] {
            catalog[title.posixLowercased()] = desc
            if let folded = normKey(title) { catalog[folded] = desc }
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
    let needed = items.filter { $0.leftoverStatus == .orphaned }.compactMap { item -> String? in
        leftoverLookupTokens(name: item.name, extraPaths: item.extraPaths).first { token in
            leftoverBlurbLookup(token: token, catalog: catalog) == nil
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
