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
    let q = posixFolded(search)
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
        return posixFolded(item.name).contains(q)
            || posixFolded(item.manager).contains(q)
            || posixFolded(item.kind).contains(q)
            || posixFolded(item.version ?? "").contains(q)
            || posixFolded(item.summary ?? "").contains(q)
            || posixFolded(item.reason ?? "").contains(q)
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
        // Collated, not folded: the POSIX fold still orders by code point
        // afterwards, so "Zebra" came before "apple" and "Ä" after "Z". Manager
        // breaks the tie, since two managers can report the same name and
        // `sort` is not stable.
        return collatedBefore(a.name, b.name, tieBreak: a.manager, b.manager)
    }
}

/// Every removal is guarded: a generated script runs under `set -e`, so a
/// second run over an already-removed package has to skip the line instead of
/// exiting nonzero and abandoning the packages after it. A guard asks the
/// manager what it still lists, which is deliberately broader than the
/// collector's query: the collector wants the strict "nobody needs this"
/// answer, while the guard only has to be sure the package is still installed.
///
/// `home` is the account's home directory, for the one guard that names a path
/// rather than asking a manager. It is quoted like any other value, so a home
/// with a space in it still reaches `/bin/sh` as one word.
public func packageRemoveCommand(
    _ entry: PackageEntry,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path
) -> String {
    guard isSafeCommandArgument(entry.name) else {
        return "# skipped \(shellComment(entry.name)): name reads as a command option"
    }
    let q = shellQuote(entry.name)
    /// `grep -F --` on the manager's own listing, whose row format the
    /// parsers above already pin.
    func listed(_ cmd: String, row: String) -> String {
        "\(cmd) | grep -qF -- \(shellQuote(row))"
    }
    switch entry.manager {
    case "pacman", "aur":
        return guardedRemoveCommand(present: "pacman -Qq \(q)", remove: "pacman -Rns \(q)")
    case "apt", "dpkg":
        return guardedRemoveCommand(present: "dpkg -s \(q)", remove: "apt-get purge -y \(q)")
    case "dnf":
        return guardedRemoveCommand(present: "rpm -q \(q)", remove: "dnf remove -y \(q)")
    case "yum":
        return guardedRemoveCommand(present: "rpm -q \(q)", remove: "yum remove -y \(q)")
    case "zypper":
        return guardedRemoveCommand(present: "rpm -q \(q)", remove: "zypper --non-interactive rm \(q)")
    case "npm":
        return guardedRemoveCommand(
            present: listed("npm ls -g --depth=0", row: "\(entry.name)@"),
            remove: "npm -g uninstall \(q)"
        )
    case "pnpm":
        return guardedRemoveCommand(
            present: listed("pnpm ls -g --depth=0", row: "\(entry.name)@"),
            remove: "pnpm remove -g \(q)"
        )
    case "bun":
        return guardedRemoveCommand(
            present: listed("bun pm ls -g", row: "\(entry.name)@"),
            remove: "bun remove -g \(q)"
        )
    case "pipx":
        return guardedRemoveCommand(
            present: listed("pipx list", row: "package \(entry.name) "),
            remove: "pipx uninstall \(q)"
        )
    case "uv":
        return guardedRemoveCommand(
            present: listed("uv tool list", row: "\(entry.name) v"),
            remove: "uv tool uninstall \(q)"
        )
    case "pip":
        return guardedRemoveCommand(present: "pip show \(q)", remove: "pip uninstall -y --user \(q)")
    case "deno":
        // The one guard with no manager to ask: it tests the file the removal
        // takes away. That path has to be one `/bin/sh` resolves, and `~` is
        // not: tilde expansion is an interactive-shell extension that POSIX `sh`
        // does not perform, so `test -e ~/.deno/bin/name` tests a directory
        // named `~` under the working directory, finds nothing, and skips the
        // removal on every run. The resolved home is absolute and expands
        // nowhere, so the guard fires while the file is still there and skips
        // the line once it is gone.
        return guardedRemoveCommand(
            present: "test -e \(shellQuote(home))/.deno/bin/\(q)",
            remove: "deno uninstall --global \(q)"
        )
    default:
        // A comment line, so the name goes through `shellComment`: a quoted
        // newline is still a newline, and it would end the comment early.
        return "# \(shellComment(entry.manager)) \(shellComment(entry.name))"
    }
}

/// Mark one package as manually installed, wrapped in the same presence guard
/// every removal uses.
///
/// The rows a mark-manual line names are the `kind == "orphan"` rows, which is
/// exactly the set `packageRemoveCommand` purges, and the two lists are
/// generated from one snapshot and saved to one script file. A person who kept
/// that file and runs it again reaches a mark-manual line for a package an
/// earlier run purged, and every manager here answers that with a nonzero exit:
/// `apt-mark manual` cannot locate the package, `dnf mark install` and
/// `zypper --non-interactive install` have nothing to mark. Under `set -e` that
/// stops the script at the line, so every package below it loses its mark and
/// the run ends on a status that reads like a failure rather than a no-op.
///
/// The guard asks the manager the same question the removal's guard asks, so a
/// package that is still there is marked and a package that is gone is skipped
/// and the script continues.
public func packageMarkManualCommand(_ entry: PackageEntry) -> String? {
    guard entry.canMarkManual else { return nil }
    guard isSafeCommandArgument(entry.name) else { return nil }
    let q = shellQuote(entry.name)
    switch entry.manager {
    case "apt", "dpkg":
        return guardedCommand(present: "dpkg -s \(q)", action: "apt-mark manual \(q)")
    case "pacman":
        return guardedCommand(present: "pacman -Qq \(q)", action: "pacman -D --asexplicit \(q)")
    case "dnf":
        return guardedCommand(present: "rpm -q \(q)", action: "dnf mark install \(q)")
    case "zypper":
        return guardedCommand(present: "rpm -q \(q)", action: "zypper --non-interactive install \(q)")
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
    if body.contains(where: callsRootHelper) {
        lines.append(scriptRootHelper)
    }
    lines.append(contentsOf: body)
    if remove.isEmpty && markManual.isEmpty {
        lines.append("")
        lines.append("# No packages selected.")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// One package per line of a manager listing, in listing order. `line` returns
/// nil for a line that is not a package row, so a manager carries its row
/// grammar and nothing else.
private func parsePackageLines(
    _ text: String,
    capacity: Int,
    _ line: (Substring) -> PackageEntry?
) -> [PackageEntry] {
    var out: [PackageEntry] = []
    out.reserveCapacity(capacity)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let pkg = line(raw) else { continue }
        out.append(pkg)
    }
    return out
}

public func parsePacmanOrphans(_ text: String) -> [PackageEntry] {
    parsePackageLines(text, capacity: 256) { raw in
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
        }) ?? nil else { return nil }
        return makePackage(name: String(pair.0), manager: "pacman", kind: "orphan", version: pair.1.map(String.init))
    }
}

public func parseDpkgRc(_ text: String) -> [PackageEntry] {
    parsePackageLines(text, capacity: 256) { raw in
        guard let pair = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring?)? in
            let (ls, le) = trimRange(u)
            // `rc` + whitespace.
            guard le - ls > 3, u[ls] == 0x72, u[ls + 1] == 0x63, bWS(u[ls + 2]) else { return nil }
            var i = ls + 2
            guard let name = tokBounds(u, le, &i), name.0 < name.1 else { return nil }
            let ver = tokBounds(u, le, &i)
            return (tokSub(raw, u, name), ver.map { tokSub(raw, u, $0) })
        }) ?? nil else { return nil }
        return makePackage(name: String(pair.0), manager: "dpkg", kind: "orphan", version: pair.1.map(String.init))
    }
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
    // `apt autoremove --dry-run` can name a package once per proposed removal,
    // so the first row wins and the rest are dropped.
    var seen = Set<String>()
    return parsePackageLines(text, capacity: 256) { raw in
        guard let (name, ver) = parseAptAutoremoveLine(raw), seen.insert(name).inserted else {
            return nil
        }
        return makePackage(name: name, manager: "apt", kind: "orphan", version: ver)
    }
}

public func parseDnfUnneeded(_ text: String) -> [PackageEntry] {
    parsePackageLines(text, capacity: 256) { raw in
        if isDnfListingNoise(raw) { return nil }
        guard let name = raw.utf8.withContiguousStorageIfAvailable({ u -> Substring? in
            let (ls, le) = trimRange(u)
            guard ls < le else { return nil }
            var i = ls
            guard let tb = tokBounds(u, le, &i), tb.0 < tb.1 else { return nil }
            return tokSub(raw, u, tb)
        }) ?? nil else { return nil }
        return makePackage(name: String(name), manager: "dnf", kind: "orphan")
    }
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
    parsePackageLines(text, capacity: 256) { raw in
        guard let cols = pipeColumns(raw), cols.count >= 4 else { return nil }
        guard let row = raw.utf8.withContiguousStorageIfAvailable({ u -> (Substring, Substring?)? in
            let name = tokSub(raw, u, cols[1])
            guard !name.isEmpty, name.caseInsensitiveCompare("Name") != .orderedSame else { return nil }
            let ver = tokSub(raw, u, cols[3])
            return (name, ver.isEmpty ? nil : ver)
        }) ?? nil else { return nil }
        return makePackage(name: String(row.0), manager: "zypper", kind: "orphan", version: row.1.map(String.init))
    }
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
    // JSON objects decode into a dictionary, whose iteration order Swift
    // reseeds per process: unsorted, the package list reorders every run.
    for (name, raw) in deps.sorted(by: { $0.key < $1.key }) {
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

func globalPackageEntries(_ document: Any, manager: String) -> [PackageEntry] {
    jsonDependencyEntries(document).map { name, version in
        makePackage(name: name, manager: manager, kind: "global", version: version)
    }
}

func parseGlobalJSON(_ text: String, manager: String) -> [PackageEntry] {
    guard let document = parseJSONDocument(text) else { return [] }
    return globalPackageEntries(document, manager: manager)
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
    parsePackageLines(text, capacity: 64) { raw in
        guard let (name, ver) = parseBunTreeLine(raw) else { return nil }
        return makePackage(name: name, manager: "bun", kind: "global", version: ver)
    }
}

/// The `venvs` object of a `pipx list --json` answer, as rows. Empty for a
/// document without one, which is what the text fallback below answers for an
/// older pipx.
func pipxListEntries(_ document: Any) -> [PackageEntry] {
    guard let obj = document as? [String: Any],
          let venvs = obj["venvs"] as? [String: Any]
    else { return [] }
    var out: [PackageEntry] = []
    for (fallback, raw) in venvs.sorted(by: { $0.key < $1.key }) {
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
    // Collated, so "Ä" is not parked after "Z" for a German or Swedish
    // reader. `venvs` is a JSON object and its key order varies, so the
    // version has to break the tie: `sort` is not stable.
    return out.sorted { collatedBefore($0.name, $1.name, tieBreak: $0.version ?? "", $1.version ?? "") }
}

public func parsePipxList(_ text: String) -> [PackageEntry] {
    if let document = parseJSONDocument(text),
       let obj = document as? [String: Any],
       obj["venvs"] as? [String: Any] != nil
    {
        return pipxListEntries(document)
    }
    return parsePackageLines(text, capacity: 64) { raw in
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
        }) ?? nil else { return nil }
        return makePackage(name: String(hit.0), manager: "pipx", kind: "global", version: String(hit.1))
    }
}

public func parseUvToolList(_ text: String) -> [PackageEntry] {
    parsePackageLines(text, capacity: 64) { raw in
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
        }) ?? nil else { return nil }
        return makePackage(name: String(hit.0), manager: "uv", kind: "global", version: String(hit.1))
    }
}

/// One package-manager query. `failed` tells "the manager is not installed"
/// apart from "every candidate binary answered with a failure status or an
/// unreadable payload": the first is a real empty answer, the second is an
/// unknown, and an unknown written to the scan cache is served as "no orphans"
/// for `scanCacheMaxAge`. Recording the unknown is the caller's job, under the
/// label it wants the user to see, because a query that is one step of a chain
/// has not failed until every step has.
struct PackageQueryResult {
    var output: String?
    /// The decoded `output`, for a step that declared its answer JSON. Decoding
    /// a listing to find out whether it decodes and decoding it again to read
    /// it is two passes over a document that runs to megabytes on a machine
    /// with a few hundred packages, so the query hands the object over.
    var json: Any?
    var failed: Bool
}

/// `text` decoded as JSON, or nil when it is not JSON. Every JSON parser in
/// this module goes through here, so one listing is decoded once per query
/// rather than once per question asked about it. The query layer takes the
/// object rather than the text for the same reason: every parser here answers
/// an unreadable payload with an empty list, and an empty list is what the
/// report prints and the scan cache stores.
func parseJSONDocument(_ text: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8))
}

/// One argument spelling for a query, and whether it answers with JSON.
/// Whether the answer is JSON belongs to the spelling, not to the manager:
/// `pipx list --json` and `pipx list` are both pipx, and only the first one
/// can be held to a JSON document.
struct PackageQueryStep {
    var args: [String]
    var json: Bool = false
    /// Reads a step whose answer is JSON, from the object `runPackageQuery`
    /// decoded. Set on every `json` step, so the listing is decoded once
    /// instead of once to check it and again to read it. The chain's `parse`
    /// stays for the text spellings of the same manager.
    var parseJSON: ((Any) -> [PackageEntry])?
}

func runPackageQuery(
    which: WhichFn,
    run: CommandRun,
    names: [String],
    args: [String],
    timeout: TimeInterval = 60,
    ok: (Int32) -> Bool = { $0 == 0 },
    json: Bool = false
) -> PackageQueryResult {
    var attempted = false
    for name in names {
        guard let path = which(name) else { continue }
        attempted = true
        let (rc, out, _) = run([path] + args, timeout)
        if ok(rc) {
            // A success status carrying a payload that is not JSON is a broken
            // answer, not the empty listing the parser would return from it. It
            // is not recorded here: a chain has further spellings to try, and
            // records the manager only when none of them answers. The next
            // binary is tried too, because `names` are alternate spellings of
            // one manager: a broken `pip` must not shadow a `pip3` that answers.
            if json {
                guard let decoded = parseJSONDocument(out) else { continue }
                return PackageQueryResult(output: out, json: decoded, failed: false)
            }
            return PackageQueryResult(output: out, json: nil, failed: false)
        }
    }
    return PackageQueryResult(output: nil, json: nil, failed: attempted)
}

/// One manager, one or more argument spellings tried in order, the first
/// answer parsed. A failure is recorded only when every spelling failed, so
/// `pipx list --json` failing on an old pipx leaves the check alone when
/// `pipx list` answered. `parse` reads a text answer and is nil for a chain
/// whose every step is JSON, each of those steps carrying its own `parseJSON`.
/// Returns the parsed rows, empty when nothing answered.
func runPackageQueryChain(
    _ steps: [PackageQueryStep],
    which: WhichFn,
    run: CommandRun,
    names: [String],
    label: String,
    timeout: TimeInterval = 60,
    ok: (Int32) -> Bool = { $0 == 0 },
    parse: ((String) -> [PackageEntry])? = nil
) -> [PackageEntry] {
    var failed = false
    for step in steps {
        let result = runPackageQuery(
            which: which, run: run, names: names, args: step.args,
            timeout: timeout, ok: ok, json: step.json
        )
        failed = failed || result.failed
        if let out = result.output {
            if let decoded = result.json, let parseJSON = step.parseJSON { return parseJSON(decoded) }
            guard let parse else { continue }
            return parse(out)
        }
    }
    if failed { noteScanCheckFailed(label) }
    return []
}

public func collectPackages(
    progress: ((String) -> Void)? = nil,
    which: @escaping WhichFn = whichCommand,
    run: @escaping CommandRun = runCommand,
    osRelease: String? = nil
) -> [PackageEntry] {
    let family = linuxDistroFamily(osRelease: osRelease ?? linuxOsReleaseText())
    let distro = resolveDistroPackageManager(family: family, which: which)
    // One closure per independent query; subprocess waits overlap via pmap.
    // Order is preserved (distro, npm, pnpm, bun, pipx, uv, pip, deno).
    // One summary progress line: per-query lines would interleave threads.
    progress?("  · listing distro orphans and language globals…")
    var queries: [() -> [PackageEntry]] = []
    switch distro {
        case .pacman:
            queries.append {
                return runPackageQueryChain(
                    [PackageQueryStep(args: ["-Qdt"])],
                    which: which, run: run, names: ["pacman"], label: "pacman",
                    ok: { $0 == 0 || $0 == 1 }, parse: parsePacmanOrphans
                )
            }
        case .apt, .dpkg:
            queries.append {
                var result: [PackageEntry] = []
                let autoremove = runPackageQuery(
                    which: which, run: run, names: ["apt-get", "apt"],
                    args: ["-s", "autoremove"]
                )
                if autoremove.failed { noteScanCheckFailed("apt") }
                if let text = autoremove.output {
                    result.append(contentsOf: parseAptAutoremove(text))
                }
                let dpkg = runPackageQuery(
                    which: which, run: run, names: ["dpkg"],
                    args: ["-l"]
                )
                if dpkg.failed { noteScanCheckFailed("dpkg") }
                if let text = dpkg.output {
                    result.append(contentsOf: parseDpkgRc(text))
                }
                return result
            }
        case .dnf:
            queries.append {
                return runPackageQueryChain(
                    [PackageQueryStep(args: ["repoquery", "--unneeded", "--qf", "%{name}"])],
                    which: which, run: run, names: ["dnf5", "dnf", "yum"],
                    label: "dnf", parse: parseDnfUnneeded
                )
            }
        case .some(DistroPackageManager.zypperPkg):
            queries.append {
                return runPackageQueryChain(
                    [PackageQueryStep(args: ["--non-interactive", "packages", "--unneeded"])],
                    which: which, run: run, names: ["zypper"],
                    label: "zypper", parse: parseZypperUnneeded
                )
            }
        case nil:
            break
    }
    queries.append {
        return runPackageQueryChain(
            [PackageQueryStep(args: ["ls", "-g", "--depth=0", "--json"], json: true,
                parseJSON: { globalPackageEntries($0, manager: "npm") })],
            which: which, run: run, names: ["npm"], label: "npm"
        )
    }
    queries.append {
        return runPackageQueryChain(
            [PackageQueryStep(args: ["ls", "-g", "--depth=0", "--json"], json: true,
                parseJSON: { globalPackageEntries($0, manager: "pnpm") })],
            which: which, run: run, names: ["pnpm"], label: "pnpm"
        )
    }
    queries.append {
        return runPackageQueryChain(
            [PackageQueryStep(args: ["pm", "ls", "-g"])],
            which: which, run: run, names: ["bun"], label: "bun",
            parse: parseBunGlobalList
        )
    }
    queries.append {
        return runPackageQueryChain(
            [
                PackageQueryStep(args: ["list", "--json"], json: true, parseJSON: pipxListEntries),
                PackageQueryStep(args: ["list"]),
            ],
            which: which, run: run, names: ["pipx"], label: "pipx",
            parse: parsePipxList
        )
    }
    queries.append {
        return runPackageQueryChain(
            [PackageQueryStep(args: ["tool", "list"])],
            which: which, run: run, names: ["uv"], label: "uv",
            parse: parseUvToolList
        )
    }
    queries.append {
        return runPackageQueryChain(
            [
                PackageQueryStep(args: ["list", "--user", "--not-required", "--format=json"], json: true,
                                 parseJSON: pipUserListEntries),
                PackageQueryStep(args: ["list", "--user", "--format=json"], json: true,
                                 parseJSON: pipUserListEntries),
            ],
            which: which, run: run, names: ["pip", "pip3"], label: "pip"
        )
    }
    var out = pmap(queries, workers: 4) { $0() }.flatMap { $0 }
    out.append(contentsOf: listDenoGlobals())
    return out
}

func pipUserListEntries(_ document: Any) -> [PackageEntry] {
    guard let arr = document as? [[String: Any]] else { return [] }
    var out: [PackageEntry] = []
    for obj in arr {
        guard let name = obj["name"] as? String, !name.isEmpty else { continue }
        let version = obj["version"] as? String
        out.append(makePackage(name: name, manager: "pip", kind: "global", version: version))
    }
    return out
}

public func parsePipUserList(_ text: String) -> [PackageEntry] {
    guard let document = parseJSONDocument(text) else { return [] }
    return pipUserListEntries(document)
}

func listDenoGlobals() -> [PackageEntry] {
    let bin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".deno/bin")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: bin.path) else {
        return []
    }
    // Sorted: readdir order varies per process, and the list is reported and
    // written to the cache in the order it is built.
    return names.sorted().compactMap { name -> PackageEntry? in
        if name.isEmpty || name.hasPrefix(".") || name == "deno" || name == "deno.exe" { return nil }
        return makePackage(name: name, manager: "deno", kind: "global")
    }
}
