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
        if opts.version {
            print("appattic \(appAtticVersion)")
            return
        }
        if opts.help {
            print(cliHelpText)
            return
        }
        if let err = opts.error {
            fputs("error: \(err)\n", stderr)
            fputs("\(cliUsageHint)\n", stderr)
            Foundation.exit(2)
        }
        let settings: AppAtticSettings
        do {
            settings = try loadSettings()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(2)
        }
        let includeSystem = effectiveIncludeSystem(cliFlag: opts.includeSystem, settings: settings)
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
            fputs("using cached scan from \(resolved.data.scanned_at) (pass --fresh to scan now)\n", stderr)
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
                fputs("JSON written to \(jsonPath)\n", stderr)
            } catch {
                fputs("error writing JSON: \(error.localizedDescription)\n", stderr)
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
            if !confirmLiveUpdate(count: n) {
                fputs("Update cancelled.\n", stderr)
                return
            }
            fputs("Updating \(n) Homebrew/Flatpak package(s)…\n", stderr)
            let rc = runShellScript(script)
            if rc != 0 {
                fputs("error: update failed (exit \(rc))\n", stderr)
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

enum C {
    static var noColorFlag = false
    static var enabled: Bool {
        cliColorEnabled(
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
            env: ProcessInfo.processInfo.environment,
            noColorFlag: noColorFlag
        )
    }
    static func paint(_ s: String, _ codes: String...) -> String {
        if !enabled || codes.isEmpty { return s }
        return codes.map { "\u{1b}[\($0)m" }.joined() + s + "\u{1b}[0m"
    }
    static func bold(_ s: String) -> String { paint(s, "1") }
    static func dim(_ s: String) -> String { paint(s, "2") }
    static func red(_ s: String) -> String { paint(s, "31") }
    static func green(_ s: String) -> String { paint(s, "32") }
    static func yellow(_ s: String) -> String { paint(s, "33") }
}

func visibleLen(_ s: String) -> Int {
    if !C.enabled { return s.count }
    let re = try! NSRegularExpression(pattern: #"\u{1b}\[[0-9;]*m"#)
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "").count
}

func renderTable(headers: [String], rows: [[String]]) -> String {
    var widths = headers.map(\.count)
    for row in rows {
        for (i, cell) in row.enumerated() where i < widths.count {
            widths[i] = max(widths[i], visibleLen(cell))
        }
    }
    var lines: [String] = []
    lines.append(zip(headers, widths).map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
    for row in rows {
        var cells: [String] = []
        for (i, cell) in row.enumerated() {
            let pad = max(0, (i < widths.count ? widths[i] : 0) - visibleLen(cell))
            cells.append(cell + String(repeating: " ", count: pad))
        }
        lines.append(cells.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
    return lines.joined(separator: "\n")
}

func fmtDt(_ dt: Date?) -> String {
    guard let dt else { return "-" }
    guard let days = calendarDaysSince(dt) else { return "-" }
    if days <= 0 { return "today" }
    if days < 45 { return "\(humanDays(Double(days))) ago" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: dt)
}

func printLeftovers(_ result: ScanResult, limit: Int?, category: [String]) {
    var orphans = result.orphanedItems.sorted { $0.sizeBytes > $1.sizeBytes }
    if !category.isEmpty {
        orphans = orphans.filter { leftoverMatchesCategory($0, categories: category) }
    }
    let system = result.dataItems.filter { $0.status == "system" }
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
        let nameColor: (String) -> String = i.status == "shadow" ? C.yellow : C.red
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
            print(C.dim("  …and \(orphans.count - limit) more (use --top N)"))
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
    let order = ["remove": 0, "review": 1, "keep": 2]
    verdicts.sort {
        let a = order[$0.tier] ?? 3
        let b = order[$1.tier] ?? 3
        if a != b { return a < b }
        return addBytes($0.software.sizeBytes, $0.software.dataBytes)
            > addBytes($1.software.sizeBytes, $1.software.dataBytes)
    }
    let nRemove = verdicts.filter { $0.tier == "remove" }.count
    let nReview = verdicts.filter { $0.tier == "review" }.count
    print()
    print(C.bold("STALE: unused installed software (\(verdicts.count) items)"))
    print(C.dim("  \(C.yellow("\(nReview)")) review · \(C.red("\(nRemove)")) remove candidates"))
    var rows: [[String]] = []
    for v in verdicts {
        let s = v.software
        let (label, style): (String, (String) -> String) = {
            switch v.tier {
            case "keep": return ("KEEP", C.green)
            case "review": return ("REVIEW", C.yellow)
            case "remove": return ("REMOVE", C.red)
            case "system": return ("SYSTEM", C.dim)
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
    let reclaim = verdicts.filter { $0.tier == "remove" }.reduce(0) {
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

func confirmLiveUpdate(count: Int) -> Bool {
    if isatty(STDIN_FILENO) == 0 { return true }
    fputs("Update \(count) Homebrew/Flatpak package(s)? [y/N] ", stderr)
    fflush(stderr)
    guard let line = readLine() else { return false }
    let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer == "y" || answer == "yes"
}

func runShellScript(_ script: String) -> Int32 {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-update-\(UUID().uuidString).sh")
    do {
        try writeOwnerOnlyFile(Data(script.utf8), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        var env = ProcessInfo.processInfo.environment
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        var parts: [String] = []
        for dir in extras + (env["PATH"] ?? "").split(separator: ":").map(String.init) {
            if !dir.isEmpty, seen.insert(dir).inserted { parts.append(dir) }
        }
        env["PATH"] = parts.joined(separator: ":")
        process.environment = env
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}
