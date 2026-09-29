import Foundation

public struct CleanupSelection: Equatable, Sendable {
    public var leftovers: Set<String>
    public var apps: Set<String>
    public var outdated: Set<String>
    public var packages: Set<String>
    public var markManual: Set<String>

    public init(
        leftovers: Set<String> = [],
        apps: Set<String> = [],
        outdated: Set<String> = [],
        packages: Set<String> = [],
        markManual: Set<String> = []
    ) {
        self.leftovers = leftovers
        self.apps = apps
        self.outdated = outdated
        self.packages = packages
        self.markManual = markManual
    }
}

/// The REVIEW + REMOVE tiers a UI can opt into cleanup, in string form. The
/// live check is `StaleTier.isSelectable(_:)`; this is the same set for a
/// caller that holds raw `tier` strings. CLI `--dry-run` for report/stale
/// emits only REMOVE.
let selectableCleanupTiers: Set<String> = Set(StaleTier.selectable.map(\.rawValue))

public func pruneCleanupSelection(
    leftovers: Set<String>,
    apps: Set<String>,
    outdated: Set<String>,
    packages: Set<String> = [],
    markManual: Set<String> = [],
    data: ScanData,
    ignoring: Set<String>
) -> CleanupSelection {
    let leftoverPaths = Set(visibleOrphanedLeftovers(data.leftovers, ignoring: ignoring).map(\.path))
    let appPaths = Set(
        data.software.filter { StaleTier.isSelectable($0.tierKind) }.map(\.path)
    )
    let outdatedIds = Set((data.outdated ?? []).filter(\.updatable).map(\.id))
    let listed = data.packages ?? []
    let packageIds = Set(listed.map(\.id))
    let markIds = Set(listed.filter(\.canMarkManual).map(\.id))
    return CleanupSelection(
        leftovers: leftovers.intersection(leftoverPaths),
        apps: apps.intersection(appPaths),
        outdated: outdated.intersection(outdatedIds),
        packages: packages.intersection(packageIds),
        markManual: markManual.intersection(markIds)
    )
}

public func resolvedSelection(_ selected: String?, visibleIds: [String]) -> String? {
    if let selected, visibleIds.contains(selected) { return selected }
    return visibleIds.first
}

public func toggleListedSelection(selected: Set<String>, visible: [String]) -> Set<String> {
    let vis = Set(visible)
    if vis.isEmpty { return selected }
    if vis.isSubset(of: selected) { return [] }
    return selected.union(vis)
}

public func isSteamManagedPath(_ path: String) -> Bool {
    let p = path.posixLowercased()
    return p.contains("/steamapps/") || p.contains("/steam.appbundle/")
}

/// The handoff to the Steam client, which is what removes the game.
///
/// `|| true` because the status is about the handoff, not the removal: on a
/// machine with no client `steam` is not on PATH and `open` has no handler,
/// and under `set -e` that stops the script and strands every removal below
/// it. Nothing here can ask whether the game is still installed, so a rerun
/// asks again; the row stays selected after a run (`isHandoffUninstallCommand`)
/// because the client, not this script, is what finishes the uninstall.
public func steamUninstallCommand(appId: String) -> String {
    let uri = "steam://uninstall/\(appId)"
    if PlatformOverride.isLinux {
        return "steam \(shellQuote(uri)) || true"
    }
    return "open \(shellQuote(uri)) || true"
}

public func uninstallCommand(
    source: String,
    name: String,
    path: String,
    caskName: String?,
    steamAppId: String?,
    pkgId: String? = nil
) -> String {
    // A name, cask name, or package id reaches a package manager as an
    // argument. A leading `-` is read as an option, so the removal is
    // refused rather than run.
    if !isSafeCommandArgument(name) {
        return "# skipped \(shellComment(name)): name reads as a command option"
    }
    if let caskName, !isSafeCommandArgument(caskName) {
        return "# skipped \(shellComment(caskName)): cask name reads as a command option"
    }
    if let pkgId, !isSafeCommandArgument(pkgId) {
        return "# skipped \(shellComment(pkgId)): package id reads as a command option"
    }
    if source == "brew-formula" {
        let q = shellQuote(name)
        return guardedRemoveCommand(present: "brew list --formula \(q)", remove: "brew uninstall \(q)")
    }
    if source == "brew-cask" {
        let q = shellQuote(caskName ?? name)
        return guardedRemoveCommand(present: "brew list --cask \(q)", remove: "brew uninstall --cask \(q)")
    }
    if source == "flatpak" {
        let q = shellQuote(linuxUninstallId(source: source, path: path, pkgId: pkgId))
        return guardedRemoveCommand(present: "flatpak info \(q)", remove: "flatpak uninstall -y \(q)")
    }
    if source == "snap" {
        let q = shellQuote(linuxUninstallId(source: source, path: path, pkgId: pkgId))
        return guardedRemoveCommand(present: "snap list \(q)", remove: "snap remove \(q)")
    }
    if source == "appimage" {
        if isProtectedPackagedPath(path) {
            return "# skipped packaged path \(shellComment(path))"
        }
        return "rm -rf \(shellQuote(path))"
    }
    if source == "steam", let id = steamAppId, !id.isEmpty, !isCrossOverPath(path) {
        return steamUninstallCommand(appId: id)
    }
    if source == "crossover" {
        return crossoverDeleteCommand(bottleName: name, bottlePath: path)
    }
    if isCrossOverPath(path) {
        return "# \(shellComment(name)): uninstall from CrossOver. Do not delete \(shellComment(path))"
    }
    if source == "steam" || isSteamManagedPath(path) {
        return "# \(shellComment(name)): uninstall from Steam. Do not delete \(shellComment(path))"
    }
    if isProtectedPackagedPath(path) {
        return "# skipped packaged path \(shellComment(path))"
    }
    return "rm -rf \(shellQuote(path))"
}

public func commandFailureMessage(
    status: Int32,
    stderr: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path
) -> String {
    let trimmed = redactHomePaths(
        stderr.trimmingCharacters(in: .whitespacesAndNewlines),
        home: home
    )
    if trimmed.isEmpty {
        return "Command failed (exit \(status))."
    }
    // The last characters, not the first: a failing command prints the reason
    // where it stops, and a long run's stderr is capped at its tail
    // (`readCommandOutputTail`), so the head of what arrived is not the error.
    let detail = trimmed.count > 400 ? String(trimmed.suffix(400)) : trimmed
    return "Command failed (exit \(status)). \(detail)"
}

public func scriptHasActionableCommands(_ script: String) -> Bool {
    for raw in script.split(whereSeparator: \.isNewline) {
        let line = String(raw).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") { continue }
        if line == "set -e" || line.hasPrefix("set -") { continue }
        return true
    }
    return false
}

/// True when a script body calls `rootcmd`, in either the bare or the guarded
/// spelling `if q; then rootcmd action; fi`. The body is previewed, untrusted
/// text, so a line can be indented; `callsRootHelper` sees a wrapped line.
private func bodyNeedsRootHelper(_ script: String) -> Bool {
    script.split(whereSeparator: \.isNewline).contains {
        callsRootHelper($0.trimmingCharacters(in: .whitespaces))
    }
}

/// Add the `rootcmd` helper to a script that is about to receive a body which
/// calls it and does not define it. A `rootcmd` call with no helper is
/// `sh: rootcmd: not found`, and under `set -e` that stops the script there.
public func ensureRootHelper(_ script: String) -> String {
    if !bodyNeedsRootHelper(script) || script.contains("rootcmd() {") { return script }
    var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var at = 0
    while at < lines.count {
        let t = lines[at].trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("set -") { at += 1; continue }
        break
    }
    var helper = scriptRootHelper.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .map(String.init)
    while helper.last?.isEmpty == true { helper.removeLast() }
    lines.insert(contentsOf: helper + [""], at: at)
    return lines.joined(separator: "\n")
}

/// Drop trailing whitespace-only lines. The blank tail both strippers leave
/// behind would otherwise pad the merged script with a run of empty lines.
func trimTrailingBlankLines(_ lines: inout [String]) {
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeLast()
    }
}

public func stripShellHeader(_ script: String) -> String {
    var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let first = lines.first {
        let line = first.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#!") || line.hasPrefix("#") || line == "set -e" || line.hasPrefix("set -") {
            lines.removeFirst()
            continue
        }
        // The `rootcmd` helper belongs to the script being merged into, not to
        // the body appended to it. Two copies redefine the same function and
        // read like two different escalation paths.
        if line == "rootcmd() {" {
            while let inner = lines.first {
                lines.removeFirst()
                if inner.trimmingCharacters(in: .whitespaces) == "}" { break }
            }
            continue
        }
        break
    }
    trimTrailingBlankLines(&lines)
    return lines.joined(separator: "\n")
}

func isShellPreamble(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return true }
    if t.hasPrefix("#!") { return true }
    if t == "set -e" || t.hasPrefix("set -") { return true }
    if t.hasPrefix("# AppAttic") { return true }
    if t.hasPrefix("# Review every path") { return true }
    if t.hasPrefix("# Update section") { return true }
    return false
}

func stripShellPreambleOnly(_ script: String) -> String {
    var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let first = lines.first, isShellPreamble(first) {
        lines.removeFirst()
    }
    trimTrailingBlankLines(&lines)
    return lines.joined(separator: "\n")
}

public func previewScript(cleanup: String, update: String) -> String {
    let hasClean = scriptHasActionableCommands(cleanup)
    let hasUpdate = scriptHasActionableCommands(update)
    let cleanupNotes = stripShellPreambleOnly(cleanup).trimmingCharacters(in: .whitespacesAndNewlines)
    let hasCleanupContent = hasClean || !cleanupNotes.isEmpty
    func terminated(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
    if hasCleanupContent && hasUpdate {
        var body = cleanup
        while body.hasSuffix("\n") { body.removeLast() }
        let extra = stripShellHeader(update)
        if extra.isEmpty { return terminated(cleanup) }
        // `stripShellHeader` drops the update script's own `rootcmd` helper. The
        // merged script keeps one, and it has to be there when the update half
        // is what escalates and the cleanup half does not.
        let section = "# Update section. Delete in the UI does not run these lines.\n" + extra + "\n"
        body = ensureRootHelper(body + "\n\n" + section)
        return body
    }
    if hasUpdate { return terminated(update) }
    return terminated(cleanup)
}

func commentedOutdatedLines(_ pkgs: [OutdatedPkg]) -> [String] {
    pkgs.map { pkg in
        // `shellComment`, not `shellQuote`: these lines are comments, and a
        // quoted newline is still a newline, so a name carrying one ended the
        // comment and made the rest of the name a command the script runs.
        let quoted = shellComment(pkg.name)
        switch pkg.manager {
        case "brew-formula":
            return "# brew upgrade \(quoted)"
        case "brew-cask":
            return "# brew upgrade --cask \(quoted)"
        case "flatpak":
            return "# flatpak update \(quoted)"
        case "snap":
            return "# snap refresh \(quoted)"
        case "apt":
            // `apt-get`, the binary `updateCommand` runs: the report and the
            // live script are the same upgrade, so they must not name two
            // different tools.
            return "# apt-get install --only-upgrade \(quoted)"
        case "pacman":
            return "# pacman -S \(quoted)"
        case "aur":
            return "# \(aurHelperBin()) -S \(quoted)"
        case "dnf":
            return "# dnf upgrade \(quoted)"
        case "yum":
            return "# yum upgrade \(quoted)"
        case "zypper":
            return "# zypper update \(quoted)"
        case "app-store":
            return "# App Store: \(quoted)"
        default:
            return "# \(shellComment(pkg.manager)) \(quoted)"
        }
    }
}

public func outdatedReportScript(_ pkgs: [OutdatedPkg], scannedAt: Date) -> String {
    var lines = [
        "#!/bin/sh",
        "set -e",
        "# AppAttic outdated report generated \(scriptStamp(scannedAt))",
        "# Report only. These upgrades are not run. Use update --dry-run to review a live script.",
    ]
    if pkgs.isEmpty {
        lines.append("")
        lines.append("# No outdated packages.")
    } else {
        lines.append("")
        lines.append(contentsOf: commentedOutdatedLines(pkgs))
    }
    return lines.joined(separator: "\n") + "\n"
}

func linuxUninstallId(source: String, path: String, pkgId: String?) -> String {
    if let pkgId, !pkgId.isEmpty { return pkgId }
    let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return linuxPkgId(source: source, desktopId: base, exec: "")
}

/// A `..` path component. A name a scan read off the filesystem cannot be one,
/// so a path carrying it was spelled by something else.
func hasParentSegment(_ path: String) -> Bool {
    path.split(separator: "/").contains("..")
}

/// The path with empty and `.` components dropped, for a prefix test. The
/// removal quotes the path as written, so `rm` resolves `//usr` and `/usr/.`
/// to the packaged root a raw prefix test would miss. Matches Qt
/// `normalizedForPrefixTest`.
func normalizedForPrefixTest(_ path: String) -> String {
    "/" + path.split(separator: "/", omittingEmptySubsequences: true)
        .filter { $0 != "." }
        .joined(separator: "/")
}

/// Packaged OS prefixes that leftover/uninstall scripts must not `rm`.
/// The root list is identical to Qt `isProtectedPackagedPath` in `ui/linux-qt/finding.cpp`.
public func isProtectedPackagedPath(_ path: String) -> Bool {
    if path.isEmpty { return false }
    // The removal quotes the path as written, so a `..` segment walks out of
    // whatever the prefix test just approved: `/home/u/gone/../../../etc` is
    // not under a packaged root by spelling and deletes `/etc` once `rm`
    // resolves it.
    if hasParentSegment(path) { return true }
    let normalized = normalizedForPrefixTest(path)
    let roots = [
        "/usr", "/bin", "/sbin", "/etc", "/System", "/lib", "/lib64",
        "/boot", "/dev", "/proc", "/sys", "/private", "/Library",
    ]
    return roots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
}

/// A path a generated `rm` may name. Every leftover root the scan walks is
/// absolute, and a scan reads the path off the filesystem, so a relative
/// spelling or a leading `-` did not come from a walk. `shellQuote` leaves
/// either one unquoted, so `rm` would resolve it against the script's working
/// directory, or read `--no-preserve-root` as the option it is.
func isRemovableLeftoverPath(_ path: String) -> Bool {
    !path.isEmpty && path.hasPrefix("/") && !path.hasPrefix("-")
}

/// A deb822/sources.list entry is removable even though it lives under `/etc`.
/// A `..` segment would let the path walk back out of that directory, so the
/// spelling has to be clean before the prefix is trusted. Matches Qt
/// `isPpaSourcesPath`.
public func isPpaSourcesPath(_ path: String) -> Bool {
    // Tested on the spelling as written, not on `standardizingPath`: that
    // resolves `..`, so the check below could never see one and
    // `/etc/apt/sources.list.d/../sources.list.d/x` was re-permitted past the
    // packaged-root deny.
    guard !hasParentSegment(path) else { return false }
    return (path as NSString).standardizingPath.hasPrefix("/etc/apt/sources.list.d/")
}

/// Manager list, same as Qt `commandNeedsRoot`: the AUR helpers and snap are in
/// it because they install and remove with root, exactly like the distro
/// managers they sit next to. A list that is short here is a script that asks
/// for no password and then fails.
private let rootCommandBases: Set<String> = [
    "apt", "apt-get", "apt-mark", "pacman", "paru", "yay", "pikaur",
    "dnf", "dnf5", "yum", "zypper", "snap",
]

public func commandNeedsRoot(_ cmd: String) -> Bool {
    var t = cmd.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("rootcmd ") { return false }
    // A `#` line is a comment. It mentions a path the way a command does, and
    // it runs nothing, so it never escalates.
    if t.hasPrefix("#") { return false }
    // A guarded remove is `if <query>; then <action>; fi`. Judge the action, or
    // the wrapper's leading `if` hides an action that needs root.
    if let guarded = parseGuardedRemove(t) { t = guarded.action }
    let first = t.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    let base = first.split(separator: "/").last.map(String.init) ?? first
    if rootCommandBases.contains(base) { return true }
    // A PPA sources file is the one leftover under a packaged root that is
    // removable. `shellQuote` wraps it in single quotes, so match the quoted
    // spelling as well as the bare one.
    return t.contains(" /etc/apt/sources.list.d/")
        || t.contains(" '/etc/apt/sources.list.d/")
        || t.contains(" \"/etc/apt/sources.list.d/")
}

/// Escalate one generated line.
///
/// A guarded removal keeps the guard outside the wrapper. `rootcmd if q; then
/// rm; fi` is a `/bin/sh` syntax error (`then` outside an `if`), and a syntax
/// error takes the whole script down before its first line runs, so the user
/// reviews a script that cannot do anything. The presence check is a read and
/// stays unprivileged; only the action escalates.
public func withRootCmd(_ cmd: String) -> String {
    // A multi-line command is a list, not one line: `rootcmd` would take the
    // first line's words and leave the rest of them as bare commands, which
    // run unprivileged or fail to parse. Escalate each line on its own.
    if cmd.contains("\n") {
        return cmd.split(separator: "\n", omittingEmptySubsequences: false)
            .map { withRootCmd(String($0)) }
            .joined(separator: "\n")
    }
    guard commandNeedsRoot(cmd) else { return cmd }
    // Escalating the whole line hands `rootcmd` the words `if` and `<query>` as
    // arguments and leaves a bare `then` behind, so the line stops parsing and
    // `set -e` ends the script there. Escalate the action inside the guard, and
    // rebuild it through the writer so the query keeps the redirect the parse
    // took off it and the escalated line is the original one.
    if let guarded = parseGuardedRemove(cmd) {
        return guardedCommand(present: guarded.present, action: "rootcmd \(guarded.action)")
    }
    return "rootcmd \(cmd)"
}

/// Absolute paths, not a PATH lookup: the child process runs with the
/// account's own `~/.local/bin` and `~/bin` ahead of the system directories,
/// and both are writable by whatever runs as the account. A `pkexec` or `sudo`
/// planted there would run at the prompt this helper opens.
public let scriptRootHelper = """
rootcmd() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    for helper in /usr/bin/pkexec /bin/pkexec /usr/bin/sudo /bin/sudo; do
      if [ -x "$helper" ]; then
        "$helper" "$@"
        return
      fi
    done
    echo "rootcmd: neither pkexec nor sudo is installed" >&2
    return 127
  fi
}
"""

public func leftoverRemoveCommand(path: String, rootLabel: String, extraPaths: [String] = []) -> String {
    if rootLabel == "LaunchAgents" {
        if isProtectedPackagedPath(path) || !isRemovableLeftoverPath(path) {
            return "# skipped packaged path \(shellComment(path))"
        }
        let q = shellQuote(path)
        return "launchctl bootout gui/$(id -u) \(q) 2>/dev/null || true\nrm -rf \(q)"
    }
    var seen = Set<String>()
    let paths = ([path] + extraPaths).filter {
        seen.insert($0).inserted && isRemovableLeftoverPath($0)
            && (!isProtectedPackagedPath($0) || isPpaSourcesPath($0))
    }
    if paths.isEmpty {
        return "# skipped packaged path \(shellComment(path))"
    }
    return "rm -rf " + paths.map(shellQuote).joined(separator: " ")
}

public func leftoverRemoveCommand(for item: LeftoverItem) -> String {
    leftoverRemoveCommand(path: item.path, rootLabel: item.root, extraPaths: item.extra_paths ?? [])
}

public func uninstallCommand(for item: SoftwareItem) -> String {
    uninstallCommand(
        source: item.source,
        name: item.name,
        path: item.path,
        caskName: item.cask_name,
        steamAppId: item.steam_appid,
        pkgId: item.pkg_id
    )
}

/// Local wall time plus the zone's offset. The stamp is the only record of
/// when a scan ran, and a generated script outlives the machine it was made
/// on: without the offset, a script written in `Europe/Warsaw` reads as the
/// same minute of the day as one written in `America/New_York` on a machine an
/// hour or nine off.
private let scriptStampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd HH:mm Z"
    return f
}()

func scriptStamp(_ date: Date) -> String {
    // Set per call, not at init: a process that outlives a zone change (a
    // laptop crossing a border) stamps with the zone it started in.
    scriptStampFormatter.timeZone = .current
    return scriptStampFormatter.string(from: date)
}

/// Largest first, collated path breaking size ties.
///
/// Size alone is not a total order, and this order decides which entries
/// survive `--top N` and where they land in the generated script, so an
/// untied order would print a different report for the same scan on the next
/// process. The tie-break collates rather than comparing bytes, so an equal-size
/// pair reads in the reader's order: byte order puts "Über" after "Zurich" and
/// every CJK folder after all Latin ones. A collated tie falls back to the byte
/// order, which keeps the two names distinct.
public func orphanedBySize(_ result: ScanResult) -> [DataItem] {
    result.orphanedItems.sorted { a, b in
        a.sizeBytes == b.sizeBytes
            ? collatedBefore(a.path, b.path, tieBreak: a.path, b.path)
            : a.sizeBytes > b.sizeBytes
    }
}

func leftoverDryRunItems(_ result: ScanResult, category: [String], top: Int?) -> [DataItem] {
    var orphans = orphanedBySize(result)
    if !category.isEmpty {
        orphans = orphans.filter { leftoverMatchesCategory($0, categories: category) }
    }
    if let top {
        orphans = Array(orphans.prefix(max(0, top)))
    }
    return orphans
}

func appendLeftoverCommands(_ lines: inout [String], items: [DataItem]) {
    guard !items.isEmpty else { return }
    lines.append("")
    lines.append("# Leftover data and PATH overlays")
    for i in items {
        lines.append(withRootCmd(leftoverRemoveCommand(path: i.path, rootLabel: i.rootLabel, extraPaths: i.extraPaths)))
    }
}

func appendRemoveVerdicts(_ lines: inout [String], result: ScanResult) {
    for v in result.verdicts where v.tierKind == .remove {
        let s = v.software
        lines.append("")
        lines.append("# \(shellComment(s.name)) (\(shellComment(s.source))) not used for a long time")
        lines.append(withRootCmd(uninstallCommand(
            source: s.source,
            name: s.name,
            path: s.path,
            caskName: s.caskName,
            steamAppId: s.extra["steam_appid"],
            pkgId: s.pkgId
        )))
        if s.dataBytes > 0 {
            lines.append("# (its user data, if any, is listed in the report)")
        }
    }
}

/// Preamble the leftover, stale, and combined cleanup scripts open with: the
/// same shell, the same safety line, and a stamped title naming what the
/// script does. The update, packages, and outdated-report scripts carry their
/// own headers.
/// `scriptHasActionableCommands` reads a generated script back and skips
/// comments and `set -` lines, so the first two lines are the shell and
/// `set -e` and everything after them is comments.
func scriptHeader(_ kind: String, scannedAt: Date) -> [String] {
    [
        "#!/bin/sh",
        "set -e",
        "# AppAttic \(kind) script generated \(scriptStamp(scannedAt))",
        "# Review every path before running. Nothing here is deleted automatically.",
    ]
}

/// Header plus body, with the `rootcmd` helper when a body line escalates.
/// A `rootcmd` call with no helper defined is `sh: rootcmd: not found`, and
/// under `set -e` that stops the script, so the helper is part of emitting the
/// wrapper rather than an extra the caller remembers.
public func scriptWithHeader(_ header: [String], _ body: [String]) -> String {
    var lines = header
    if bodyNeedsRootHelper(body.joined(separator: "\n")) {
        lines.append(scriptRootHelper)
    }
    lines.append(contentsOf: body)
    return lines.joined(separator: "\n") + "\n"
}

func leftoverCleanupScript(_ items: [DataItem], scannedAt: Date) -> String {
    let header = scriptHeader("leftover cleanup", scannedAt: scannedAt)
    var body: [String] = []
    if items.isEmpty {
        body.append("")
        body.append("# No leftover data matched.")
    } else {
        appendLeftoverCommands(&body, items: items)
    }
    return scriptWithHeader(header, body)
}

func staleCleanupScript(_ result: ScanResult) -> String {
    let header = scriptHeader("stale uninstall", scannedAt: result.scannedAt)
    var body: [String] = []
    appendRemoveVerdicts(&body, result: result)
    if body.isEmpty {
        body.append("")
        body.append("# No remove-tier unused software.")
    }
    return scriptWithHeader(header, body)
}

/// Printable `/bin/sh` for this CLI command. `outdated` comments every upgrade;
/// `update` is named live upgrades after confirm. `packages` emits removals
/// (the mark-manual set is always empty here; the UI builds that half).
/// `report` emits leftovers and REMOVE-tier uninstalls; `leftovers` and `stale`
/// emit their own half only, and `--leftovers-only` / `--stale-only` on
/// `report` narrow it the same way.
public func dryRunScript(
    command: String,
    result: ScanResult,
    category: [String] = [],
    top: Int? = nil,
    leftoversOnly: Bool = false,
    staleOnly: Bool = false
) -> String {
    switch command {
    case "leftovers":
        return leftoverCleanupScript(
            leftoverDryRunItems(result, category: category, top: top),
            scannedAt: result.scannedAt
        )
    case "stale":
        return staleCleanupScript(result)
    case "outdated":
        return outdatedReportScript(result.outdated, scannedAt: result.scannedAt)
    case "packages":
        return packageActionScript(remove: result.packages, markManual: [])
    case "update":
        return updateScript(result.outdated)
    default:
        if leftoversOnly && !staleOnly {
            return leftoverCleanupScript(
                leftoverDryRunItems(result, category: category, top: top),
                scannedAt: result.scannedAt
            )
        }
        if staleOnly && !leftoversOnly {
            return staleCleanupScript(result)
        }
        return cleanupScript(result, category: category, top: top)
    }
}

public func cleanupScript(_ result: ScanResult, category: [String] = [], top: Int? = nil) -> String {
    let header = scriptHeader("cleanup", scannedAt: result.scannedAt)
    var body: [String] = []
    appendLeftoverCommands(&body, items: leftoverDryRunItems(result, category: category, top: top))
    appendRemoveVerdicts(&body, result: result)
    if !result.outdated.isEmpty {
        body.append("")
        body.append("# Outdated packages (report only; not run)")
        body.append(contentsOf: commentedOutdatedLines(result.outdated))
    }
    return scriptWithHeader(header, body)
}

/// The live-object view of a `ScanData`: `dataItems`, `software`, `verdicts`,
/// `outdated`, and `packages` rebuilt, with ignored leftover paths (the item
/// path and its `extra_paths`) dropped. `now` is the scan time to fall back on
/// when the payload carries no `scanned_at`, so a caller that must not read the
/// clock passes the time it already has.
public func scanResult(from data: ScanData, ignoringLeftovers: Set<String> = [], now: Date = Date()) -> ScanResult {
    let result = ScanResult()
    result.scannedAt = parseISODate(data.scanned_at) ?? now
    // Clamped like the freshly measured value is, so a `duration_s` written by
    // hand or carried over from another machine cannot make a caller report a
    // negative or infinite scan. `reportDuration()` guards the encode side.
    result.durationS = data.duration_s.isFinite && data.duration_s > 0 ? data.duration_s : 0
    result.brewAvailable = data.brew_available
    result.incomplete = data.incomplete == true
    result.appsInstalled = data.totals.apps_installed
    let ignoredKeys = Set(ignoringLeftovers.map(pathIdentityKey))
    let filterIgnored = !ignoredKeys.isEmpty
    result.dataItems = data.leftovers.compactMap { item in
        if filterIgnored, leftoverIgnorePaths(item).contains(where: { ignoredKeys.contains(pathIdentityKey($0)) }) { return nil }
        return DataItem(
            path: item.path,
            name: item.name,
            rootLabel: item.root,
            kind: item.kind,
            status: item.status,
            owner: item.owner,
            shadows: item.shadows,
            sizeBytes: item.size_bytes ?? 0,
            sizeMeasured: item.size_measured,
            mtime: parseISODate(item.mtime),
            reason: item.reason,
            summary: item.summary,
            extraPaths: item.extra_paths ?? []
        )
    }
    result.software = data.software.map { item in
        var extra: [String: String] = [:]
        if let id = item.steam_appid, !id.isEmpty {
            extra["steam_appid"] = id
        } else if item.source == "steam", item.name.compare("Steam", options: .caseInsensitive) == .orderedSame {
            extra["steam_client"] = "1"
        }
        if item.source == "crossover" {
            extra["crossover_bottle"] = "1"
        }
        return Software(
            name: item.name,
            kind: item.kind,
            path: item.path,
            source: item.source,
            sizeBytes: item.size_bytes ?? 0,
            sizeMeasured: item.size_measured ?? true,
            lastUsed: parseISODate(item.last_used),
            usageSource: item.usage_source,
            installedAt: parseISODate(item.installed_at),
            dataBytes: item.data_bytes ?? 0,
            dataMeasured: item.data_measured ?? true,
            dataPaths: item.data_paths ?? [],
            runningService: item.running_service ?? false,
            version: item.version ?? item.current_version,
            caskName: item.cask_name,
            isLeaf: item.is_leaf ?? true,
            outdated: item.outdated ?? false,
            latestVersion: item.latest_version,
            pkgId: item.pkg_id,
            bundleId: item.bundle_id,
            summary: item.summary,
            extra: extra
        )
    }
    result.verdicts = zip(result.software, data.software).map { sw, item in
        Verdict(software: sw, tier: item.tier ?? "", reason: item.reason ?? "")
    }
    result.outdated = (data.outdated ?? []).map {
        OutdatedPkg(
            name: $0.name,
            manager: $0.manager,
            currentVersion: $0.current_version,
            latestVersion: $0.latest_version,
            title: $0.title,
            summary: $0.summary,
            reason: $0.reason,
            bundleId: $0.bundle_id,
            kind: $0.kind
        )
    }
    result.packages = data.packages ?? []
    return result
}

public func isHandoffUninstallCommand(_ command: String) -> Bool {
    command.contains("steam://uninstall")
}

public func remainingPendingAppPaths(selected: Set<String>, software: [SoftwareItem]) -> Set<String> {
    Set(software.compactMap { item in
        guard selected.contains(item.path) else { return nil }
        let cmd = uninstallCommand(for: item)
        if isHandoffUninstallCommand(cmd) { return item.path }
        if scriptHasActionableCommands("#!/bin/sh\nset -e\n\(cmd)\n") { return nil }
        return item.path
    })
}

public func cleanupScript(from data: ScanData, ignoringLeftovers: Set<String> = [], now: Date = Date()) -> String {
    cleanupScript(scanResult(from: data, ignoringLeftovers: ignoringLeftovers, now: now))
}

/// The `ScanData` a report writes out: the round trip back to the wire form
/// with totals recomputed from the rows that survived `ignoringLeftovers`, and
/// `from_cache` stamped with where the scan came from. A check the input
/// reported as not run stays not run, so an export never turns "unknown" into
/// "nothing to report".
public func exportedScanData(
    from data: ScanData,
    ignoringLeftovers: Set<String> = [],
    fromCache: Bool = false,
    now: Date = Date()
) -> ScanData {
    var payload = scanResult(from: data, ignoringLeftovers: ignoringLeftovers, now: now).toScanData()
    // `ScanResult` holds a list either way, so a round trip would report a
    // check that never ran as one that found nothing. Put the nil back: an
    // export says "not checked", not "nothing to report".
    if data.outdated == nil {
        payload.outdated = nil
        payload.totals.outdated_apps = nil
    }
    if data.packages == nil { payload.packages = nil }
    payload.from_cache = fromCache
    return payload
}
