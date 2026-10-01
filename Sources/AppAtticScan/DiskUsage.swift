import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One entry in the disk tree. `apparent` is the logical byte sum, `allocated`
/// what the file system actually reserved, and `metric(allocatedSize:)` picks
/// between them. `unreadable` marks a subtree the walk could not enter, and
/// `mountPoint` a child on another device, so a listing can say so rather than
/// read as a complete total.
public final class DiskUsageNode {
    public var name: String
    public var path: String
    public var apparent: Int
    public var allocated: Int
    public var items: Int
    public var mtime: Date?
    public var isDir: Bool
    public var unreadable: Bool
    public var mountPoint: Bool
    public var children: [DiskUsageNode]

    public init(
        name: String,
        path: String,
        apparent: Int = 0,
        allocated: Int = 0,
        items: Int = 1,
        mtime: Date? = nil,
        isDir: Bool = false,
        unreadable: Bool = false,
        mountPoint: Bool = false,
        children: [DiskUsageNode] = []
    ) {
        self.name = name
        self.path = path
        self.apparent = apparent
        self.allocated = allocated
        self.items = items
        self.mtime = mtime
        self.isDir = isDir
        self.unreadable = unreadable
        self.mountPoint = mountPoint
        self.children = children
    }

    public func metric(allocatedSize: Bool) -> Int {
        allocatedSize ? allocated : apparent
    }

    public func sortChildren(allocatedSize: Bool) {
        if children.count > 1 {
            // Collation, not UTF-8 byte order: a byte-ordered tie-break puts
            // "Über" after "Zurich" and every CJK folder after all Latin ones.
            children.sort { a, b in
                let am = a.metric(allocatedSize: allocatedSize)
                let bm = b.metric(allocatedSize: allocatedSize)
                if am != bm { return am > bm }
                return collatedBefore(a.name, b.name, tieBreak: a.path, b.path)
            }
        }
        for c in children { c.sortChildren(allocatedSize: allocatedSize) }
    }
}

/// One mounted volume as the volume list shows it: its name, where it is
/// mounted, the device behind it, and the space figures.
public struct DiskVolume: Equatable, Sendable {
    public var name: String
    public var rootPath: String
    public var fileSystem: String
    public var bytesTotal: Int
    public var bytesAvailable: Int
    public var isRoot: Bool
    public var isHome: Bool
}

/// Bytes per `st_blocks` unit. POSIX fixes the block count at 512-byte units
/// on every platform this scans, and it is a spec constant, not a tunable.
private let bytesPerBlock = 512

private struct UnixMeta {
    var apparent: Int
    var allocated: Int
    var mtime: Date?
    var isDir: Bool
    var isLink: Bool
    var dev: UInt64
    var ino: UInt64
    var nlink: UInt64
}

/// Identity of a file for hardlink / bind-mount dedup. A packed value-keyed set
/// avoids interpolating a `"dev:ino"` String for every directory entry. Only
/// the allocated size is zeroed on a repeat inode: apparent size is the file's
/// own length, so a three-hardlink file reports 3x apparent and 1x allocated.
private struct FileKey: Hashable {
    var dev: UInt64
    var ino: UInt64
}

/// Shared with Leftovers.probeActivityMtime; file-private would hide it.
func unixMtime(_ st: stat) -> TimeInterval {
    #if canImport(Glibc)
    return TimeInterval(st.st_mtim.tv_sec)
    #elseif canImport(Darwin)
    return TimeInterval(st.st_mtimespec.tv_sec)
    #else
    return TimeInterval(st.st_mtime)
    #endif
}

private func unixMetaFromStat(_ st: stat) -> UnixMeta {
    let mode = Int32(st.st_mode)
    let isLink = (mode & Int32(S_IFMT)) == Int32(S_IFLNK)
    let isDir = (mode & Int32(S_IFMT)) == Int32(S_IFDIR) && !isLink
    return UnixMeta(
        apparent: Int(st.st_size),
        allocated: mulBytes(Int(st.st_blocks), bytesPerBlock),
        mtime: Date(timeIntervalSince1970: unixMtime(st)),
        isDir: isDir,
        isLink: isLink,
        dev: UInt64(st.st_dev),
        ino: UInt64(st.st_ino),
        nlink: UInt64(st.st_nlink)
    )
}

private func unixMeta(_ path: String, follow: Bool = false) -> UnixMeta? {
    var st = stat()
    let rc = path.withCString { p in
        follow ? stat(p, &st) : lstat(p, &st)
    }
    if rc != 0 { return nil }
    return unixMetaFromStat(st)
}

public enum DiskRootError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    case missing(path: String)
    case notADirectory(path: String)

    /// `disk` defaults to the account home, so the raw path carries the
    /// account name into the terminal. `~/...` still names the bad root.
    public var description: String {
        redactHomePaths(rawDescription)
    }

    private var rawDescription: String {
        switch self {
        case .missing(let path):
            return "no such directory: \(path)"
        case .notADirectory(let path):
            return "not a directory: \(path)"
        }
    }

    public var errorDescription: String? { description }
}

/// `disk PATH` must name a directory. A typo would otherwise print a one-line
/// "unreadable" tree and exit 0, which reads as an empty disk.
/// Throw unless `path` is a directory that exists, so a bad root is reported
/// before a walk starts rather than as an unreadable node in the tree.
public func validateDiskRoot(_ path: String) throws {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        throw DiskRootError.missing(path: path)
    }
    guard isDir.boolValue else {
        throw DiskRootError.notADirectory(path: path)
    }
}

/// Walks `root` and returns the tree, sorted by allocated size descending.
/// `oneFileSystem` stops at the first other mounted device. `cancel` is polled
/// during the walk; a cancel returns the partial tree rather than throwing.
public func scanDiskUsage(
    root: String,
    oneFileSystem: Bool = true,
    cancel: () -> Bool = { false }
) -> DiskUsageNode {
    let path = (root as NSString).standardizingPath
    let name = (path as NSString).lastPathComponent
    let node = DiskUsageNode(name: name.isEmpty ? path : name, path: path, isDir: true)
    guard let meta = unixMeta(path, follow: true), meta.isDir else {
        node.unreadable = true
        return node
    }
    node.apparent = meta.apparent
    node.allocated = meta.allocated
    node.mtime = meta.mtime
    var seen = Set<FileKey>()
    seen.insert(FileKey(dev: meta.dev, ino: meta.ino))
    let rootFd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard rootFd >= 0 else {
        node.unreadable = true
        return node
    }
    walkDiskFd(
        node: node,
        fd: rootFd,
        rootDev: meta.dev,
        oneFileSystem: oneFileSystem,
        seen: &seen,
        cancel: cancel
    )
    close(rootFd)
    node.sortChildren(allocatedSize: true)
    return node
}

// Shared with DiskSize.walkLogicalBytes; file-private would hide it from that caller.
let childDirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

private func walkDiskFd(
    node: DiskUsageNode,
    fd: Int32,
    rootDev: UInt64,
    oneFileSystem: Bool,
    seen: inout Set<FileKey>,
    cancel: () -> Bool
) {
    if cancel() { return }
    let dupfd = dup(fd)
    guard dupfd >= 0 else {
        node.unreadable = true
        return
    }
    guard let dirp = fdopendir(dupfd) else {
        close(dupfd)
        node.unreadable = true
        return
    }
    defer { closedir(dirp) }
    while true {
        if cancel() { return }
        errno = 0
        guard let ent = readdir(dirp) else {
            if errno != 0 { node.unreadable = true }
            break
        }
        guard let name = direntName(ent) else {
            // Not representable as text, so not representable as a path:
            // counting it under a substituted name would report the wrong size.
            node.unreadable = true
            continue
        }
        if name == "." || name == ".." { continue }
        let childPath = node.path.hasSuffix("/") ? node.path + name : node.path + "/" + name
        var st = stat()
        let rc = name.withCString { fstatat(fd, $0, &st, AT_SYMLINK_NOFOLLOW) }
        if rc != 0 {
            // ENOENT is the entry leaving under a live scan: it is gone, not
            // uncountable. Any other errno leaves an entry of unknown size in
            // this total, so the tree is partial and says so.
            if errno != ENOENT { node.unreadable = true }
            continue
        }
        let meta = unixMetaFromStat(st)
        let child = DiskUsageNode(
            name: name,
            path: childPath,
            apparent: meta.apparent,
            allocated: 0,
            items: 1,
            mtime: meta.mtime,
            isDir: meta.isDir
        )
        let key = FileKey(dev: meta.dev, ino: meta.ino)
        let seenDir = meta.isDir && seen.contains(key)
        let hardDup = !meta.isDir && meta.nlink > 1 && seen.contains(key)
        if !hardDup {
            child.allocated = meta.allocated
            if !meta.isDir && meta.nlink > 1 { seen.insert(key) }
        }
        if meta.isDir {
            if seenDir || (oneFileSystem && meta.dev != rootDev) {
                child.mountPoint = true
            } else {
                seen.insert(key)
                let childFd = name.withCString { openat(fd, $0, childDirFlags) }
                if childFd < 0 {
                    child.unreadable = true
                } else {
                    walkDiskFd(
                        node: child,
                        fd: childFd,
                        rootDev: rootDev,
                        oneFileSystem: oneFileSystem,
                        seen: &seen,
                        cancel: cancel
                    )
                    close(childFd)
                }
            }
        }
        node.children.append(child)
        node.apparent = addBytes(node.apparent, child.apparent)
        node.allocated = addBytes(node.allocated, child.allocated)
        node.items = addBytes(node.items, child.items)
    }
}

/// Render a tree as indented text, one line per entry. `top` keeps only the
/// largest children of each level; pair it with `diskTreeHiddenEntries` so the
/// cut is visible.
public func formatDiskTree(
    _ node: DiskUsageNode,
    allocatedSize: Bool = true,
    top: Int? = nil,
    depth: Int = 0
) -> String {
    var lines: [String] = []
    func emit(_ n: DiskUsageNode, _ depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        var extra = ""
        if n.unreadable { extra += " unreadable" }
        if n.mountPoint { extra += " other-filesystem" }
        let size = humanSize(n.metric(allocatedSize: allocatedSize))
        // The name is whatever a directory on the scanned tree is called, so
        // it goes through `terminalSafe`: a folder whose name carries an
        // escape would otherwise repaint the report it is a row in.
        lines.append("\(indent)\(terminalSafe(n.name))  \(size)\(extra)")
        var kids = n.children
        if let top {
            kids = Array(kids.prefix(max(0, top)))
        }
        for c in kids { emit(c, depth + 1) }
    }
    emit(node, depth)
    return lines.joined(separator: "\n") + "\n"
}

/// Entries a `--top N` tree leaves out. The tree itself is silent about the
/// cut, so without this a sliced listing reads as the whole folder.
public func diskTreeHiddenEntries(_ node: DiskUsageNode, top: Int) -> Int {
    var hidden = 0
    var stack: [DiskUsageNode] = [node]
    while let n = stack.popLast() {
        let shown = min(n.children.count, max(0, top))
        hidden += n.children.count - shown
        stack.append(contentsOf: n.children.prefix(shown))
    }
    return hidden
}

/// JSON for the disk tree, written straight into a byte buffer.
///
/// The old shape built a `[String: Any]` per node and handed the whole tree to
/// `JSONSerialization`: 112 ms for a 2 300-node tree (~48 µs/node, mostly
/// dictionary and NSNumber boxing), which is minutes on a real home directory.
/// Field names and key order match `JSONSerialization` with `.sortedKeys`; the
/// pretty-print layout is `indent: 2, "key": value`.
public func diskUsageJSON(_ node: DiskUsageNode) throws -> Data {
    var out: [UInt8] = []
    out.reserveCapacity(1024 + node.items * 96)
    appendDiskUsageJSON(node, to: &out, depth: 0)
    return Data(out)
}

private let juTrue: [UInt8] = [0x74, 0x72, 0x75, 0x65]
private let juFalse: [UInt8] = [0x66, 0x61, 0x6C, 0x73, 0x65]
private let juEmptyArray: [UInt8] = [0x5B, 0x5D]

private func appendDiskUsageJSON(_ n: DiskUsageNode, to out: inout [UInt8], depth: Int) {
    func indent(_ d: Int) {
        out.append(0x0A)
        var i = 0
        while i < d {
            out.append(0x20)
            out.append(0x20)
            i += 1
        }
    }
    out.append(0x7B) // {
    indent(depth + 1); juKey("allocated", &out); juInt(n.allocated, &out); out.append(0x2C)
    indent(depth + 1); juKey("apparent", &out); juInt(n.apparent, &out); out.append(0x2C)
    indent(depth + 1); juKey("children", &out)
    if n.children.isEmpty {
        out.append(contentsOf: juEmptyArray)
    } else {
        out.append(0x5B) // [
        for (i, c) in n.children.enumerated() {
            if i > 0 { out.append(0x2C) }
            indent(depth + 2)
            appendDiskUsageJSON(c, to: &out, depth: depth + 2)
        }
        indent(depth + 1)
        out.append(0x5D) // ]
    }
    out.append(0x2C)
    indent(depth + 1); juKey("isDir", &out); out.append(contentsOf: n.isDir ? juTrue : juFalse); out.append(0x2C)
    indent(depth + 1); juKey("items", &out); juInt(n.items, &out); out.append(0x2C)
    indent(depth + 1); juKey("mountPoint", &out); out.append(contentsOf: n.mountPoint ? juTrue : juFalse); out.append(0x2C)
    indent(depth + 1); juKey("name", &out); juString(n.name, &out); out.append(0x2C)
    indent(depth + 1); juKey("path", &out); juString(n.path, &out); out.append(0x2C)
    indent(depth + 1); juKey("unreadable", &out); out.append(contentsOf: n.unreadable ? juTrue : juFalse)
    indent(depth)
    out.append(0x7D) // }
}

@inline(__always)
private func juKey(_ k: String, _ out: inout [UInt8]) {
    juString(k, &out)
    out.append(0x3A) // :
    out.append(0x20)
}

private func juString(_ s: String, _ out: inout [UInt8]) {
    out.append(0x22)
    for b in s.utf8 {
        switch b {
        case 0x22: out.append(0x5C); out.append(0x22)
        case 0x5C: out.append(0x5C); out.append(0x5C)
        case 0x08: out.append(0x5C); out.append(0x62)
        case 0x09: out.append(0x5C); out.append(0x74)
        case 0x0A: out.append(0x5C); out.append(0x6E)
        case 0x0C: out.append(0x5C); out.append(0x66)
        case 0x0D: out.append(0x5C); out.append(0x72)
        default:
            if b < 0x20 {
                out.append(0x5C); out.append(0x75)
                out.append(0x30); out.append(0x30)
                out.append(juHex(b >> 4)); out.append(juHex(b & 0x0F))
            } else {
                out.append(b)
            }
        }
    }
    out.append(0x22)
}

@inline(__always)
private func juHex(_ v: UInt8) -> UInt8 {
    v < 10 ? (0x30 + v) : (0x61 + v - 10)
}

private func juInt(_ value: Int, _ out: inout [UInt8]) {
    if value == 0 {
        out.append(0x30)
        return
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buf in
        // Negative digits are accumulated as-is so Int.min does not overflow on negation.
        var n = value
        let neg = n < 0
        var i = 20
        while n != 0 {
            i -= 1
            let d = n % 10
            buf[i] = 0x30 &+ UInt8(truncatingIfNeeded: neg ? -d : d)
            n /= 10
        }
        if neg { out.append(0x2D) }
        out.append(contentsOf: UnsafeBufferPointer(start: buf.baseAddress! + i, count: 20 - i))
    }
}

private let virtualFs: Set<String> = [
    "proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs",
    "pstore", "bpf", "tracefs", "debugfs", "hugetlbfs", "mqueue", "ramfs",
    "autofs", "fusectl", "configfs", "rpc_pipefs", "binfmt_misc", "overlay",
    "squashfs", "nsfs", "efivarfs", "tmpfs",
]

/// `/proc/mounts` writes space, tab, newline, and backslash in a field as
/// three-digit octal. Undo all four; a mount point with a tab or a backslash in
/// its name is otherwise listed under a path that does not exist.
/// Linux-only: nothing else writes this format.
func unescapeProcMountField(_ field: String) -> String {
    var out = ""
    var rest = field[...]
    while let slash = rest.firstIndex(of: "\\") {
        let first = rest.index(after: slash)
        guard let last = rest.index(first, offsetBy: 2, limitedBy: rest.endIndex),
              last < rest.endIndex,
              let byte = UInt8(rest[first...last], radix: 8) else {
            out += rest[...slash]
            rest = rest[first...]
            continue
        }
        out += rest[..<slash]
        out.append(Character(UnicodeScalar(byte)))
        rest = rest[rest.index(first, offsetBy: 3)...]
    }
    return out + rest
}

/// The unit `f_blocks` and `f_bavail` are counted in, as a byte count.
///
/// `f_frsize` is the fragment size and is what has to be used when it is
/// nonzero: on a filesystem that allocates in blocks larger than the
/// fragment, multiplying by anything else overstates the volume. It is
/// zero on some network and FUSE mounts, and the whole product is then
/// zero, so the volume reports "0 B" and drops out of the list entirely.
/// `f_bsize` is the preferred block size, the unit `f_frsize` is itself
/// derived from, and the only substitute the interface offers.
func volumeBlockSize(_ st: statvfs) -> Int {
    let fragment = Int(clamping: st.f_frsize)
    return fragment > 0 ? fragment : Int(clamping: st.f_bsize)
}

/// Root file system first, then the home one, then the rest in collated
/// mount-path order. Both platform arms sort with this: sorting the macOS rows
/// on the path alone put `/` first only because it collates before `/Users`
/// and `/Volumes`, which says nothing about a home volume on another device.
private func volumeBefore(_ a: DiskVolume, _ b: DiskVolume) -> Bool {
    if a.isRoot != b.isRoot { return a.isRoot }
    if a.isHome != b.isHome { return a.isHome }
    // Collated: a mount point is a path, and byte order files every non-ASCII
    // one ("/media/Ünïcode", "/Volumes/日本語") after the ASCII mounts. The
    // path breaks the tie, since two rows can carry the same label and `sort`
    // is not stable.
    return collatedBefore(a.rootPath, b.rootPath, tieBreak: a.rootPath, b.rootPath)
}

/// The volumes to list, the root file system first, then the home one, then
/// the rest in collated mount-path order. `mountsText` replaces the platform's
/// mount table, so a caller can parse a captured one on either platform.
public func listDiskVolumes(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    mountsText: String? = nil
) -> [DiskVolume] {
    #if os(Linux)
    let text = mountsText ?? (readUTF8File("/proc/mounts") ?? "")
    var seen = Set<String>()
    var out: [DiskVolume] = []
    for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 3 else { continue }
        let root = unescapeProcMountField(parts[1])
        let fs = parts[2]
        if seen.contains(root) { continue }
        if virtualFs.contains(fs) && root != "/" { continue }
        var total = 0
        var avail = 0
        var st = statvfs()
        if root.withCString({ statvfs($0, &st) }) == 0 {
            // The counts are unsigned and the product is not bounded by the
            // filesystem, so both the conversion and the multiply are
            // checked: a wrapped total reads as negative, which drops the
            // volume below out of the list entirely.
            let blockSize = volumeBlockSize(st)
            total = mulBytes(blockSize, Int(clamping: st.f_blocks))
            avail = mulBytes(blockSize, Int(clamping: st.f_bavail))
        }
        if total <= 0 && root != "/" { continue }
        // Claimed only once it is really a volume: an over-mount that statvfs
        // could not resolve must not lock out the real mount listed after it.
        seen.insert(root)
        out.append(DiskVolume(
            name: root == "/" ? "File system" : (root as NSString).lastPathComponent,
            rootPath: root,
            fileSystem: fs,
            bytesTotal: total,
            bytesAvailable: avail,
            isRoot: root == "/",
            isHome: home == root || home.hasPrefix(root == "/" ? "/" : root + "/")
        ))
    }
    return out.sorted(by: volumeBefore)
    #else
    _ = mountsText
    var out: [DiskVolume] = []
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
    if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) {
        for url in urls {
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let root = url.path
            out.append(DiskVolume(
                name: vals?.volumeName ?? (root as NSString).lastPathComponent,
                rootPath: root,
                fileSystem: "",
                bytesTotal: vals?.volumeTotalCapacity ?? 0,
                bytesAvailable: vals?.volumeAvailableCapacity ?? 0,
                isRoot: root == "/",
                isHome: home == root || home.hasPrefix(root == "/" ? "/" : root + "/")
            ))
        }
    }
    // Sorted by mount point, the way the mount table above is read: the URL
    // list is in readdir order, so the rows and the JSON written from them
    // would come out in a different order on every run. Collated, so a
    // non-ASCII mount name is not filed after every ASCII one.
    return out.sorted(by: volumeBefore)
    #endif
}
