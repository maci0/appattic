import Foundation

/// Per-line hot loops below use manual scans instead of NSRegularExpression:
/// ~5x faster on 5 000-line manager listings.

/// Packages page filter. `leaves` is distro orphans (`kind == "orphan"`), not Homebrew leaves.
public enum PackageListFilter: String, CaseIterable, Sendable {
    case all
    case leaves
    case globals
}

/// Manager label for what/why text. No manager in the tree carries `-`, so
/// skip the Foundation pass in the common case (saves ~0.4 µs per package).
private func packageLabel(_ manager: String) -> String {
    manager.contains("-") ? manager.replacingOccurrences(of: "-", with: " ") : manager
}

public func packageWhatText(manager: String, kind: String) -> String {
    let label = packageLabel(manager)
    if kind == "global" {
        return "User-global \(label) tool"
    }
    if manager == "dpkg" {
        return "Removed package still has config files (dpkg)"
    }
    return "Distro package nothing still needs (\(label))"
}

public func packageWhyText(manager: String, kind: String) -> String {
    let label = packageLabel(manager)
    if kind == "global" {
        return "Language tool installed with \(label) for this user, not a project lockfile."
    }
    if manager == "dpkg" {
        return "dpkg status rc: the package is gone, config remnants remain. Purge drops them."
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
    case "pacman", "aur":
        return "pacman -Rns \(q)"
    case "apt", "dpkg":
        return "apt-get purge -y \(q)"
    case "dnf":
        return "dnf remove -y \(q)"
    case "yum":
        return "yum remove -y \(q)"
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
    case "pip":
        return "pip uninstall -y --user \(q)"
    case "deno":
        return "deno uninstall --global \(q)"
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
    var body: [String] = []
    if !remove.isEmpty {
        body.append("")
        body.append("# Remove unused distro packages and language globals")
        for item in remove {
            body.append(withRootCmd(packageRemoveCommand(item)))
        }
    }
    if !markManual.isEmpty {
        body.append("")
        body.append("# Mark as manually installed (keep)")
        for item in markManual {
            if let cmd = packageMarkManualCommand(item) {
                body.append(withRootCmd(cmd))
            }
        }
    }
    if body.contains(where: { $0.hasPrefix("rootcmd ") }) {
        lines.append(scriptRootHelper)
    }
    lines.append(contentsOf: body)
    if remove.isEmpty && markManual.isEmpty {
        lines.append("")
        lines.append("# No packages selected.")
    }
    return lines.joined(separator: "\n") + "\n"
}

public func parsePacmanOrphans(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(256)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let pair = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring?)? in
            let (ls, le) = trimRange(u)
            guard ls < le else { return nil }
            // Skip `error:` / `warning:` diagnostics.
            if le - ls >= 6 {
                let err: [UInt8] = [0x65, 0x72, 0x72, 0x6F, 0x72, 0x3A]
                var isErr = true
                for k in 0..<6 where u[ls + k] != err[k] { isErr = false; break }
                if isErr { return nil }
            }
            if le - ls >= 8 {
                let warn: [UInt8] = [0x77, 0x61, 0x72, 0x6E, 0x69, 0x6E, 0x67, 0x3A]
                var isWarn = true
                for k in 0..<8 where u[ls + k] != warn[k] { isWarn = false; break }
                if isWarn { return nil }
            }
            var i = ls
            guard let name = tokBounds(u, le, &i), name.0 < name.1 else { return nil }
            let ver = tokBounds(u, le, &i)
            return (tokSub(raw, u, name), ver.map { tokSub(raw, u, $0) })
        }) ?? nil else { continue }
        out.append(makePackage(name: String(pair.0), manager: "pacman", kind: "orphan", version: pair.1.map(String.init)))
    }
    return out
}

public func parseDpkgRc(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(256)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let pair = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring?)? in
            let (ls, le) = trimRange(u)
            // `rc` + whitespace.
            guard le - ls > 3, u[ls] == 0x72, u[ls + 1] == 0x63, bWS(u[ls + 2]) else { return nil }
            var i = ls + 2
            guard let name = tokBounds(u, le, &i), name.0 < name.1 else { return nil }
            let ver = tokBounds(u, le, &i)
            return (tokSub(raw, u, name), ver.map { tokSub(raw, u, $0) })
        }) ?? nil else { continue }
        out.append(makePackage(name: String(pair.0), manager: "dpkg", kind: "orphan", version: pair.1.map(String.init)))
    }
    return out
}

/// `apt-get -s autoremove` row: `Remv name [version]`.
func parseAptAutoremoveLine(_ s: Substring) -> (name: String, version: String)? {
    s.utf8.withContiguousStorageIfAvailable { u -> (String, String)? in
        let (ls, le) = trimRange(u)
        // `Remv` + whitespace.
        guard le - ls > 5,
              u[ls] == 0x52, u[ls + 1] == 0x65, u[ls + 2] == 0x6D, u[ls + 3] == 0x76,
              bWS(u[ls + 4])
        else { return nil }
        var i = ls + 4
        guard let nameB = tokBounds(u, le, &i), nameB.0 < nameB.1 else { return nil }
        while i < le, bWS(u[i]) { i += 1 }
        guard i < le, u[i] == 0x5B /* [ */ else { return nil }
        i += 1
        let vs = i
        while i < le, u[i] != 0x5D /* ] */ {
            if bWS(u[i]) { return nil }
            i += 1
        }
        guard i < le, vs < i else { return nil }
        return (String(tokSub(s, u, nameB)), String(tokSub(s, u, (vs, i))))
    } ?? nil
}

public func parseAptAutoremove(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(256)
    var seen = Set<String>()
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let (name, ver) = parseAptAutoremoveLine(raw) else { continue }
        if seen.insert(name).inserted {
            out.append(makePackage(name: name, manager: "apt", kind: "orphan", version: ver))
        }
    }
    return out
}

public func parseDnfUnneeded(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(256)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if isDnfListingNoise(raw) { continue }
        guard let name = raw.utf8.withContiguousStorageIfAvailable({ u -> Substring? in
            let (ls, le) = trimRange(u)
            guard ls < le else { return nil }
            var i = ls
            guard let tb = tokBounds(u, le, &i), tb.0 < tb.1 else { return nil }
            return tokSub(raw, u, tb)
        }) ?? nil else { continue }
        out.append(makePackage(name: String(name), manager: "dnf", kind: "orphan"))
    }
    return out
}

/// `|`-separated table row: status | repo | name | current | available.
/// Returns column bounds (trimmed) or nil.
func pipeColumns(_ raw: Substring) -> [(Int, Int)]? {
    raw.utf8.withContiguousStorageIfAvailable { u -> [(Int, Int)]? in
        let (ls, le) = trimRange(u)
        guard ls < le else { return nil }
        var hasPipe = false
        for k in ls..<le where u[k] == 0x7C { hasPipe = true; break }
        guard hasPipe else { return nil }
        // Skip `--...` separator rows.
        if le - ls >= 2, u[ls] == 0x2D, u[ls + 1] == 0x2D { return nil }
        var cols: [(Int, Int)] = []
        cols.reserveCapacity(6)
        var f = ls
        while f <= le {
            var g = f
            while g < le, u[g] != 0x7C { g += 1 }
            let (ts, te) = trimBounds(u, g, ls: f)
            cols.append((ts, te))
            f = g + 1
        }
        return cols
    } ?? nil
}

public func parseZypperUnneeded(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(256)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let cols = pipeColumns(raw), cols.count >= 4 else { continue }
        guard let row = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring?)? in
            let name = tokSub(raw, u, cols[1])
            guard !name.isEmpty, name.caseInsensitiveCompare("Name") != .orderedSame else { return nil }
            let ver = tokSub(raw, u, cols[3])
            return (name, ver.isEmpty ? nil : ver)
        }) ?? nil else { continue }
        out.append(makePackage(name: String(row.0), manager: "zypper", kind: "orphan", version: row.1.map(String.init)))
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
    guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return [] }
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

/// `bun pm ls -g` tree row: `[box chars]name@version`. The name may be scoped
/// (`@scope/pkg`); the version is the text after the last `@`.
func parseBunTreeLine(_ s: Substring) -> (name: String, version: String)? {
    s.utf8.withContiguousStorageIfAvailable { u -> (String, String)? in
        let (ls, le) = trimRange(u)
        guard ls < le else { return nil }
        // Skip box-drawing + spaces: multi-byte UTF-8 (>= 0x80), space, tab.
        // Stops at the first ASCII byte that could start a package name.
        var p = ls
        while p < le {
            let c = u[p]
            if c == 0x20 || c == 0x09 || c >= 0x80 { p += 1; continue }
            break
        }
        // Last `@` in the remainder splits name from version.
        var at = -1
        var k = p
        while k < le {
            if u[k] == 0x40 { at = k }
            k += 1
        }
        guard at > p else { return nil }
        // Neither side may contain whitespace; name may not be a path line.
        var j = p
        while j < at, !bWS(u[j]) { j += 1 }
        guard j == at else { return nil }
        var v = at + 1
        while v < le, !bWS(u[v]) { v += 1 }
        guard v == le, v > at + 1 else { return nil }
        // Reject the bare node_modules root line.
        let nm: [UInt8] = [0x6E, 0x6F, 0x64, 0x65, 0x5F, 0x6D, 0x6F, 0x64, 0x75, 0x6C, 0x65, 0x73] // node_modules
        var k2 = p
        var isPath = false
        while k2 + nm.count <= at {
            var m = true
            for q in 0..<nm.count where u[k2 + q] != nm[q] { m = false; break }
            if m { isPath = true; break }
            k2 += 1
        }
        if isPath { return nil }
        // `@scope` without a package path is not a package row.
        if u[p] == 0x40 {
            var slash = false
            for q in p..<at where u[q] == 0x2F { slash = true; break }
            if !slash { return nil }
        }
        return (String(tokSub(s, u, (p, at))), String(tokSub(s, u, (at + 1, le))))
    } ?? nil
}

public func parseBunGlobalList(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(64)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let (name, ver) = parseBunTreeLine(raw) else { continue }
        out.append(makePackage(name: name, manager: "bun", kind: "global", version: ver))
    }
    return out
}

public func parsePipxList(_ text: String) -> [PackageEntry] {
    if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
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
    var out: [PackageEntry] = []
    out.reserveCapacity(64)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        // `pipx list` row: `package <name> <version>, installed using …`.
        // Case-insensitive `package` token, then two tokens; trailing comma
        // on the version is stripped.
        guard let hit = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring)? in
            let e = u.count
            var i = 0
            while true {
                guard let tb = tokBounds(u, e, &i) else { return nil }
                // `package`, ASCII case-insensitive (7 chars).
                guard tb.1 - tb.0 == 7 else { continue }
                var mm = true
                let want: [UInt8] = [0x70, 0x61, 0x63, 0x6B, 0x61, 0x67, 0x65]
                for q in 0..<7 {
                    var c = u[tb.0 + q]
                    if c >= 0x41, c <= 0x5A { c &+= 32 }
                    if c != want[q] { mm = false; break }
                }
                if !mm { continue }
                guard let nb = tokBounds(u, e, &i), nb.0 < nb.1,
                      let vb = tokBounds(u, e, &i), vb.0 < vb.1
                else { return nil }
                var ve = vb.1
                if u[ve - 1] == 0x2C /* , */ { ve -= 1 }
                guard ve > vb.0 else { return nil }
                return (tokSub(raw, u, nb), tokSub(raw, u, (vb.0, ve)))
            }
        }) ?? nil else { continue }
        out.append(makePackage(name: String(hit.0), manager: "pipx", kind: "global", version: String(hit.1)))
    }
    return out
}

public func parseUvToolList(_ text: String) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(64)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        // `uv tool list` row: `name v<version>`. `- item` rows and anything
        // without exactly two tokens drop out; version is digits and dots.
        guard let hit = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring)? in
            let (ls, le) = trimRange(u)
            guard ls < le, u[ls] != 0x2D /* - */ else { return nil }
            var i = ls
            guard let nb = tokBounds(u, le, &i), nb.0 < nb.1,
                  let vb = tokBounds(u, le, &i), vb.0 < vb.1, u[vb.0] == 0x76 /* v */
            else { return nil }
            var p = vb.0 + 1
            guard p < vb.1 else { return nil }
            while p < vb.1 {
                let c = u[p]
                guard bDigit(c) || c == 0x2E else { return nil }
                p += 1
            }
            while i < le, bWS(u[i]) { i += 1 }
            guard i == le else { return nil }
            return (tokSub(raw, u, nb), tokSub(raw, u, (vb.0 + 1, vb.1)))
        }) ?? nil else { continue }
        out.append(makePackage(name: String(hit.0), manager: "uv", kind: "global", version: String(hit.1)))
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
    let family = linuxDistroFamily(osRelease: osRelease ?? linuxOsReleaseText())
    let distro = resolveDistroPackageManager(family: family, which: which)
    // One closure per independent query; subprocess waits overlap via pmap.
    // Order is preserved (distro, npm, pnpm, bun, pipx, uv, pip, deno).
    // One summary progress line: per-query lines would interleave threads.
    // Closures never outlive this call (pmap joins), so rebinding is sound.
    progress?("  · listing distro orphans and language globals…")
    return withoutActuallyEscaping(which) { which in
        withoutActuallyEscaping(run) { run in
            var queries: [() -> [PackageEntry]] = []
            switch distro {
    case .pacman:
        queries.append {
            guard let text = runPackageQuery(
                which: which, run: run, names: ["pacman"], args: ["-Qdt"],
                ok: { $0 == 0 || $0 == 1 }
            ) else { return [] }
            return parsePacmanOrphans(text)
        }
    case .apt:
        queries.append {
            var result: [PackageEntry] = []
            if let text = runPackageQuery(
                which: which, run: run, names: ["apt-get", "apt"],
                args: ["-s", "autoremove"]
            ) {
                result.append(contentsOf: parseAptAutoremove(text))
            }
            if let text = runPackageQuery(
                which: which, run: run, names: ["dpkg"],
                args: ["-l"],
                ok: { $0 == 0 }
            ) {
                result.append(contentsOf: parseDpkgRc(text))
            }
            return result
        }
    case .dnf:
        queries.append {
            guard let text = runPackageQuery(
                which: which, run: run, names: ["dnf5", "dnf", "yum"],
                args: ["repoquery", "--unneeded", "--qf", "%{name}"]
            ) else { return [] }
            return parseDnfUnneeded(text)
        }
    case .zypper:
        queries.append {
            guard let text = runPackageQuery(
                which: which, run: run, names: ["zypper"],
                args: ["--non-interactive", "packages", "--unneeded"]
            ) else { return [] }
            return parseZypperUnneeded(text)
        }
    case nil:
        queries.append { [] }
    }
    queries.append {
        guard let text = runPackageQuery(
            which: which, run: run, names: ["npm"],
            args: ["ls", "-g", "--depth=0", "--json"]
        ) else { return [] }
        return parseNpmGlobalList(text)
    }
    queries.append {
        guard let text = runPackageQuery(
            which: which, run: run, names: ["pnpm"],
            args: ["ls", "-g", "--depth=0", "--json"]
        ) else { return [] }
        return parsePnpmGlobalList(text)
    }
    queries.append {
        guard let text = runPackageQuery(
            which: which, run: run, names: ["bun"],
            args: ["pm", "ls", "-g"]
        ) else { return [] }
        return parseBunGlobalList(text)
    }
    queries.append {
        if let json = runPackageQuery(
            which: which, run: run, names: ["pipx"],
            args: ["list", "--json"]
        ) {
            return parsePipxList(json)
        }
        if let text = runPackageQuery(
            which: which, run: run, names: ["pipx"],
            args: ["list"]
        ) {
            return parsePipxList(text)
        }
        return []
    }
    queries.append {
        guard let text = runPackageQuery(
            which: which, run: run, names: ["uv"],
            args: ["tool", "list"]
        ) else { return [] }
        return parseUvToolList(text)
    }
    queries.append {
        if let text = runPackageQuery(
            which: which, run: run, names: ["pip", "pip3"],
            args: ["list", "--user", "--not-required", "--format=json"]
        ) {
            return parsePipUserList(text)
        }
        if let text = runPackageQuery(
            which: which, run: run, names: ["pip", "pip3"],
            args: ["list", "--user", "--format=json"]
        ) {
            return parsePipUserList(text)
        }
        return []
    }
    var out = pmap(queries, workers: 4) { $0() }.flatMap { $0 }
    out.append(contentsOf: listDenoGlobals())
    return out
        }
    }
}

public func parsePipUserList(_ text: String) -> [PackageEntry] {
    guard let arr = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
        return []
    }
    var out: [PackageEntry] = []
    for obj in arr {
        guard let name = obj["name"] as? String, !name.isEmpty else { continue }
        let version = obj["version"] as? String
        out.append(makePackage(name: name, manager: "pip", kind: "global", version: version))
    }
    return out
}

func listDenoGlobals() -> [PackageEntry] {
    let bin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".deno/bin")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: bin.path) else {
        return []
    }
    return names.compactMap { name -> PackageEntry? in
        if name.isEmpty || name.hasPrefix(".") || name == "deno" || name == "deno.exe" { return nil }
        return makePackage(name: name, manager: "deno", kind: "global")
    }
}
