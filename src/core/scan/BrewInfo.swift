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

    public init(
        available: Bool,
        prefix: String? = nil,
        formulas: [Formula] = [],
        casks: [Cask] = [],
        services: Set<String> = [],
        outdated: [OutdatedPkg] = [],
        untrustedCasks: [UntrustedCask] = []
    ) {
        self.available = available
        self.prefix = prefix
        self.formulas = formulas
        self.casks = casks
        self.services = services
        self.outdated = outdated
        self.untrustedCasks = untrustedCasks
    }

    public var allNames: [String] {
        formulas.map(\.name) + casks.map(\.name)
    }
}

public typealias CommandRun = ([String], TimeInterval) -> (Int32, String, String)
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
        guard !token.isEmpty, seen.insert(token.lowercased()).inserted else { continue }
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

func parseInfoJSON(_ out: String) -> [String: Any] {
    guard let data = out.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

public func fetchInfoJSON(
    brew: String,
    run: CommandRun = runCommand
) -> [String: Any] {
    var formulae: [Any] = []
    var casks: [Any] = []
    let (rcF, outF, _) = run([brew, "info", "--json=v2", "--formula", "--installed"], 180)
    if rcF == 0, !outF.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        formulae = parseInfoJSON(outF)["formulae"] as? [Any] ?? []
    }
    let (rcC, outC, _) = run([brew, "info", "--json=v2", "--cask", "--installed"], 180)
    if rcC == 0, !outC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        casks = parseInfoJSON(outC)["casks"] as? [Any] ?? []
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
        guard let token = refusedCaskToken(err) else { return [:] }
        let dropped = remaining.filter { $0 != token && !$0.hasSuffix("/" + token) }
        if dropped.count == remaining.count { return [:] }
        remaining = dropped
    }
    return [:]
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
            for (src, dest) in dict {
                if let dest = dest as? String {
                    name = dest
                } else if let dest = dest as? [String: Any] {
                    if let target = dest["target"] as? String {
                        name = target
                    } else {
                        name = src
                    }
                } else {
                    name = src
                }
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
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: binDir) else { return [] }
    return names.filter { base in
        !base.hasPrefix(".") && !base.hasSuffix(".dylib") && !base.hasSuffix(".prl")
    }.sorted()
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
    }
    let (rcC, outC, _) = tracking([brew, "list", "--cask"], 60)
    if rcC == 0 {
        info.casks = outC.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { Cask(name: $0) }
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
        (descMap, titleMap) = brewPackageMeta(data)
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
        for f in formulae {
            let fname = (f["name"] as? String) ?? (f["full_name"] as? String)
            guard let match = info.formulas.firstIndex(where: { $0.name == fname || $0.name == (f["full_name"] as? String) }) else { continue }
            info.formulas[match].aliases = (f["aliases"] as? [String])?.filter { !$0.isEmpty } ?? []
            let installed = f["installed"] as? [[String: Any]] ?? []
            let ver = (installed.first?["version"] as? String) ?? ((f["versions"] as? [String: Any])?["stable"] as? String)
            info.formulas[match].version = ver
        }
        for c in casksJSON {
            guard let token = c["token"] as? String,
                  let match = info.casks.firstIndex(where: { $0.name == token })
            else { continue }
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
            if parts.count >= 2, parts[1] == "started" || parts[1] == "running" {
                info.services.insert(parts[0])
            }
        }
    }

    info.outdated = queryBrew(brew, progress: progress, run: tracking)
    attachSummaries(info.outdated, summaries: descMap, titles: titleMap)
    var unique: [UntrustedCask] = []
    var seen = Set<String>()
    for u in refused where seen.insert(u.name.lowercased()).inserted {
        unique.append(u)
    }
    info.untrustedCasks = unique
    for u in unique {
        if let i = info.casks.firstIndex(where: { $0.name.lowercased() == u.name.lowercased() }) {
            info.casks[i].untrustedTap = u.tap
        }
    }
    return info
}
