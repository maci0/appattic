import Foundation

public struct Formula {
    public var name: String
    public var aliases: [String]
    public var version: String?
    public var isLeaf: Bool
    public var bins: [String]
    public var desc: String?

    public init(
        name: String,
        aliases: [String] = [],
        version: String? = nil,
        isLeaf: Bool = true,
        bins: [String] = [],
        desc: String? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.version = version
        self.isLeaf = isLeaf
        self.bins = bins
        self.desc = desc
    }
}

public struct Cask {
    public var name: String
    public var version: String?
    public var isLeaf: Bool
    public var appPaths: [String]
    public var desc: String?
    public var titles: [String]
    public var appNames: [String]
    public var untrustedTap: String?

    public init(
        name: String,
        version: String? = nil,
        isLeaf: Bool = true,
        appPaths: [String] = [],
        desc: String? = nil,
        titles: [String] = [],
        appNames: [String] = [],
        untrustedTap: String? = nil
    ) {
        self.name = name
        self.version = version
        self.isLeaf = isLeaf
        self.appPaths = appPaths
        self.desc = desc
        self.titles = titles
        self.appNames = appNames
        self.untrustedTap = untrustedTap
    }
}

public struct BrewSnapshot {
    public var available: Bool
    public var prefix: String?
    public var formulas: [Formula]
    public var casks: [Cask]
    public var services: Set<String>
    public var outdated: [OutdatedPkg]
    public var untrustedCasks: [UntrustedCask]
    public var outdatedFailed: Bool

    public init(
        available: Bool,
        prefix: String? = nil,
        formulas: [Formula] = [],
        casks: [Cask] = [],
        services: Set<String> = [],
        outdated: [OutdatedPkg] = [],
        untrustedCasks: [UntrustedCask] = [],
        outdatedFailed: Bool = false
    ) {
        self.available = available
        self.prefix = prefix
        self.formulas = formulas
        self.casks = casks
        self.services = services
        self.outdated = outdated
        self.untrustedCasks = untrustedCasks
        self.outdatedFailed = outdatedFailed
    }

    public var allNames: [String] {
        formulas.map(\.name) + casks.map(\.name)
    }
}

/// The subprocess seam every collector takes as a `run:` parameter, so a test
/// can answer a package manager instead of running it.
///
/// Arguments are the argv (never a shell string) and the timeout in seconds.
/// The result is `(exitStatus, stdout, stderr)`, in that order: a non-zero
/// status is a failed check, which callers report and never treat as an empty
/// answer. `runCommand` is the real implementation.
public typealias CommandRun = ([String], TimeInterval) -> (Int32, String, String)

/// The `which:` seam: a program name to the path that runs it, or nil when the
/// machine has no such program. `whichCommand` is the real implementation.
public typealias WhichFn = (String) -> String?

public struct UntrustedCask: Equatable, Sendable {
    public var name: String
    public var tap: String?
    public init(name: String, tap: String? = nil) {
        self.name = name
        self.tap = tap
    }
}

private let untrustedCaskRE = try! NSRegularExpression(
    pattern: "Refusing to load cask (\\S+) from untrusted tap (\\S+)",
    options: [.caseInsensitive]
)

public func refusedCasks(from err: String) -> [UntrustedCask] {
    let range = NSRange(err.startIndex..., in: err)
    let matches = untrustedCaskRE.matches(in: err, range: range)
    var out: [UntrustedCask] = []
    var seen = Set<String>()
    for match in matches where match.numberOfRanges >= 3 {
        guard let nameR = Range(match.range(at: 1), in: err) else { continue }
        var token = String(err[nameR])
        if let slash = token.split(separator: "/").last {
            token = String(slash)
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !token.isEmpty, seen.insert(token.posixLowercased()).inserted else { continue }
        var tap: String?
        if let tapR = Range(match.range(at: 2), in: err) {
            tap = String(err[tapR]).trimmingCharacters(in: CharacterSet(charactersIn: "'\". "))
            if tap?.isEmpty == true { tap = nil }
        }
        out.append(UntrustedCask(name: token, tap: tap))
    }
    return out
}

public func refusedCaskToken(_ err: String) -> String? {
    refusedCasks(from: err).first?.name
}

public func untrustedCaskSummary(_ cask: UntrustedCask) -> String {
    if let tap = cask.tap, !tap.isEmpty {
        return "Installed from untrusted Homebrew tap \(tap)"
    }
    return "Installed from an untrusted Homebrew tap"
}

public func untrustedCaskReason(_ cask: UntrustedCask) -> String {
    if let tap = cask.tap, !tap.isEmpty {
        return "Homebrew refuses to load this cask from untrusted tap \(tap). It is still installed. AppAttic will not trust the tap for you."
    }
    return "Homebrew refuses to load this cask from an untrusted tap. It is still installed. AppAttic will not trust the tap for you."
}

/// `out` decoded as a `brew info --json=v2` document, or nil when it is not
/// one. `brew info --json=v2 --installed` answers with every installed
/// formula's full metadata, which runs to megabytes on a machine with a few
/// hundred of them, so the callers below take the decoded document rather
/// than decoding once to check it and again to read it.
func infoJSONDocument(_ out: String) -> [String: Any]? {
    parseJSONDocument(out) as? [String: Any]
}

func parseInfoJSON(_ out: String) -> [String: Any] {
    infoJSONDocument(out) ?? [:]
}

public func fetchInfoJSON(
    brew: String,
    run: CommandRun = runCommand
) -> [String: Any] {
    var formulae: [Any] = []
    var casks: [Any] = []
    let (rcF, outF, _) = run([brew, "info", "--json=v2", "--formula", "--installed"], 180)
    if rcF == 0, !outF.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // A success status carrying a payload that is not JSON is a broken
        // answer, not an empty installed list. The report would show every
        // formula without a version, and the scan would cache that for a day.
        if let doc = infoJSONDocument(outF) {
            formulae = doc["formulae"] as? [Any] ?? []
        } else {
            noteScanCheckFailed("brew-info")
        }
    }
    let (rcC, outC, _) = run([brew, "info", "--json=v2", "--cask", "--installed"], 180)
    if rcC == 0, !outC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let doc = infoJSONDocument(outC) {
            casks = doc["casks"] as? [Any] ?? []
        } else {
            noteScanCheckFailed("brew-info")
        }
    }
    return ["formulae": formulae, "casks": casks]
}

public func infoJSONForNames(
    brew: String,
    names: [String],
    run: CommandRun = runCommand
) -> [String: Any] {
    var remaining = names.filter { !$0.isEmpty }
    while !remaining.isEmpty {
        let (rc, out, err) = run([brew, "info", "--json=v2"] + remaining, 180)
        if rc == 0 {
            return parseInfoJSON(out)
        }
        // Every refusal in this stderr is dropped in one retry, not one
        // subprocess per cask: each retry is a fresh `brew info` over the
        // remaining names, and a machine with k untrusted taps paid k of them.
        let tokens = refusedCasks(from: err).map(\.name)
        guard !tokens.isEmpty else { return [:] }
        let exact = Set(tokens)
        let qualified = tokens.map { "/" + $0 }
        let dropped = remaining.filter { name in
            guard !exact.contains(name) else { return false }
            return !qualified.contains(where: { name.hasSuffix($0) })
        }
        if dropped.count == remaining.count { return [:] }
        remaining = dropped
    }
    return [:]
}

/// The app one cask artifact entry names, if any.
private func artifactAppName(_ key: String, _ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let opts = value as? [String: Any], let target = opts["target"] as? String { return target }
    return key
}

public func caskArtifactAppNames(_ items: [Any]) -> [String] {
    var names: [String] = []
    for item in items {
        var name: String?
        if let s = item as? String {
            name = s
        } else if let dict = item as? [String: Any] {
            if let app = dict["app"] {
                names.append(contentsOf: caskArtifactAppNames(app as? [Any] ?? [app]))
                continue
            }
            // Keys are walked sorted, not in Dictionary order: that order is
            // hash-seeded per process, so a plain `for` picks a different
            // artifact on each run of the same scan.
            for key in dict.keys.sorted() {
                guard let candidate = artifactAppName(key, dict[key]),
                      candidate.hasSuffix(".app") else { continue }
                name = candidate
                break
            }
        }
        if let name, name.hasSuffix(".app") {
            names.append(name)
        }
    }
    return names
}

public func caskArtifactAppNames(fromArtifacts artifacts: [Any]) -> [String] {
    var names: [String] = []
    for art in artifacts {
        if let s = art as? String, s.hasSuffix(".app") {
            names.append(s)
        } else if let dict = art as? [String: Any] {
            if let app = dict["app"] {
                names.append(contentsOf: caskArtifactAppNames(app as? [Any] ?? [app]))
            } else {
                names.append(contentsOf: caskArtifactAppNames([dict]))
            }
        } else if let arr = art as? [Any] {
            names.append(contentsOf: caskArtifactAppNames(arr))
        }
    }
    return names
}

func formulaBins(prefix: String, name: String) -> [String] {
    guard !prefix.isEmpty, !name.isEmpty else { return [] }
    let binDir = URL(fileURLWithPath: prefix)
        .appendingPathComponent("opt")
        .appendingPathComponent(name)
        .appendingPathComponent("bin")
        .path
    return directoryEntryNames(binDir).filter { base in
        !base.hasSuffix(".dylib") && !base.hasSuffix(".prl")
    }
}

public func collectBrew(
    progress: @escaping (String) -> Void = { _ in },
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand
) -> BrewSnapshot {
    guard let brew = which("brew") else {
        return BrewSnapshot(available: false)
    }
    let realBrew = URL(fileURLWithPath: brew).resolvingSymlinksInPath().path
    let prefix = URL(fileURLWithPath: realBrew).deletingLastPathComponent().deletingLastPathComponent().path
    var info = BrewSnapshot(available: true, prefix: prefix)
    progress("  · querying Homebrew…")
    var refused: [UntrustedCask] = []
    func tracking(_ cmd: [String], _ timeout: TimeInterval) -> (Int32, String, String) {
        let r = run(cmd, timeout)
        refused.append(contentsOf: refusedCasks(from: r.2))
        return r
    }

    let (rcF, outF, _) = tracking([brew, "list", "--formula"], 60)
    if rcF == 0 {
        info.formulas = outF.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { Formula(name: $0) }
    } else {
        // No formulae listed is the report's "no Homebrew software", and the
        // scan would keep it for a day. A listing that ran and failed is an
        // unknown, so it is recorded like any other failed check.
        noteScanCheckFailed("brew-formula-list")
    }
    let (rcC, outC, _) = tracking([brew, "list", "--cask"], 60)
    if rcC == 0 {
        info.casks = outC.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { Cask(name: $0) }
    } else {
        noteScanCheckFailed("brew-cask-list")
    }

    let (rcL, outL, _) = tracking([brew, "leaves"], 60)
    if rcL == 0 {
        let leaves = Set(outL.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        for i in info.formulas.indices {
            info.formulas[i].isLeaf = leaves.contains(info.formulas[i].name)
        }
        for i in info.casks.indices {
            info.casks[i].isLeaf = leaves.contains(info.casks[i].name)
        }
    }

    let names = info.allNames
    var data: [String: Any] = ["formulae": [], "casks": []]
    if !names.isEmpty {
        progress("  · loading Homebrew package info…")
        data = fetchInfoJSON(brew: brew, run: tracking)
        func mergeOmitted(jsonKey: String, tokenKey: String, listed: [String]) {
            guard !listed.isEmpty else { return }
            var rows = data[jsonKey] as? [[String: Any]] ?? []
            let present = Set(rows.compactMap { $0[tokenKey] as? String })
            let missing = listed.filter { !present.contains($0) }
            guard !missing.isEmpty else { return }
            let extra = infoJSONForNames(brew: brew, names: missing, run: tracking)
            if let more = extra[jsonKey] as? [[String: Any]] {
                rows.append(contentsOf: more)
                data[jsonKey] = rows
            }
        }
        mergeOmitted(jsonKey: "formulae", tokenKey: "name", listed: info.formulas.map(\.name))
        mergeOmitted(jsonKey: "casks", tokenKey: "token", listed: info.casks.map(\.name))
    }

    var descMap: [String: String] = [:]
    var titleMap: [String: String] = [:]
    let formulae = data["formulae"] as? [[String: Any]] ?? []
    let casksJSON = data["casks"] as? [[String: Any]] ?? []
    if !formulae.isEmpty || !casksJSON.isEmpty {
        let meta = brewPackageMeta(from: data)
        (descMap, titleMap) = (meta.summaries, meta.titles)
        for i in info.formulas.indices {
            if info.formulas[i].desc == nil {
                info.formulas[i].desc = descMap[info.formulas[i].name]
            }
        }
        for i in info.casks.indices {
            if info.casks[i].desc == nil {
                info.casks[i].desc = descMap[info.casks[i].name]
            }
        }
        // Installed name -> index, first occurrence wins. Both keys a row can
        // match on, `name` and `full_name`, are compared against the installed
        // name, so one index serves both and the earlier of the two hits is the
        // match.
        var formulaByName: [String: Int] = [:]
        formulaByName.reserveCapacity(info.formulas.count)
        for (i, entry) in info.formulas.enumerated() where formulaByName[entry.name] == nil {
            formulaByName[entry.name] = i
        }
        for f in formulae {
            let byName = (f["name"] as? String).flatMap { formulaByName[$0] }
            let byFull = (f["full_name"] as? String).flatMap { formulaByName[$0] }
            var match = byName
            if let byFull { match = match.map { min($0, byFull) } ?? byFull }
            guard let match else { continue }
            info.formulas[match].aliases = (f["aliases"] as? [String])?.filter { !$0.isEmpty } ?? []
            let installed = f["installed"] as? [[String: Any]] ?? []
            let ver = (installed.first?["version"] as? String) ?? ((f["versions"] as? [String: Any])?["stable"] as? String)
            info.formulas[match].version = ver
        }
        var caskByToken: [String: Int] = [:]
        caskByToken.reserveCapacity(info.casks.count)
        for (i, entry) in info.casks.enumerated() where caskByToken[entry.name] == nil {
            caskByToken[entry.name] = i
        }
        for c in casksJSON {
            guard let token = c["token"] as? String, let match = caskByToken[token] else { continue }
            info.casks[match].version = (c["version"] as? String) ?? ((c["versions"] as? [String: Any])?["stable"] as? String)
            var pretty: [String] = []
            if let names = c["name"] as? [String] {
                pretty = names
            } else if let name = c["name"] as? String {
                pretty = [name]
            }
            info.casks[match].titles = pretty.filter { !$0.isEmpty }.map { String($0) }
            for appName in caskArtifactAppNames(fromArtifacts: c["artifacts"] as? [Any] ?? []) {
                if !info.casks[match].appNames.contains(appName) {
                    info.casks[match].appNames.append(appName)
                }
                let homeApps = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Applications")
                for base in ["/Applications", homeApps] {
                    let candidate = URL(fileURLWithPath: (base as NSString).appendingPathComponent(appName)).resolvingSymlinksInPath().path
                    if FileManager.default.fileExists(atPath: candidate) {
                        if !info.casks[match].appPaths.contains(candidate) {
                            info.casks[match].appPaths.append(candidate)
                        }
                        break
                    }
                }
            }
        }
    }

    let leafFormulas = info.formulas.filter(\.isLeaf)
    if !leafFormulas.isEmpty {
        progress("  · resolving binaries for \(leafFormulas.count) top-level brew formulas…")
        let prefix = info.prefix ?? ""
        for i in info.formulas.indices where info.formulas[i].isLeaf {
            info.formulas[i].bins = formulaBins(prefix: prefix, name: info.formulas[i].name)
        }
    }

    let (rcS, outS, _) = tracking([brew, "services", "list"], 60)
    if rcS == 0 {
        let lines = outS.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines.dropFirst() {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // `brew services list` is "name state ...". Older brew releases
            // print "running" where newer ones print "started".
            let state = parts.count >= 2 ? parts[1] : ""
            if state == "started" || state == "running" {
                info.services.insert(parts[0])
            }
        }
    }

    let brewOutdated = queryBrewStatus(brew, progress: progress, run: tracking)
    info.outdated = brewOutdated.pkgs
    info.outdatedFailed = brewOutdated.failed
    attachSummaries(info.outdated, summaries: descMap, titles: titleMap)
    var unique: [UntrustedCask] = []
    var seen = Set<String>()
    for u in refused {
        guard seen.insert(u.name.posixLowercased()).inserted else { continue }
        unique.append(u)
    }
    info.untrustedCasks = unique
    // Lowercased installed name -> index, first occurrence wins.
    var caskByLowered: [String: Int] = [:]
    caskByLowered.reserveCapacity(info.casks.count)
    for (i, entry) in info.casks.enumerated() {
        let key = entry.name.posixLowercased()
        if caskByLowered[key] == nil { caskByLowered[key] = i }
    }
    for u in unique {
        if let i = caskByLowered[u.name.posixLowercased()] { info.casks[i].untrustedTap = u.tap }
    }
    return info
}

// MARK: - Homebrew outdated queries
// Parsers and metadata for the Homebrew side of the Outdated report. They
// belong with the rest of the brew feature, not in the manager-agnostic report.

func brewOutdatedEntries(_ document: Any) -> [OutdatedPkg] {
    guard let obj = document as? [String: Any] else { return [] }
    var out: [OutdatedPkg] = []
    for (key, manager) in [("formulae", "brew-formula"), ("casks", "brew-cask")] {
        for item in obj[key] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            var current: String?
            if let installed = item["installed_versions"] as? [String] {
                current = installed.first
            } else if let installed = item["installed_versions"] as? String {
                current = installed
            }
            out.append(OutdatedPkg(
                name: name,
                manager: manager,
                currentVersion: current,
                latestVersion: item["current_version"] as? String
            ))
        }
    }
    return out
}

public func parseBrewOutdatedJSON(_ text: String) -> [OutdatedPkg] {
    guard let document = parseJSONDocument(text) else { return [] }
    return brewOutdatedEntries(document)
}

func queryBrewStatus(
    _ brew: String,
    progress: ((String) -> Void)? = nil,
    run: CommandRun = runCommand
) -> (pkgs: [OutdatedPkg], failed: Bool) {
    if brew.isEmpty { return ([], false) }
    progress?("  · checking for outdated Homebrew packages…")
    let (rc, out, _) = run([brew, "outdated", "--json=v2"], 90)
    if rc != 0 { return ([], true) }
    if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ([], false) }
    // A success status with a payload that is not JSON is a broken answer, not
    // the answer "nothing is outdated": the parser would answer an empty list
    // and the scan would write that empty list to the cache and serve it for a
    // day. `outdatedFailed` is the same unknown a nonzero status produces.
    guard let document = parseJSONDocument(out) else { return ([], true) }
    return (brewOutdatedEntries(document), false)
}

/// The two lookup tables `brewPackageMeta` reads out of `brew info --json=v2`:
/// `summaries` maps a formula name or cask token to its `desc`, and `titles`
/// maps a cask token to the pretty `name` the cask file installs under. A
/// token is absent from `titles` when the pretty name is empty or is the token
/// itself, so a caller that fills a display name from this map never repeats
/// what the token already says.
public struct BrewPackageMeta: Equatable, Sendable {
    public var summaries: [String: String]
    public var titles: [String: String]

    public init(summaries: [String: String] = [:], titles: [String: String] = [:]) {
        self.summaries = summaries
        self.titles = titles
    }
}

public func brewPackageMeta(from data: [String: Any]) -> BrewPackageMeta {
    var summaries: [String: String] = [:]
    var titles: [String: String] = [:]
    for f in data["formulae"] as? [[String: Any]] ?? [] {
        let name = (f["name"] as? String) ?? (f["full_name"] as? String)
        let desc = (f["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let name, !name.isEmpty, !desc.isEmpty {
            summaries[name] = desc
        }
    }
    for c in data["casks"] as? [[String: Any]] ?? [] {
        guard let token = c["token"] as? String, !token.isEmpty else { continue }
        let desc = (c["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !desc.isEmpty { summaries[token] = desc }
        var pretty: String?
        if let names = c["name"] as? [String], let first = names.first {
            pretty = first.trimmingCharacters(in: .whitespaces)
        } else if let name = c["name"] as? String {
            pretty = name.trimmingCharacters(in: .whitespaces)
        }
        if let pretty, !pretty.isEmpty, pretty.posixLowercased() != token.posixLowercased() {
            titles[token] = pretty
        }
    }
    return BrewPackageMeta(summaries: summaries, titles: titles)
}

public func attachSummaries(
    _ pkgs: [OutdatedPkg],
    summaries: [String: String],
    titles: [String: String] = [:]
) {
    for p in pkgs {
        if p.summary?.isEmpty ?? true {
            let text = (summaries[p.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { p.summary = text }
        }
        if p.title?.isEmpty ?? true {
            let text = (titles[p.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text.posixLowercased() != p.name.posixLowercased() {
                p.title = text
            }
        }
    }
}
