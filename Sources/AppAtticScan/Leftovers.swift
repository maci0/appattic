import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The leftover scan: the roots it walks, the item model, the activity probe,
// and the two scans that fill a result. Ownership of a name is `Identity`,
// wording is `LeftoverText`, grouping is `LeftoverGroups`, and PATH or overlay
// directories are `Overlays`.

/// Ownership rule for the two taxonomies that walk the same directories:
/// Leftovers owns *data* (`~/.steam`, `~/.wine`, …; the `path-home-dot`
/// allowlist in `core/src/path_listing.zig` covers a subset of these, keep the
/// two in sync); Packages owns *tools* (PATH overlays, globals). A file in an
/// overlay root that a package dir also ships (e.g. `~/.local/bin/foo` against
/// `/usr/bin/foo`) is reported on Leftovers with a `shadow` status linking the
/// packaged path, and the cleanup script removes the overlay path only, leaving
/// the packaged file alone. See `Overlays.swift` `listShadowingOverlays` and
/// `LeftoverText.swift` `isUserBinLeftoverPath`.
let homeDotData = [
    ".mozilla", ".thunderbird", ".steam", ".wine", ".java",
    ".gradle", ".docker", ".kube", ".aws", ".gnupg", ".ssh",
    ".npm", ".cargo", ".rustup", ".android", ".m2",
]

let skipDescend: Set<String> = [
    "node_modules", ".git", "__pycache__", "Caches", "Cache",
    "DerivedData", ".cache",
]

let skipNestedRoots: Set<String> = ["Containers", "Group Containers", "WebKit"]

/// The XDG base directories a Linux scan descends, as
/// `(label, path, kind)` per root.
///
/// All three fields are positional, so the order is the only thing telling them
/// apart: `label` is the short name a report shows, `path` is the directory to
/// read, and `kind` is what the entries under it are (`"dir"` for a plain
/// directory). Pass the kind to `includeScanEntry`, which needs it to tell a
/// directory from a plist.
public func xdgScanRoots(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [(String, String, String)] {
    let cfg = xdgConfigHome(home: home, env: env)
    let share = xdgDataHome(home: home, env: env)
    let cache = xdgCacheHome(home: home, env: env)
    let state = xdgStateHome(home: home, env: env)
    let lib = ((home as NSString).appendingPathComponent(".local") as NSString).appendingPathComponent("lib")
    return [
        (".config", cfg, "dir"),
        (".local/share", share, "dir"),
        (".cache", cache, "dir"),
        (".local/state", state, "dir"),
        (".local/lib", lib, "dir"),
    ]
}

/// Every root a scan reads on this platform, as `(label, path, kind)`, in the
/// same positional order as `xdgScanRoots`. A macOS root list and a Linux one
/// are both returned by the same call, so a caller does not branch on the OS to
/// enumerate them.
public func scanRootsForPlatform() -> [(String, String, String)] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let xdg = xdgScanRoots(home: home)
    if PlatformOverride.isLinux {
        return xdg + [
            (".var/app", (home as NSString).appendingPathComponent(".var/app"), "dir"),
            ("snap", (home as NSString).appendingPathComponent("snap"), "dir"),
        ]
    }
    let lib = (home as NSString).appendingPathComponent("Library")
    return [
        ("Application Support", (lib as NSString).appendingPathComponent("Application Support"), "dir"),
        ("Caches", (lib as NSString).appendingPathComponent("Caches"), "dir"),
        ("Preferences", (lib as NSString).appendingPathComponent("Preferences"), "plist"),
        ("Saved Application State", (lib as NSString).appendingPathComponent("Saved Application State"), "savedstate"),
        ("Containers", (lib as NSString).appendingPathComponent("Containers"), "bundleid"),
        ("Group Containers", (lib as NSString).appendingPathComponent("Group Containers"), "group"),
        ("Logs", (lib as NSString).appendingPathComponent("Logs"), "dir"),
        ("WebKit", (lib as NSString).appendingPathComponent("WebKit"), "bundleid"),
        ("HTTPStorages", (lib as NSString).appendingPathComponent("HTTPStorages"), "mixed"),
    ] + xdg
}

/// The `~/.something` directories a scan reads, as `(path, kind)`. The kind is
/// the constant `"leaf"` on every entry: these are directories named after a
/// single app, so nothing under them is a bundle or a plist.
public func homeDataLeaves() -> [(String, String)] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return homeDotData.map { ((home as NSString).appendingPathComponent($0), "leaf") }
}

public func includeScanEntry(_ path: String, kind: String) -> Bool {
    let base = URL(fileURLWithPath: path).lastPathComponent
    if base == ".DS_Store" || base == ".localized" { return false }
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if kind == "dir" || kind == "bundleid" || kind == "group" {
        return exists && isDir.boolValue
    }
    if kind == "plist" {
        return exists && !isDir.boolValue && path.hasSuffix(".plist")
    }
    return exists
}

public final class DataItem {
    public var path: String
    public var name: String
    public var rootLabel: String
    public var kind: String
    public var status: String
    public var owner: String?
    public var sizeBytes: Int
    public var sizeMeasured: Bool
    public var mtime: Date?
    public var activityMtime: Date?
    public var reason: String?
    public var summary: String?
    public var extraPaths: [String]
    public var shadows: String?

    public init(
        path: String,
        name: String,
        rootLabel: String,
        kind: String,
        status: String = "orphaned",
        owner: String? = nil,
        shadows: String? = nil,
        sizeBytes: Int = 0,
        sizeMeasured: Bool = true,
        mtime: Date? = nil,
        activityMtime: Date? = nil,
        reason: String? = nil,
        summary: String? = nil,
        extraPaths: [String] = []
    ) {
        self.path = path
        self.name = name
        self.rootLabel = rootLabel
        self.kind = kind
        self.status = status
        self.owner = owner
        self.shadows = shadows
        self.sizeBytes = sizeBytes
        self.sizeMeasured = sizeMeasured
        self.mtime = mtime
        self.activityMtime = activityMtime
        self.reason = reason
        self.summary = summary
        self.extraPaths = extraPaths
    }

    /// `status` as a typed value, or nil when it is not a known status.
    public var leftoverStatus: LeftoverStatus? { LeftoverStatus(rawValue: status) }

    /// True for the rows the leftover lists keep: orphaned and shadow
    /// (`visibleOrphanedLeftovers` applies this test).
    public var isListedLeftover: Bool { isListedLeftoverStatus(status) }

    public func toLeftoverItem() -> LeftoverItem {
        LeftoverItem(
            name: name,
            path: path,
            root: rootLabel,
            kind: kind,
            status: status,
            owner: owner,
            size_bytes: sizeBytes,
            size_measured: sizeMeasured,
            mtime: isoString(activityMtime ?? mtime),
            reason: reason,
            summary: summary,
            extra_paths: extraPaths.isEmpty ? nil : extraPaths,
            shadows: shadows
        )
    }
}

public struct OrphanAgent {
    public var path: String
    public var label: String
    public var program: String
    public init(path: String, label: String, program: String) {
        self.path = path
        self.label = label
        self.program = program
    }
}

func dataItem(from agent: OrphanAgent, ident: Identity? = nil) -> DataItem {
    var status = LeftoverStatus.orphaned.rawValue
    var owner: String?
    if let ident {
        let base = URL(fileURLWithPath: agent.program).lastPathComponent
        if !isGenericOwnerToken(base) {
            let (st, own) = ident.classify(base, kind: "dir")
            if st == "owned" || st == "system" {
                status = LeftoverStatus.owned.rawValue
                owner = own
            }
        }
    }
    return DataItem(
        path: agent.path,
        name: agent.label,
        rootLabel: "LaunchAgents",
        kind: "plist",
        status: status,
        owner: owner
    )
}

public func skipNestedProbe(_ item: DataItem) -> Bool {
    if item.leftoverStatus == .system { return true }
    if item.kind == "bundleid" || item.kind == "group" { return true }
    if skipNestedRoots.contains(item.rootLabel) { return true }
    return false
}

/// True when a leftover's bytes are already counted by the row above it, so
/// the scan measures neither again. False for an ordinary leftover whose size
/// query simply failed.
public func leftoverSizeIsNested(kind: String, root: String) -> Bool {
    if kind == "bundleid" || kind == "group" { return true }
    return skipNestedRoots.contains(root)
}

/// The size a report prints for one leftover row, and why it is missing when
/// it is.
///
/// A row with no byte count has one of two reasons, and they read very
/// differently. A nested row is deliberately not walked again because its
/// bytes are already in the parent total. Any other unmeasured row is a size
/// query that failed: `du` was not installed, ran out of time, hit the output
/// limit, or the walk could not open the tree. One label for both told the
/// operator a failed measurement was a permissions boundary, which is a claim
/// nothing established about a path the scan has not read.
public func leftoverSizeText(measured: Bool, sizeBytes: Int, kind: String, root: String) -> String {
    if measured { return humanSize(sizeBytes) }
    if leftoverSizeIsNested(kind: kind, root: root) { return "n/a (counted above)" }
    return "n/a (size unknown)"
}

/// One `stat` (follows symlinks, like the old `attributesOfItem`): mtime and

/// kind together, without Foundation's owner/group lookup per entry.
private func statMtimeKind(_ path: String) -> (mtime: Date, isDir: Bool)? {
    var st = stat()
    guard path.withCString({ stat($0, &st) }) == 0 else { return nil }
    let kind = Int32(st.st_mode) & Int32(S_IFMT)
    return (Date(timeIntervalSince1970: unixMtime(st)), kind == Int32(S_IFDIR))
}

public func probeActivityMtime(
    _ path: String,
    maxEntries: Int = 80,
    maxDepth: Int = 2,
    timeout: TimeInterval = 0.2,
    clock: MonotonicFn = monotonicSeconds
) -> Date? {
    // fd walk, not Foundation: `attributesOfItem` populates owner names per
    // entry (NSS lookup) and `contentsOfDirectory(...).sorted()` sorts every
    // directory for a max() that is order-independent. Same budget, timeout,
    // dotfile/skipDescend, and follow-symlink semantics as before.
    let start = clock()
    var best: Date?
    var seen = 0
    var stack: [(String, Int)] = [(path, 0)]
    while !stack.isEmpty {
        if clock() - start > timeout || seen >= maxEntries { break }
        let (current, depth) = stack.removeLast()
        guard let (mtime, isDir) = statMtimeKind(current) else { continue }
        seen += 1
        if best == nil || mtime > best! { best = mtime }
        if depth >= maxDepth || !isDir { continue }
        guard let dirp = current.withCString({ opendir($0) }) else { continue }
        // Collect names first, then close before pushing children. The read is
        // bounded by the same budget as the walk: a name past it can never be
        // visited, and a directory with hundreds of thousands of entries used
        // to be fully read and materialized as Strings before the budget was
        // consulted at all.
        var names: [String] = []
        while names.count < maxEntries - seen {
            if clock() - start > timeout { break }
            errno = 0
            guard let ent = readdir(dirp) else { break }
            guard let name = direntName(ent) else { continue }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            names.append(name)
        }
        for name in names {
            if clock() - start > timeout || seen >= maxEntries { break }
            let child = (current as NSString).appendingPathComponent(name)
            if skipDescend.contains(name) {
                if let (mt, _) = statMtimeKind(child) {
                    seen += 1
                    if best == nil || mt > best! { best = mt }
                }
                continue
            }
            if depth + 1 <= maxDepth {
                stack.append((child, depth + 1))
            }
        }
        closedir(dirp)
    }
    return best
}

public func applyRecentActivity(_ items: [DataItem], now: Date = Date()) {
    for item in items {
        if item.leftoverStatus != .orphaned { continue }
        if item.rootLabel == "LaunchAgents" { continue }
        if item.kind == "symlink" { continue }
        guard let dt = item.activityMtime ?? item.mtime else { continue }
        if let age = daysSince(dt, now: now), age <= Double(activeDays) {
            item.status = LeftoverStatus.active.rawValue
        }
    }
}

public func scanLeftovers(
    apps: [AppRecord],
    brew: BrewSnapshot,
    progress: (String) -> Void = { _ in },
    roots: [(String, String, String)]? = nil,
    measureSizes: Bool = true,
    now: Date = Date(),
    clock: MonotonicFn = monotonicSeconds,
    run: CommandRun = runCommand
) -> ([DataItem], [OrphanAgent]) {
    // One walk of the tool directories feeds both halves of Identity.
    let toolEntries = executableToolEntries(in: nil)
    let ident = Identity(
        apps: apps + appsFromPathBinaries(entries: toolEntries),
        brew: brew,
        toolNames: listUserToolNames(entries: toolEntries)
    )
    var allRoots = roots ?? scanRootsForPlatform()
    if roots == nil {
        for (path, kind) in homeDataLeaves() {
            allRoots.append(("home", path, kind))
        }
    }
    progress("  · scanning data locations for \(allRoots.count) roots…")
    var items: [DataItem] = []
    for (label, root, kind) in allRoots {
        if kind == "leaf" {
            if !includeScanEntry(root, kind: kind) { continue }
            var name = stripBidiControls(URL(fileURLWithPath: root).lastPathComponent)
            if name.hasPrefix(".") { name = String(name.dropFirst()) }
            let (status, owner) = ident.classify(name, kind: "dir")
            items.append(DataItem(path: root, name: name, rootLabel: label, kind: kind, status: status, owner: owner))
            continue
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
        for path in listEntries(root) {
            if !includeScanEntry(path, kind: kind) { continue }
            let name = stripBidiControls(URL(fileURLWithPath: path).lastPathComponent)
            if kind == "plist", !name.hasSuffix(".plist") { continue }
            let (status, owner) = ident.classify(name, kind: kind)
            items.append(DataItem(path: path, name: name, rootLabel: label, kind: kind, status: status, owner: owner))
        }
    }

    let agents: [OrphanAgent]
    if roots == nil {
        agents = scanLaunchAgents(progress: progress)
        for agent in agents {
            items.append(dataItem(from: agent, ident: ident))
        }
        items.append(contentsOf: listBrokenUserBinLinks())
        items.append(contentsOf: listShadowingOverlays())
    } else {
        agents = []
    }

    if measureSizes {
        let toMeasure = items.filter { isListedLeftoverStatus($0.status) && !skipNestedProbe($0) }
        progress("  · measuring sizes for \(toMeasure.count) leftover folders…")
        // One `du -sk` per chunk, not one spawn per folder.
        let sizes = duSizes(toMeasure.map(\.path), timeout: 6, run: run)
        let measuredIds = Set(toMeasure.map { ObjectIdentifier($0) })
        var dirPaths = Set<String>()
        dirPaths.reserveCapacity(items.count)
        for item in items {
            if measuredIds.contains(ObjectIdentifier(item)) {
                let pair = sizes[item.path] ?? (0, false)
                item.sizeBytes = pair.0
                item.sizeMeasured = pair.1
            } else if skipNestedProbe(item) {
                item.sizeBytes = 0
                item.sizeMeasured = false
            } else if !isListedLeftoverStatus(item.status) {
                item.sizeBytes = 0
                item.sizeMeasured = true
            }
            if let (mt, isDir) = statMtimeKind(item.path) {
                item.mtime = mt
                // The nested probe walks directories only, and this is the
                // same `stat` that reads the mtime: a separate
                // `fileExists(atPath:isDirectory:)` per item was a third stat
                // for a fact this pass already had.
                if isDir { dirPaths.insert(item.path) }
            }
        }
        progress("  · checking nested mtimes for \(items.lazy.filter { $0.leftoverStatus != .system }.count) entries…")
        let acts = pmap(items, workers: 8) { item -> Date? in
            if skipNestedProbe(item) { return item.mtime }
            guard dirPaths.contains(item.path) else { return item.mtime }
            return probeActivityMtime(item.path, clock: clock) ?? item.mtime
        }
        for (item, act) in zip(items, acts) {
            item.activityMtime = act
        }
        applyRecentActivity(items, now: now)
    }
    items = groupOrphanedLeftovers(items)
    applyOrphanReasons(items)
    return (items, agents)
}

public func scanLaunchAgents(
    progress: (String) -> Void = { _ in },
    roots: [String]? = nil
) -> [OrphanAgent] {
    if PlatformOverride.isLinux { return [] }
    progress("  · checking LaunchAgents…")
    var orphans: [OrphanAgent] = []
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dirs = roots ?? [
        (home as NSString).appendingPathComponent("Library/LaunchAgents"),
        "/Library/LaunchAgents",
    ]
    for root in dirs {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
        for path in listEntries(root) where path.hasSuffix(".plist") {
            let info = loadPlist(path)
            if info.isEmpty { continue }
            let label = stripBidiControls((info["Label"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent)
            var program: String?
            if let args = info["ProgramArguments"] as? [Any], let first = args.first {
                program = "\(first)"
            } else if let p = info["Program"] {
                program = "\(p)"
            }
            guard let program, !program.isEmpty else { continue }
            if program.hasPrefix("/usr/bin/") || program.hasPrefix("/bin/") || program.hasPrefix("/usr/sbin/") || program.hasPrefix("/sbin/") {
                continue
            }
            if !FileManager.default.fileExists(atPath: program) {
                orphans.append(OrphanAgent(path: path, label: label, program: program))
            } else if program.contains(".app/") {
                // Bundle root without bridging to NSString.
                let bundle: String
                if let r = program.range(of: ".app/") {
                    bundle = String(program[..<r.upperBound].dropLast())
                } else {
                    bundle = program
                }
                if !bundle.isEmpty, !FileManager.default.fileExists(atPath: bundle) {
                    orphans.append(OrphanAgent(path: path, label: label, program: program))
                }
            }
        }
    }
    return orphans
}
