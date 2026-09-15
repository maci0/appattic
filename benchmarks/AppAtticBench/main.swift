import Foundation
import AppAtticScan

// Repeatable micro-benchmarks for AppAtticScan hotpaths.
// Build: swift build -c release --product appattic-bench
// Run:   .build/release/appattic-bench [--json]
// One line per benchmark: "<name> <iters> <ns/op> <checksum>".

var sink = 0

setvbuf(stdout, nil, _IONBF, 0)

// Optional argv filter: `appattic-bench isodate` runs only matching benchmarks.
let benchFilter: String? = CommandLine.arguments.dropFirst().first

@inline(never)
func bench(_ name: String, iters: Int, _ body: () -> Int) {
    if let f = benchFilter, !name.contains(f) { return }
    // Warm up so first-touch allocations do not land in the measurement.
    sink ^= body()
    let clock = ContinuousClock()
    let start = clock.now
    var local = 0
    for _ in 0..<iters { local &+= body() }
    sink ^= local
    let elapsed = clock.now - start
    let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
    let perOp = ns / Double(iters)
    let padded = name.padding(toLength: 28, withPad: " ", startingAt: 0)
    print("\(padded) \(String(format: "%8d", iters)) \(String(format: "%12.1f", perOp)) \(local)")
}

// ---- synthetic inputs -------------------------------------------------------

func repeatLines(_ n: Int, _ make: (Int) -> String) -> String {
    var s = ""
    s.reserveCapacity(n * 48)
    for i in 0..<n { s += make(i); s += "\n" }
    return s
}

let aptText = repeatLines(5000) { i in
    "libpkg\(i)/stable \(i % 40).\((i * 7) % 90).1 amd64 [upgradable from: \(i % 40).\((i * 7) % 90).0]"
}
let pacmanText = repeatLines(5000) { i in
    "pkg\(i) \(i % 40).\((i * 7) % 90).1 -> \(i % 40).\((i * 7) % 90).2"
}
let dnfText = repeatLines(5000) { i in
    "pkg\(i).x86_64 \(i % 40).\((i * 7) % 90)-1.fc40 updates"
}
let masText = repeatLines(5000) { i in
    "\(100000 + i) App Number \(i) (\(i % 9).1.0 -> \(i % 9).2.1)"
}
let remvText = repeatLines(5000) { i in
    "Remv libgone\(i) [\(i % 9).2.1]"
}
let zypperText = repeatLines(5000) { i in
    "v | Update | pkg\(i) | \(i % 9).1-1 | \(i % 9).2-1 | x86_64"
}
let flatpakText = repeatLines(5000) { i in
    "org.example.App\(i)\t\(i % 9).2.1\tApp \(i)\tA test application"
}
let snapRefreshText = "Name     Version  Rev   Size   Publisher   Notes\n" + repeatLines(5000) { i in
    "pkg\(i)  \(i % 9).2.1  \(1000 + i)  10MB  publisher\(i)  -"
}
let snapInstalledText = repeatLines(5000) { i in
    "pkg\(i)  \(i % 9).2.0  \(900 + i)  latest/stable  publisher\(i)  -"
}
let dpkgText = repeatLines(5000) { i in
    "rc  oldpkg\(i)  \(i % 9).0-1  amd64  leftover config"
}
let pacmanOrphanText = repeatLines(5000) { i in
    "libfoo\(i) \(i % 9).2.3-1"
}
let dnfUnneededText = "Last metadata expiration check: 0:12:00 ago.\n" + repeatLines(5000) { i in
    "libfoo\(i)"
}
let names = (0..<5000).map { "Acme Product \($0) Helper" }
let isoText = repeatLines(5000) { i in
    String(format: "2024-01-%02dT12:34:5%d.123456Z", (i % 28) + 1, i % 10)
}
let timestamps: [String?] = isoText.split(separator: "\n").map(String.init)

// ---- synthetic tree ---------------------------------------------------------

func makeTree(at root: URL, dirs: Int, filesPerDir: Int) {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    for d in 0..<dirs {
        let dir = root.appendingPathComponent("dir\(d)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in 0..<filesPerDir {
            let url = dir.appendingPathComponent("file\(f).txt")
            try? Data(repeating: UInt8(f & 0xff), count: 256).write(to: url)
        }
    }
}

let env = ProcessInfo.processInfo.environment
let treeDirs = Int(env["BENCH_DIRS"] ?? "") ?? 48
let treeFiles = Int(env["BENCH_FILES"] ?? "") ?? 48
let treeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-bench-tree")
if env["BENCH_SKIP_TREE"] != "1" {
    makeTree(at: treeRoot, dirs: treeDirs, filesPerDir: treeFiles)
}

// ---- synthetic shell history ------------------------------------------------

let histRoot = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-bench-hist")
try? FileManager.default.createDirectory(at: histRoot, withIntermediateDirectories: true)
let histLines = Int(env["BENCH_HIST"] ?? "") ?? 50_000

let zshHistFile = histRoot.appendingPathComponent(".zsh_history")
let zshHistText = repeatLines(histLines) { i in
    i % 5 == 4
        ? "plain command number \(i) with a longer argument list here"
        : ": \(1_700_000_000 + i):0;git commit -m \"fix \(i)\""
}
try? zshHistText.write(to: zshHistFile, atomically: false, encoding: .utf8)

let fishHistFile = histRoot.appendingPathComponent("fish_history")
var fishText = ""
fishText.reserveCapacity(histLines * 48)
for i in 0..<histLines {
    fishText += "- cmd: git commit -m \"fix \(i)\"\n  when: \(1_700_000_000 + i)\n"
}
try? fishText.write(to: fishHistFile, atomically: false, encoding: .utf8)

let bigNode = scanDiskUsage(root: treeRoot.path)

let classifyNames = (0..<5000).map { i in
    ["com.example.app\(i).helper", "DDD9A2B1C3E4", "550E8400-E29B-41D4-A716-446655440000", "comapplewebkitdaemon\(i)d"][i % 4]
}

let oneTimestamp = timestamps[0]
let oneName = names[0]

// Adversarial grouping input: many distinct bundle ids (worst case for the
// bucket-collapse pair loops) plus a few true parent/child pairs.
let groupItems: [DataItem] = (0..<3000).map { i in
    DataItem(
        path: "/Users/x/Library/Caches/com.vendor\(i).app\(i)",
        name: "com.vendor\(i).app\(i)",
        rootLabel: "Caches",
        kind: "dir",
        status: "orphaned",
        sizeBytes: 100 + i
    )
} + [
    DataItem(path: "/Users/x/Library/Caches/com.acme.suite", name: "com.acme.suite", rootLabel: "Caches", kind: "dir", status: "orphaned", sizeBytes: 500),
    DataItem(path: "/Users/x/Library/Caches/com.acme.suite.helper", name: "com.acme.suite.helper", rootLabel: "Caches", kind: "dir", status: "orphaned", sizeBytes: 50),
]
let osReleaseText = """
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://archlinux.org/"
DOCUMENTATION="https://wiki.archlinux.org/"
LOGO=archlinux-logo
"""

// ---- benchmarks -------------------------------------------------------------

bench("parse_apt_upgradable", iters: 10) { parseAptUpgradable(aptText).count }
bench("parse_pacman_qu", iters: 10) { parsePacmanQu(pacmanText).count }
bench("parse_dnf_upgrades", iters: 10) { parseDnfUpgrades(dnfText).count }
bench("parse_mas_outdated", iters: 10) { parseMasOutdated(masText).count }
bench("parse_apt_autoremove", iters: 10) { parseAptAutoremove(remvText).count }
bench("parse_zypper_updates", iters: 10) { parseZypperListUpdates(zypperText).count }
bench("parse_flatpak_updates", iters: 10) { parseFlatpakUpdates(flatpakText).count }
bench("parse_snap_refresh", iters: 10) { parseSnapRefreshList(snapRefreshText, installedText: snapInstalledText).count }
bench("parse_dpkg_rc", iters: 10) { parseDpkgRc(dpkgText).count }
bench("parse_pacman_orphans", iters: 10) { parsePacmanOrphans(pacmanOrphanText).count }
bench("parse_dnf_unneeded", iters: 10) { parseDnfUnneeded(dnfUnneededText).count }
bench("group_3000_orphans", iters: 3) { groupOrphanedLeftovers(groupItems).count }
bench("toscan_3000", iters: 3) {
    let r = ScanResult()
    r.dataItems = groupItems
    r.software = (0..<400).map { i in
        Software(name: "App \(i)", kind: "app", path: "/Applications/App \(i).app", source: "pkg/other", lastUsed: Date(), version: "1.\(i)", summary: "A test application with a somewhat longer description here")
    }
    return r.toScanData().leftovers.count + r.toScanData().software.count
}
bench("json_encode_3000", iters: 3) {
    let r = ScanResult()
    r.dataItems = groupItems
    r.software = (0..<400).map { i in
        Software(name: "App \(i)", kind: "app", path: "/Applications/App \(i).app", source: "pkg/other", lastUsed: Date(), version: "1.\(i)", summary: "A test application with a somewhat longer description here")
    }
    let data = r.toScanData()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(data).count) ?? 0
}

// Realistic classify load: 200 installed apps + brew/tools, 5 000 leftover names.
let benchApps: [AppRecord] = (0..<200).map { i in
    AppRecord(path: "/Applications/BenchApp\(i).app", displayName: "BenchApp\(i)", bundleId: "com.bench.app\(i)")
}
let benchBrew = BrewSnapshot(
    available: true,
    formulas: (0..<200).map { i in Formula(name: "bench-formula-\(i)", version: "1.\(i).0") },
    casks: []
)
let benchIdent = Identity(apps: benchApps, brew: benchBrew, toolNames: (0..<50).map { "/home/user/.local/bin/tool\($0)" })
let benchLeftoverNames = (0..<5000).map { i in
    ["benchapp\(i % 200).helper", "orphan-thing-\(i)", "com.bench.app\(i % 200).xpc", "stray\(i)"][i % 4]
}
bench("classify_5000", iters: 5) {
    benchLeftoverNames.reduce(0) { $0 + (benchIdent.classify($1, kind: "dir").0 == "orphaned" ? 1 : 0) }
}
bench("parse_isodate", iters: 5_000) { oneTimestamp.flatMap { parseISODate($0) } == nil ? 0 : 1 }
bench("norm", iters: 20_000) { norm(oneName).count }
bench("redact_home", iters: 2_000) {
    redactHomePaths("/home/alice/Library/Caches/com.example.App/data.bin").count
}
bench("scan_disk_2304_files", iters: 3) { scanDiskUsage(root: treeRoot.path).items }
bench("du_size", iters: 3) { duSize(treeRoot.path).0 }
bench("du_sizes_48_dirs", iters: 3) {
    let dirs = (0..<48).map { treeRoot.appendingPathComponent("dir\($0)").path }
    return duSizes(dirs).values.reduce(0) { $0 + $1.0 }
}
bench("probe_mtime_48_dirs", iters: 3) {
    let dirs = (0..<48).map { treeRoot.appendingPathComponent("dir\($0)").path }
    return dirs.reduce(0) { $0 + (probeActivityMtime($1) == nil ? 0 : 1) }
}
bench("directory_bytes_fallback", iters: 3) { directoryByteSize(treeRoot.path).0 }
bench("format_disk_tree", iters: 5) { formatDiskTree(bigNode).count }
bench("disk_usage_json", iters: 5) { (try? diskUsageJSON(bigNode))?.count ?? 0 }

// ---- history / parsing ------------------------------------------------------

bench("parse_zsh_history", iters: 3) {
    var idx = HistoryIndex()
    parseHistoryFile(zshHistFile.path, index: &idx)
    return idx.lastSeen.count
}
bench("parse_fish_history", iters: 3) {
    var idx = HistoryIndex()
    parseFishHistory(fishHistFile.path, index: &idx)
    return idx.lastSeen.count
}
bench("parse_os_release", iters: 200) { parseOsRelease(osReleaseText).count }
bench("posix_lower", iters: 20_000) { posixLowercased(oneName).count }
bench("ascii_contains", iters: 20_000) {
    (asciiContains(oneName, "product") ? 1 : 0) + (asciiHasByte(oneName, 0x2E) ? 1 : 0)
}
bench("classify_shapes", iters: 20) {
    classifyNames.reduce(0) { $0 + (isBundleId($1) ? 1 : 0) + (isTeamId($1) ? 1 : 0) + (isUUID($1) ? 1 : 0) + (isDaemonName($1) ? 1 : 0) }
}
bench("expand_name_aliases", iters: 200) { names.reduce(0) { $0 + expandNameAliases($1).count } }
bench("human_size", iters: 20_000) { humanSize(names[0].count * 12345).count }
bench("shell_quote", iters: 20_000) { shellQuote(oneName).count }

print("sink=\(sink)")
