import Foundation

public enum PackageListFilter: String, CaseIterable, Sendable {
    case all
    case leaves
    case globals
}

public func packageWhatText(manager: String, kind: String) -> String {
    let label = manager.replacingOccurrences(of: "-", with: " ")
    if kind == "global" {
        return "User-global \(label) tool"
    }
    return "Distro package nothing still needs (\(label))"
}

public func packageWhyText(manager: String, kind: String) -> String {
    let label = manager.replacingOccurrences(of: "-", with: " ")
    if kind == "global" {
        return "Language tool installed with \(label) for this user, not a project lockfile."
    }
    return "\(label) reports this as an orphan: installed as a dependency, nothing installed still requires it."
}

func makePackage(
    name: String,
    manager: String,
    kind: String,
    version: String? = nil,
    sizeBytes: Int? = nil,
    children: [String]? = nil
) -> PackageEntry {
    PackageEntry(
        name: name,
        manager: manager,
        kind: kind,
        version: version,
        size_bytes: sizeBytes,
        size_measured: sizeBytes != nil,
        summary: packageWhatText(manager: manager, kind: kind),
        reason: packageWhyText(manager: manager, kind: kind),
        children: children
    )
}

public func filterPackages(
    _ rows: [PackageEntry],
    filter: PackageListFilter,
    search: String = ""
) -> [PackageEntry] {
    let q = search.lowercased()
    return rows.filter { item in
        switch filter {
        case .all:
            break
        case .leaves:
            if item.kind != "orphan" { return false }
        case .globals:
            if item.kind != "global" { return false }
        }
        if q.isEmpty { return true }
        return item.name.lowercased().contains(q)
            || item.manager.lowercased().contains(q)
            || item.kind.lowercased().contains(q)
            || (item.version ?? "").lowercased().contains(q)
            || (item.summary ?? "").lowercased().contains(q)
            || (item.reason ?? "").lowercased().contains(q)
    }.sorted { a, b in
        switch (a.size_bytes, b.size_bytes) {
        case let (l?, r?):
            if l != r { return l > r }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return a.name.lowercased() < b.name.lowercased()
    }
}

public func packageRemoveCommand(_ entry: PackageEntry) -> String {
    let q = shellQuote(entry.name)
    switch entry.manager {
    case "pacman":
        return "pacman -Rns \(q)"
    case "apt":
        return "apt-get purge -y \(q)"
    case "dnf":
        return "dnf remove -y \(q)"
    case "zypper":
        return "zypper --non-interactive rm \(q)"
    case "npm":
        return "npm -g uninstall \(q)"
    case "pnpm":
        return "pnpm remove -g \(q)"
    case "bun":
        return "bun remove -g \(q)"
    case "pipx":
        return "pipx uninstall \(q)"
    case "uv":
        return "uv tool uninstall \(q)"
    default:
        return "# \(entry.manager) \(q)"
    }
}

public func packageMarkManualCommand(_ entry: PackageEntry) -> String? {
    guard entry.canMarkManual else { return nil }
    let q = shellQuote(entry.name)
    switch entry.manager {
    case "apt":
        return "apt-mark manual \(q)"
    case "pacman":
        return "pacman -D --asexplicit \(q)"
    case "dnf":
        return "dnf mark install \(q)"
    case "zypper":
        return "zypper --non-interactive install \(q)"
    default:
        return nil
    }
}

public func packageActionScript(remove: [PackageEntry], markManual: [PackageEntry]) -> String {
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic package script",
        "# Review every line before running. Nothing here is deleted automatically.",
        "# Distro system updates are not included.",
    ]
    if !remove.isEmpty {
        lines.append("")
        lines.append("# Remove unused distro packages and language globals")
        for item in remove {
            lines.append(packageRemoveCommand(item))
        }
    }
    if !markManual.isEmpty {
        lines.append("")
        lines.append("# Mark as manually installed (keep)")
        for item in markManual {
            if let cmd = packageMarkManualCommand(item) {
                lines.append(cmd)
            }
        }
    }
    if remove.isEmpty && markManual.isEmpty {
        lines.append("")
        lines.append("# No packages selected.")
    }
    return lines.joined(separator: "\n") + "\n"
}

public func parsePacmanOrphans(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("error:") || s.hasPrefix("warning:") { continue }
        let parts = s.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = parts.first, !name.isEmpty else { continue }
        let version = parts.count >= 2 ? parts[1] : nil
        out.append(makePackage(name: name, manager: "pacman", kind: "orphan", version: version))
    }
    return out
}

public func parseAptAutoremove(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    var seen = Set<String>()
    let remv = try! NSRegularExpression(pattern: #"^Remv\s+(\S+)\s+\[([^\]]+)\]"#)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = remv.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
              let n = Range(m.range(at: 1), in: s),
              let v = Range(m.range(at: 2), in: s)
        else { continue }
        let name = String(s[n])
        if seen.insert(name).inserted {
            out.append(makePackage(name: name, manager: "apt", kind: "orphan", version: String(s[v])))
        }
    }
    return out
}

public func parseDnfUnneeded(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { continue }
        let low = s.lowercased()
        if low.hasPrefix("last metadata") || low.hasPrefix("packages") || low.hasPrefix("finding") {
            continue
        }
        let name = s.split(whereSeparator: \.isWhitespace).map(String.init).first ?? ""
        if name.isEmpty { continue }
        out.append(makePackage(name: name, manager: "dnf", kind: "orphan"))
    }
    return out
}

public func parseZypperUnneeded(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || !s.contains("|") || s.hasPrefix("--") { continue }
        let cols = s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard cols.count >= 4 else { continue }
        let name = cols[1]
        if name.isEmpty || name.caseInsensitiveCompare("Name") == .orderedSame { continue }
        let version = cols.count >= 4 && !cols[3].isEmpty ? cols[3] : nil
        out.append(makePackage(name: name, manager: "zypper", kind: "orphan", version: version))
    }
    return out
}

func jsonDependencyEntries(_ value: Any) -> [(String, String?)] {
    var out: [(String, String?)] = []
    if let arr = value as? [Any] {
        for item in arr {
            out.append(contentsOf: jsonDependencyEntries(item))
        }
        return out
    }
    guard let obj = value as? [String: Any],
          let deps = obj["dependencies"] as? [String: Any]
    else { return out }
    for (name, raw) in deps {
        var version: String?
        if let child = raw as? [String: Any] {
            version = child["version"] as? String
        } else if let text = raw as? String {
            version = text
        }
        out.append((name, version))
    }
    return out
}

func parseGlobalJSON(_ text: String, manager: String) -> [PackageEntry] {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data)
    else { return [] }
    return jsonDependencyEntries(obj).map { name, version in
        makePackage(name: name, manager: manager, kind: "global", version: version)
    }
}

public func parseNpmGlobalList(_ text: String) -> [PackageEntry] {
    parseGlobalJSON(text, manager: "npm")
}

public func parsePnpmGlobalList(_ text: String) -> [PackageEntry] {
    parseGlobalJSON(text, manager: "pnpm")
}

public func parseBunGlobalList(_ text: String) -> [PackageEntry] {
    let re = try! NSRegularExpression(pattern: #"^[├└│\s─]*((?:@[^@\s]+/)?[^@\s]+)@(\S+)"#)
    var out: [PackageEntry] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
              let n = Range(m.range(at: 1), in: s),
              let v = Range(m.range(at: 2), in: s)
        else { continue }
        out.append(makePackage(name: String(s[n]), manager: "bun", kind: "global", version: String(s[v])))
    }
    return out
}

public func parsePipxList(_ text: String) -> [PackageEntry] {
    if let data = text.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let venvs = obj["venvs"] as? [String: Any]
    {
        var out: [PackageEntry] = []
        for (fallback, raw) in venvs {
            var name = fallback
            var version: String?
            if let meta = raw as? [String: Any],
               let metadata = meta["metadata"] as? [String: Any],
               let main = metadata["main_package"] as? [String: Any]
            {
                if let pkg = main["package"] as? String, !pkg.isEmpty { name = pkg }
                version = main["package_version"] as? String
            }
            out.append(makePackage(name: name, manager: "pipx", kind: "global", version: version))
        }
        return out.sorted { $0.name < $1.name }
    }
    let re = try! NSRegularExpression(pattern: #"package\s+(\S+)\s+(\S+),"#)
    var out: [PackageEntry] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
              let n = Range(m.range(at: 1), in: s),
              let v = Range(m.range(at: 2), in: s)
        else { continue }
        out.append(makePackage(name: String(s[n]), manager: "pipx", kind: "global", version: String(s[v])))
    }
    return out
}

public func parseUvToolList(_ text: String) -> [PackageEntry] {
    let re = try! NSRegularExpression(pattern: #"^(\S+)\s+v(\S+)"#)
    var out: [PackageEntry] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("-") { continue }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
              let n = Range(m.range(at: 1), in: s),
              let v = Range(m.range(at: 2), in: s)
        else { continue }
        out.append(makePackage(name: String(s[n]), manager: "uv", kind: "global", version: String(s[v])))
    }
    return out
}

func runPackageQuery(
    which: WhichFn,
    run: CommandRun,
    names: [String],
    args: [String],
    timeout: TimeInterval = 60,
    ok: (Int32) -> Bool = { $0 == 0 }
) -> String? {
    for name in names {
        guard let path = which(name) else { continue }
        let (rc, out, _) = run([path] + args, timeout)
        if ok(rc) { return out }
    }
    return nil
}

public func collectPackages(
    progress: ((String) -> Void)? = nil,
    which: WhichFn = whichCommand,
    run: CommandRun = runCommand,
    osRelease: String? = nil
) -> [PackageEntry] {
    var out: [PackageEntry] = []
    let family = linuxDistroFamily(osRelease: osRelease ?? linuxOsReleaseText())
    func addOrphans() {
        switch family {
        case "arch":
            progress?("  · listing pacman orphans…")
            if let text = runPackageQuery(
                which: which, run: run, names: ["pacman"], args: ["-Qdt"],
                ok: { $0 == 0 || $0 == 1 }
            ) {
                out.append(contentsOf: parsePacmanOrphans(text))
            }
        case "debian":
            progress?("  · listing apt autoremove candidates…")
            if let text = runPackageQuery(
                which: which, run: run, names: ["apt-get", "apt"],
                args: ["-s", "autoremove"]
            ) {
                out.append(contentsOf: parseAptAutoremove(text))
            }
        case "fedora":
            progress?("  · listing dnf unneeded packages…")
            if let text = runPackageQuery(
                which: which, run: run, names: ["dnf5", "dnf"],
                args: ["repoquery", "--unneeded", "--qf", "%{name}"]
            ) {
                out.append(contentsOf: parseDnfUnneeded(text))
            } else if let text = runPackageQuery(
                which: which, run: run, names: ["dnf5", "dnf"],
                args: ["leaves"]
            ) {
                out.append(contentsOf: parseDnfUnneeded(text))
            }
        case "suse":
            progress?("  · listing zypper unneeded packages…")
            if let text = runPackageQuery(
                which: which, run: run, names: ["zypper"],
                args: ["--non-interactive", "packages", "--unneeded"]
            ) {
                out.append(contentsOf: parseZypperUnneeded(text))
            }
        default:
            if which("pacman") != nil {
                if let text = runPackageQuery(
                    which: which, run: run, names: ["pacman"], args: ["-Qdt"],
                    ok: { $0 == 0 || $0 == 1 }
                ) {
                    out.append(contentsOf: parsePacmanOrphans(text))
                }
            } else if which("dnf5") != nil || which("dnf") != nil {
                if let text = runPackageQuery(
                    which: which, run: run, names: ["dnf5", "dnf"],
                    args: ["repoquery", "--unneeded", "--qf", "%{name}"]
                ) {
                    out.append(contentsOf: parseDnfUnneeded(text))
                }
            } else if which("zypper") != nil {
                if let text = runPackageQuery(
                    which: which, run: run, names: ["zypper"],
                    args: ["--non-interactive", "packages", "--unneeded"]
                ) {
                    out.append(contentsOf: parseZypperUnneeded(text))
                }
            } else if let text = runPackageQuery(
                which: which, run: run, names: ["apt-get", "apt"],
                args: ["-s", "autoremove"]
            ) {
                out.append(contentsOf: parseAptAutoremove(text))
            }
        }
    }
    addOrphans()
    progress?("  · listing language globals…")
    if let text = runPackageQuery(
        which: which, run: run, names: ["npm"],
        args: ["ls", "-g", "--depth=0", "--json"]
    ) {
        out.append(contentsOf: parseNpmGlobalList(text))
    }
    if let text = runPackageQuery(
        which: which, run: run, names: ["pnpm"],
        args: ["ls", "-g", "--depth=0", "--json"]
    ) {
        out.append(contentsOf: parsePnpmGlobalList(text))
    }
    if let text = runPackageQuery(
        which: which, run: run, names: ["bun"],
        args: ["pm", "ls", "-g"]
    ) {
        out.append(contentsOf: parseBunGlobalList(text))
    }
    if let json = runPackageQuery(
        which: which, run: run, names: ["pipx"],
        args: ["list", "--json"]
    ) {
        out.append(contentsOf: parsePipxList(json))
    } else if let text = runPackageQuery(
        which: which, run: run, names: ["pipx"],
        args: ["list"]
    ) {
        out.append(contentsOf: parsePipxList(text))
    }
    if let text = runPackageQuery(
        which: which, run: run, names: ["uv"],
        args: ["tool", "list"]
    ) {
        out.append(contentsOf: parseUvToolList(text))
    }
    return out
}
