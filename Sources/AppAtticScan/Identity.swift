import Foundation

// Who owns a name: the alias and system-name tables, the bundle-id and name
// validators, and the `Identity` index the classifier reads.

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

func parseNewlineNameSet(_ text: String) -> Set<String> {
    Set(
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    )
}

/// Read the names file through `decodeUTF8`, not `String(contentsOf:encoding:)`.
///
/// A strict decode drops the whole file on the first byte it cannot read, and an
/// empty name set makes every entry under a system root look like an orphan. A
/// leading BOM decodes but sticks to the first name instead. `decodeUTF8` is the
/// convention the rest of the scanners follow: invalid bytes become U+FFFD, a
/// leading BOM is not content.
func loadLinuxSystemNamesText() -> String {
    if let url = Bundle.module.url(forResource: "linux-system-names", withExtension: "txt"),
       let data = try? Data(contentsOf: url)
    {
        return decodeUTF8(data)
    }
    let here = URL(fileURLWithPath: #filePath)
    let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = repo.appendingPathComponent("core/src/linux-system-names.txt")
    return readUTF8File(file.path) ?? ""
}

let linuxSystemNames: Set<String> = parseNewlineNameSet(loadLinuxSystemNamesText())

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

@inline(__always) func isLowerAlnum(_ c: UInt8) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A)
}

/// `^[a-z0-9]+(\.[a-z0-9_\-]+)+$` on bytes. Case: callers pass lowercased input.
public func isBundleId(_ s: String) -> Bool {
    s.utf8.withContiguousStorageIfAvailable { u -> Bool in
        let n = u.count
        guard n >= 3 else { return false }
        var i = 0
        var dots = 0
        while i < n {
            let seg = i
            while i < n, u[i] != 0x2E {
                let c = u[i]
                guard isLowerAlnum(c) || c == 0x5F || c == 0x2D else { return false }
                i += 1
            }
            // First segment: `[a-z0-9]+` (no `_`/`-`); rest: `[a-z0-9_-]+`.
            if i == seg { return false }
            if dots == 0 {
                for k in seg..<i where u[k] == 0x5F || u[k] == 0x2D { return false }
            }
            if i == n { break }
            dots += 1
            i += 1 // dot
        }
        return dots >= 1 && i == n && u[n - 1] != 0x2E
    } ?? false
}

/// `^[a-z][a-z0-9]{8,}d$`: lowercase lead, 8+ alnum, trailing `d`, length ≥ 10.
public func isDaemonName(_ s: String) -> Bool {
    s.utf8.withContiguousStorageIfAvailable { u -> Bool in
        let n = u.count
        guard n >= 10, u[0] >= 0x61, u[0] <= 0x7A, u[n - 1] == 0x64 else { return false }
        for k in 1..<(n - 1) where !isLowerAlnum(u[k]) { return false }
        return true
    } ?? false
}

/// `^(?=.*[0-9])[A-Z0-9]{8,12}$` case-insensitive: 8–12 ASCII alnum, one digit.
public func isTeamId(_ s: String) -> Bool {
    s.utf8.withContiguousStorageIfAvailable { u -> Bool in
        let n = u.count
        guard n >= 8, n <= 12 else { return false }
        var digit = false
        for k in 0..<n {
            let c = u[k]
            if c >= 0x30, c <= 0x39 { digit = true; continue }
            guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) else { return false }
        }
        return digit
    } ?? false
}

/// `^[0-9a-f]{8}-...$` case-insensitive UUID.
public func isUUID(_ s: String) -> Bool {
    s.utf8.withContiguousStorageIfAvailable { u -> Bool in
        guard u.count == 36 else { return false }
        @inline(__always) func hex(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
        }
        for k in [8, 13, 18, 23] where u[k] != 0x2D { return false }
        for k in 0..<36 {
            if k == 8 || k == 13 || k == 18 || k == 23 { continue }
            if !hex(u[k]) { return false }
        }
        return true
    } ?? false
}

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
    if linuxSystemNames.contains(n) || linuxSystemNames.contains(nn)
        || n.hasPrefix("gtk-") || n.hasPrefix("xdg")
        || n.hasPrefix("kde") || n.hasPrefix("kwin") || n.hasPrefix("plasma")
        || n.hasPrefix("baloo") {
        return ("system", nil)
    }
    if n.hasSuffix("rc"), n.count > 2 {
        let stem = String(n.dropLast(2))
        if linuxSystemNames.contains(stem) {
            return ("system", nil)
        }
    }
    if snapSystemNames.contains(n) {
        return ("system", nil)
    }
    // `isASCII` too: `Character.isNumber` is also true for Arabic-Indic and
    // other non-ASCII digits, so `~/.config/core٩` would be classified exactly
    // as `core42` and hidden from the report. Same rule as Zig `isAllDigits`.
    if n.hasPrefix("core") && n.dropFirst(4).allSatisfy({ $0.isNumber && $0.isASCII }) {
        return ("system", nil)
    }
    let parts = n.split(separator: "-")
    if n.hasPrefix("gnome-"), let last = parts.last, last.allSatisfy({ $0.isNumber && $0.isASCII }) {
        return ("system", nil)
    }
    return ("orphaned", nil)
}

func vendorFromBid(_ bundleId: String) -> String? {
    let labels = bundleId.posixLowercased().split(separator: ".").map(String.init).filter { !$0.isEmpty }
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
    /// Precomputed `stem` + separator forms. The old per-call `stem + sep`
    /// allocated 3 Strings per stem per classified entry. Built once at the
    /// end of init; `stems` is never mutated after construction.
    /// Indexed by first UTF-8 byte: ~200 stems share ~26 buckets, so each
    /// entry checks ~8 candidates instead of all of them.
    private var stemTests: [(stem: String, dash: String, under: String, dot: String)] = []
    private var stemIndex: [UInt8: [(stem: String, dash: String, under: String, dot: String)]] = [:]
    /// `brewRaw` minus generic tokens. The old loop re-checked
    /// `isGenericOwnerToken` (lowercase + trim) per package per entry.
    /// The brew keys as sets, and only the hyphenated ones: the unscoped
    /// ownership test requires a hyphen. Looking the *query's* prefixes up in a
    /// set replaces a scan of every installed formula for every name (200 keys x
    /// 5000 names in the bench) with one hash lookup per prefix length.
    private var brewKeySet: Set<Substring> = []
    private var brewKeyHyphenSet: Set<Substring> = []

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
                let b = bidRaw.posixLowercased()
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
                brewRaw.insert(name.posixLowercased())
            }
        }
        for raw in toolNames {
            let base = URL(fileURLWithPath: raw).lastPathComponent
            if isGenericOwnerToken(base) { continue }
            let n = norm(base)
            if n.count < 2 { continue }
            brewNames.insert(n)
            brewRaw.insert(base.posixLowercased())
            for alias in toolLeftoverAliases[n] ?? [] {
                brewNames.insert(alias)
            }
        }
        stemTests = stems.filter { $0.count >= 5 }.map {
            ($0, $0 + "-", $0 + "_", $0 + ".")
        }
        var index: [UInt8: [(stem: String, dash: String, under: String, dot: String)]] = [:]
        for t in stemTests {
            guard let f = t.stem.utf8.first else { continue }
            index[f, default: []].append(t)
        }
        stemIndex = index
        let brewKeys = brewRaw.filter { !isGenericOwnerToken($0) }
        brewKeySet = Set(brewKeys.map { Substring($0) })
        brewKeyHyphenSet = Set(brewKeys.filter { $0.contains("-") }.map { Substring($0) })
    }

    /// `posixFolded`, not `posixLowercased`: a stem is matched against a
    /// leftover name with `==` and `hasPrefix`, and the two arrive in
    /// whatever form their sources wrote them. `/Applications/Café.app` is
    /// NFC on Linux and NFD on macOS, so a fold without the canonical step
    /// keys the same app under two stems, and `s.count >= 5` then admits one
    /// spelling and drops the other ("café" is 4 clusters composed, 5
    /// decomposed) so which one lands is decided by the filesystem.
    func addStem(_ raw: String) {
        var s = posixFolded(raw.trimmingCharacters(in: .whitespaces))
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
        // Same form `addStem` stores, so the two sides of `==` agree.
        let e = posixFolded(stripLeftoverNameSuffix(entry))
        guard let f = e.utf8.first, let bucket = stemIndex[f] else { return false }
        for t in bucket {
            if e == t.stem { return true }
            if e.hasPrefix(t.dash) || e.hasPrefix(t.under) || e.hasPrefix(t.dot) { return true }
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
        let d = stem.posixLowercased()
        if isBundleId(d) {
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
        let low = core.posixLowercased()
        let n = norm(core)
        let bidLike = ["bundleid", "group", "savedstate", "plist"].contains(kind) || isBundleId(low)
        if bidLike {
            var b = low
            if b.hasPrefix("group.") { b = String(b.dropFirst("group.".count)) }
            if let res = classifyBid(b) { return res }
        }
        if names.contains(n) { return ("owned", nameOwner[n]) }
        if brewNames.contains(n) { return ("owned", nil) }
        if affinity.contains(n) { return ("owned", nil) }
        let first = core.split { $0 == " " || $0 == "\t" || $0 == "." || $0 == "_" || $0 == "-" }.first.map(String.init) ?? ""
        let fn = norm(first)
        if affinity.contains(fn), fn.count >= 5 { return ("owned", nil) }
        if ownedByStem(core) { return ("owned", nameOwner[n]) }
        var brewKey = low
        let scoped = brewKey.hasPrefix("@")
        if scoped {
            brewKey = String(brewKey.dropFirst())
        }
        let pool = scoped ? brewKeySet : brewKeyHyphenSet
        if !pool.isEmpty {
            var end = brewKey.count
            while end >= 2 {
                if pool.contains(brewKey.prefix(end)) {
                    let rest = brewKey.dropFirst(end)
                    if rest.isEmpty || !(rest.first?.isLetter == true || rest.first?.isNumber == true) {
                        return ("owned", nil)
                    }
                }
                end -= 1
            }
        }
        if isUUID(core) { return ("system", nil) }
        let user = currentUsername()
        if !user.isEmpty, (low == user || normKey(user).map { n == $0 } == true) { return ("system", nil) }
        if appleServiceNames.contains(n) || isDaemonName(low) || asciiContains(n, "ratelimiter") || asciiContains(n, "loginwindow") {
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
        if labels.count >= 2, isTeamId(labels[0]) {
            let tokens = teamIdVendors[labels[0].posixLowercased()] ?? []
            // Membership tested per token: the union this replaces copied
            // `affinity`, `names` and `stems` into two fresh hash tables to
            // test one or two team ids, and this runs for every bundle-id
            // leftover and again on each recursion.
            if tokens.contains(where: { affinity.contains($0) || names.contains($0) || stems.contains($0) }) {
                return ("owned", nil)
            }
            return classifyBid(labels.dropFirst().joined(separator: "."))
        }
        if labels.count > 2 {
            return classifyBid(labels.dropFirst().joined(separator: "."))
        }
        return nil
    }
}
