import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
            // Fold the name once per child instead of bridging to NSString for
            // every comparator call: tie-heavy directories do O(n) folds, not O(n log n).
            var keyed = children.map { (node: $0, key: $0.name.lowercased()) }
            keyed.sort { a, b in
                let am = a.node.metric(allocatedSize: allocatedSize)
                let bm = b.node.metric(allocatedSize: allocatedSize)
                if am != bm { return am > bm }
                return a.key < b.key
            }
            children = keyed.map(\.node)
        }
        for c in children { c.sortChildren(allocatedSize: allocatedSize) }
    }
}

public struct DiskVolume: Equatable, Sendable {
    public var name: String
    public var rootPath: String
    public var fileSystem: String
    public var bytesTotal: Int
    public var bytesAvailable: Int
    public var isRoot: Bool
    public var isHome: Bool
}

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
/// avoids interpolating a `"dev:ino"` String for every directory entry.
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
        allocated: Int(st.st_blocks) * 512,
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

func direntName(_ ent: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &ent.pointee.d_name) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
}

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

// Shared with Util.walkLogicalBytes; file-private would hide it from that caller.
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
        let name = direntName(ent)
        if name == "." || name == ".." { continue }
        let childPath = node.path.hasSuffix("/") ? node.path + name : node.path + "/" + name
        var st = stat()
        let rc = name.withCString { fstatat(fd, $0, &st, AT_SYMLINK_NOFOLLOW) }
        if rc != 0 { continue }
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
        lines.append("\(indent)\(n.name)  \(size)\(extra)")
        var kids = n.children
        if let top {
            kids = Array(kids.prefix(max(0, top)))
        }
        for c in kids { emit(c, depth + 1) }
    }
    emit(node, depth)
    return lines.joined(separator: "\n") + "\n"
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
    "squashfs", "nsfs", "efivarfs",
]

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
        let device = parts[0]
        let root = parts[1].replacingOccurrences(of: "\\040", with: " ")
        let fs = parts[2]
        if seen.contains(root) { continue }
        if virtualFs.contains(fs) && root != "/" { continue }
        seen.insert(root)
        var total = 0
        var avail = 0
        var st = statvfs()
        if root.withCString({ statvfs($0, &st) }) == 0 {
            total = Int(st.f_frsize) * Int(st.f_blocks)
            avail = Int(st.f_frsize) * Int(st.f_bavail)
        }
        if total <= 0 && root != "/" { continue }
        out.append(DiskVolume(
            name: root == "/" ? "File system" : (root as NSString).lastPathComponent,
            rootPath: root,
            fileSystem: fs,
            bytesTotal: total,
            bytesAvailable: avail,
            isRoot: root == "/",
            isHome: home == root || home.hasPrefix(root == "/" ? "/" : root + "/")
        ))
        _ = device
    }
    return out.sorted { a, b in
        if a.isRoot != b.isRoot { return a.isRoot }
        if a.isHome != b.isHome { return a.isHome }
        return a.rootPath < b.rootPath
    }
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
                isHome: home == root || home.hasPrefix(root + "/")
            ))
        }
    }
    return out
    #endif
}
