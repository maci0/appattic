import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import AppAtticScan

@main
enum AppAtticCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let opts = parseCLIArguments(args)
        C.noColorFlag = opts.noColor
        if opts.help {
            print(cliHelpText)
            return
        }
        if let err = opts.error {
            failUsage(err)
        }
        if opts.version {
            print("appattic \(appAtticVersion)")
            return
        }
        if opts.command == "disk" {
            runDiskCommand(opts)
            return
        }
        let settings: AppAtticSettings
        do {
            settings = try loadSettings()
        } catch {
            fputs("error: \(redactHomePaths(error.localizedDescription))\n", stderr)
            Foundation.exit(2)
        }
        let includeSystem = effectiveIncludeSystem(cliFlag: opts.includeSystem, settings: settings)
        if opts.command == "config" {
            runConfigCommand(opts, settings: settings)
            return
        }
        let now = Date()
        let resolved = resolveScan(
            includeSystem: includeSystem,
            fresh: opts.fresh,
            forceLive: opts.command == "update",
            now: now,
            liveScan: { includeSystem in
                runFullScan(includeSystem: includeSystem, now: now) { msg in
                    fputs(msg + "\n", stderr)
                    fflush(stderr)
                }
            }
        )
        if resolved.fromCache {
            // In the reader's own zone, like every other timestamp the CLI
            // prints: the cache file holds the instant as UTC, so the raw
            // string showed a wall time hours away from the one the rest of
            // the report uses.
            let when = parseISODate(resolved.data.scanned_at)
                .map { TimestampFormat.string(from: $0) } ?? resolved.data.scanned_at
            fputs("using cached scan from \(when) (pass --fresh to scan now)\n", stderr)
        }
        if let cacheFailure = resolved.cacheWriteFailure {
            fputs("warning: scan not cached: \(redactHomePaths(cacheFailure)); the next run rescans\n", stderr)
        }
        if resolved.data.incomplete == true {
            fputs("warning: an update check failed; the outdated list is incomplete and the scan is not cached\n", stderr)
        }
        let ignored = Set(settings.ignoredLeftoverPaths)
        let result = scanResult(from: resolved.data, ignoringLeftovers: ignored, now: now)
        if let jsonPath = opts.json {
            do {
                let payload = exportedScanData(
                    from: resolved.data,
                    ignoringLeftovers: ignored,
                    fromCache: resolved.fromCache,
                    now: now
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let pretty = try encoder.encode(payload)
                try writeOwnerOnlyFile(pretty, to: URL(fileURLWithPath: jsonPath))
                fputs("JSON written to \(redactHomePaths(jsonPath))\n", stderr)
            } catch {
                fputs("error writing JSON: \(redactHomePaths(error.localizedDescription))\n", stderr)
                Foundation.exit(1)
            }
        }
        if opts.dryRun {
            print(
                dryRunScript(
                    command: opts.command,
                    result: result,
                    category: opts.category,
                    top: opts.top,
                    leftoversOnly: opts.leftoversOnly,
                    staleOnly: opts.staleOnly
                ),
                terminator: ""
            )
            return
        }
        if opts.command == "update" {
            let script = updateScript(result.outdated)
            let n = result.outdated.filter(\.updatable).count
            if n == 0 {
                print("Nothing to update. \(outdatedSkippedManagersNote)")
                return
            }
            if !confirmUpdate(count: n, assumeYes: opts.yes) {
                fputs("Update cancelled.\n", stderr)
                Foundation.exit(1)
            }
            fputs("Updating \(n) package(s)…\n", stderr)
            let run = runShellScript(script)
            if run.status != 0 {
                fputs("error: \(commandFailureMessage(status: run.status, stderr: run.stderr))\n", stderr)
                Foundation.exit(1)
            }
            clearScanCache()
            return
        }
        switch opts.command {
        case "leftovers":
            printLeftovers(result, limit: opts.top, category: opts.category)
        case "stale":
            printStale(result, includeSystem: includeSystem)
        case "outdated":
            printOutdated(result)
        case "packages":
            printPackages(result)
        default:
            if !opts.staleOnly {
                printLeftovers(result, limit: opts.top, category: opts.category)
            }
            if !opts.leftoversOnly {
                printStale(result, includeSystem: includeSystem)
            }
            if !opts.staleOnly && !opts.leftoversOnly {
                printOutdated(result)
                printPackages(result)
            }
        }
    }
}

/// Print the configuration this run resolves: the settings file and its
/// values, the flag that overrides them, and the paths the XDG variables
/// resolved to. Nothing is scanned, so it is safe to run anywhere.
func runConfigCommand(_ opts: CLIOptions, settings: AppAtticSettings) {
    let config = EffectiveConfig(settings: settings, includeSystemFlag: opts.includeSystem)
    for line in config.lines {
        print(line)
    }
    if let jsonPath = opts.json {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = try encoder.encode(config)
            try writeOwnerOnlyFile(payload, to: URL(fileURLWithPath: jsonPath))
            fputs("JSON written to \(redactHomePaths(jsonPath))\n", stderr)
        } catch {
            fputs("error writing JSON: \(redactHomePaths(error.localizedDescription))\n", stderr)
            Foundation.exit(1)
        }
    }
}

func runDiskCommand(_ opts: CLIOptions) {
    let root = opts.diskPath ?? FileManager.default.homeDirectoryForCurrentUser.path
    do {
        try validateDiskRoot(root)
    } catch {
        failUsage(redactHomePaths(error.localizedDescription))
    }
    fputs("scanning \(redactHomePaths(root))\n", stderr)
    fflush(stderr)
    let tree = scanDiskUsage(root: root, oneFileSystem: !opts.allFileSystems)
    // `scanDiskUsage` ranks by allocated blocks; the default report prints
    // apparent size, so re-rank by the metric being shown or `--top N` slices
    // the wrong rows.
    tree.sortChildren(allocatedSize: opts.allocated)
    print(formatDiskTree(tree, allocatedSize: opts.allocated, top: opts.top), terminator: "")
    if let top = opts.top {
        let hidden = diskTreeHiddenEntries(tree, top: top)
        if hidden > 0 {
            print(C.dim("  \(hidden) more \(hidden == 1 ? "entry" : "entries") not shown (--top \(top))"))
        }
    }
    if let jsonPath = opts.json {
        do {
            let data = try diskUsageJSON(tree)
            try writeOwnerOnlyFile(data, to: URL(fileURLWithPath: jsonPath))
            fputs("JSON written to \(redactHomePaths(jsonPath))\n", stderr)
        } catch {
            fputs("error writing JSON: \(redactHomePaths(error.localizedDescription))\n", stderr)
            Foundation.exit(1)
        }
    }
}

func failUsage(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    fputs("\(cliUsageHint)\n", stderr)
    Foundation.exit(2)
}

enum C {
    static var noColorFlag = false
    private static let env = ProcessInfo.processInfo.environment
    /// Resolved once: the status colors a run uses cannot change mid-report.
    static let tone = cliTone(env: env)
    static var enabled: Bool {
        cliColorEnabled(
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
            env: env,
            noColorFlag: noColorFlag
        )
    }
    static func paint(_ s: String, _ codes: String...) -> String {
        if !enabled || codes.isEmpty { return s }
        return codes.map { "\u{1b}[\($0)m" }.joined() + s + "\u{1b}[0m"
    }
    static func bold(_ s: String) -> String { paint(s, "1") }
    static func dim(_ s: String) -> String { paint(s, "2") }
    static func red(_ s: String) -> String { paint(s, tone.forRole(.remove)) }
    static func green(_ s: String) -> String { paint(s, tone.forRole(.keep)) }
    static func yellow(_ s: String) -> String { paint(s, tone.forRole(.review)) }
}

func visibleLen(_ s: String) -> Int {
    if !C.enabled { return displayWidth(s) }
    let re = try! NSRegularExpression(pattern: #"\u{1b}\[[0-9;]*m"#)
    return displayWidth(re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: ""))
}

func padCell(_ cell: String, to width: Int) -> String {
    let pad = max(0, width - visibleLen(cell))
    return pad == 0 ? cell : cell + String(repeating: " ", count: pad)
}

func renderTable(headers: [String], rows: [[String]]) -> String {
    var widths = headers.map { visibleLen($0) }
    for row in rows {
        for (i, cell) in row.enumerated() where i < widths.count {
            widths[i] = max(widths[i], visibleLen(cell))
        }
    }
    var lines: [String] = []
    lines.append(zip(headers, widths).map { padCell($0.0, to: $0.1) }.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
    for row in rows {
        var cells: [String] = []
        for (i, cell) in row.enumerated() {
            cells.append(padCell(cell, to: i < widths.count ? widths[i] : 0))
        }
        lines.append(cells.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
    return lines.joined(separator: "\n")
}

func fmtDt(_ dt: Date?) -> String {
    guard let dt else { return "-" }
    return TimestampFormat.string(from: dt)
}

func printLeftovers(_ result: ScanResult, limit: Int?, category: [String]) {
    var orphans = orphanedBySize(result)
    if !category.isEmpty {
        orphans = orphans.filter { leftoverMatchesCategory($0, categories: category) }
    }
    let system = result.dataItems.filter { $0.leftoverStatus == .system }
    let bytes = orphans.reduce(0) { addBytes($0, $1.sizeBytes) }
    print()
    print(C.bold("LEFTOVERS: leftover data and PATH overlays (\(orphans.count) items, \(humanSize(bytes)))"))
    if orphans.isEmpty {
        print(C.green("  Nothing found: no leftover data or overlays."))
    }
    let shown = limit.map { Array(orphans.prefix($0)) } ?? orphans
    var rows: [[String]] = []
    for i in shown {
        let size = i.sizeMeasured ? humanSize(i.sizeBytes) : C.dim("n/a (protected)")
        let nameColor: (String) -> String = i.leftoverStatus == .shadow ? C.yellow : C.red
        rows.append([
            nameColor(leftoverDisplayName(name: i.name, extraPaths: i.extraPaths)),
            C.dim(leftoverWhatText(
                rootLabel: i.rootLabel,
                kind: i.kind,
                name: i.name,
                extraPaths: i.extraPaths,
                storedSummary: i.summary,
                shadows: i.shadows
            )),
            C.dim(leftoverLocationLabel(rootLabel: i.rootLabel, extraCount: i.extraPaths.count)),
            size,
            C.dim(fmtDt(i.mtime)),
            C.dim(leftoverWhyText(
                rootLabel: i.rootLabel,
                kind: i.kind,
                extraPaths: i.extraPaths,
                storedReason: i.reason,
                shadows: i.shadows
            )),
        ])
    }
    if !rows.isEmpty {
        print(renderTable(headers: ["Name", "What", "Location", "Size", "Modified", "Why"], rows: rows))
        if let limit, orphans.count > limit {
            print(C.dim("  …and \(orphans.count - limit) more not shown (--top \(limit))"))
        }
    }
    if !system.isEmpty {
        print()
        print(C.dim("System-owned data (not counted as reclaimable): \(system.count) items"))
    }
    if !orphans.isEmpty {
        print()
        print(C.dim("Total reclaimable from leftovers: \(C.green(humanSize(bytes)))"))
    }
}

func printStale(_ result: ScanResult, includeSystem: Bool) {
    var verdicts = staleVerdicts(result.verdicts, includeSystem: includeSystem)
    let order: [StaleTier: Int] = [.remove: 0, .review: 1, .keep: 2]
    verdicts.sort { lhs, rhs in
        let a = lhs.tierKind.flatMap { tier in order[tier] } ?? 3
        let b = rhs.tierKind.flatMap { tier in order[tier] } ?? 3
        if a != b { return a < b }
        return addBytes(lhs.software.sizeBytes, lhs.software.dataBytes)
            > addBytes(rhs.software.sizeBytes, rhs.software.dataBytes)
    }
    let nRemove = verdicts.filter { $0.tierKind == .remove }.count
    let nReview = verdicts.filter { $0.tierKind == .review }.count
    print()
    print(C.bold("STALE: unused installed software (\(verdicts.count) items)"))
    print(C.dim("  \(C.yellow("\(nReview)")) review · \(C.red("\(nRemove)")) remove candidates"))
    var rows: [[String]] = []
    for v in verdicts {
        let s = v.software
        let (label, style): (String, (String) -> String) = {
            switch v.tierKind {
            case .keep?: return ("KEEP", C.green)
            case .review?: return ("REVIEW", C.yellow)
            case .remove?: return ("REMOVE", C.red)
            case .system?: return ("SYSTEM", C.dim)
            default: return (v.tier.uppercased(), C.dim)
            }
        }()
        let size = staleSizeText(sizeBytes: s.sizeBytes, sizeMeasured: s.sizeMeasured, dataBytes: s.dataBytes)
        let last = s.usageSource == "unknown" ? C.dim("no data") : fmtDt(s.lastUsed)
        rows.append([
            style(label),
            s.name,
            C.dim(softwareDisplaySummary(s)),
            C.dim(s.source.replacingOccurrences(of: "-", with: " ")),
            last,
            size,
            C.dim(displayStaleReason(v.reason)),
        ])
    }
    print(renderTable(headers: ["Verdict", "Name", "What", "Source", "Last used", "Size", "Why"], rows: rows))
    let reclaim = verdicts.filter { $0.tierKind == .remove }.reduce(0) {
        addBytes($0, addBytes($1.software.sizeBytes, $1.software.dataBytes))
    }
    if reclaim > 0 {
        print()
        print(C.dim("Reclaimable by acting on REMOVE candidates: \(C.green(humanSize(reclaim)))"))
    }
    print()
    print(C.dim("  Tiers: KEEP = in use · REVIEW = idle, check before deleting · REMOVE = stale & easy to reinstall"))
    if !result.outdated.isEmpty {
        print(C.dim("  \(result.outdated.count) package(s) have a newer version. See: appattic outdated"))
    }
}

func printOutdated(_ result: ScanResult) {
    let pkgs = result.outdated
    print()
    print(C.bold("OUTDATED: newer version available (\(pkgs.count) packages)"))
    if pkgs.isEmpty {
        print(C.green("  Nothing found. Installed packages look up to date, or no package manager responded."))
        return
    }
    var rows: [[String]] = []
    for p in pkgs {
        let latest: String
        if p.kind == "untrusted" {
            latest = "untrusted"
        } else {
            latest = p.latestVersion ?? "?"
        }
        rows.append([
            p.title ?? p.name,
            C.dim(outdatedSummaryFallback(p)),
            C.dim(p.manager.replacingOccurrences(of: "-", with: " ")),
            C.dim(p.currentVersion ?? "-"),
            C.yellow(latest),
        ])
    }
    print(renderTable(headers: ["Name", "What", "Manager", "Current", "Latest"], rows: rows))
    print()
    for line in outdatedReportFooter(pkgs) {
        print(C.dim("  \(line)"))
    }
}

func printPackages(_ result: ScanResult) {
    let pkgs = filterPackages(result.packages, filter: .all)
    print()
    print(C.bold("PACKAGES: distro orphans and language globals (\(pkgs.count))"))
    if pkgs.isEmpty {
        print(C.green("  Nothing found. Distro tools reported no orphans, or language globals are absent."))
        return
    }
    var rows: [[String]] = []
    for p in pkgs {
        let kind = p.kind == "global" ? "Global" : "Orphan"
        let kindPaint: (String) -> String = p.kind == "global" ? C.yellow : C.red
        let size = p.size_measured ? humanSize(p.size_bytes ?? 0) : C.dim("unknown")
        rows.append([
            p.name,
            C.dim(p.summary ?? packageWhatText(manager: p.manager, kind: p.kind)),
            C.dim(p.manager.replacingOccurrences(of: "-", with: " ")),
            kindPaint(kind),
            size,
        ])
    }
    print(renderTable(headers: ["Name", "What", "Manager", "Kind", "Size"], rows: rows))
    print()
    print(C.dim("  Remove and mark-manual are confirm + script only. Distro upgrades are never included."))
}

func confirmUpdate(count: Int, assumeYes: Bool) -> Bool {
    if assumeYes { return true }
    if isatty(STDIN_FILENO) == 0 {
        fputs("error: update needs confirmation and stdin is not a terminal\n", stderr)
        fputs("       pass --yes to run it unattended, or --dry-run to print the script\n", stderr)
        Foundation.exit(2)
    }
    fputs("Update \(count) package(s)? [y/N] ", stderr)
    fflush(stderr)
    guard let line = readLine() else { return false }
    let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer == "y" || answer == "yes"
}

/// Runs a generated script under `/bin/sh`. Returns the exit status and
/// whatever the script wrote to stderr, which is the only thing that says
/// which of `set -e`'s lines failed.
func runShellScript(_ script: String) -> (status: Int32, stderr: String) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("appattic-update-\(UUID().uuidString).sh")
    let errURL = dir.appendingPathComponent("appattic-update-\(UUID().uuidString).err")
    do {
        try writeOwnerOnlyFile(Data(script.utf8), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOwnerOnlyFile(Data(), to: errURL)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        process.environment = augmentedProcessEnvironment()
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? errHandle.synchronize()
        let status = process.terminationStatus
        let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (status, errText)
    } catch {
        fputs("error: \(redactHomePaths(error.localizedDescription))\n", stderr)
        return (1, "")
    }
}
