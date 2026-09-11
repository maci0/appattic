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
        children.sort { a, b in
            let am = a.metric(allocatedSize: allocatedSize)
            let bm = b.metric(allocatedSize: allocatedSize)
            if am != bm { return am > bm }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
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

private func unixMtime(_ st: stat) -> TimeInterval {
    #if canImport(Glibc)
    return TimeInterval(st.st_mtim.tv_sec)
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

private func direntName(_ ent: dirent) -> String {
    var e = ent
    return withUnsafePointer(to: &e.d_name) { ptr in
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
    var seen = Set<String>()
    seen.insert("\(meta.dev):\(meta.ino)")
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

private let childDirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

private func walkDiskFd(
    node: DiskUsageNode,
    fd: Int32,
    rootDev: UInt64,
    oneFileSystem: Bool,
    seen: inout Set<String>,
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
        let name = direntName(ent.pointee)
        if name == "." || name == ".." { continue }
        let childPath = (node.path as NSString).appendingPathComponent(name)
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
        let key = "\(meta.dev):\(meta.ino)"
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

public func diskUsageJSON(_ node: DiskUsageNode) throws -> Data {
    func obj(_ n: DiskUsageNode) -> [String: Any] {
        [
            "name": n.name,
            "path": n.path,
            "apparent": n.apparent,
            "allocated": n.allocated,
            "items": n.items,
            "isDir": n.isDir,
            "unreadable": n.unreadable,
            "mountPoint": n.mountPoint,
            "children": n.children.map { obj($0) },
        ]
    }
    return try JSONSerialization.data(withJSONObject: obj(node), options: [.prettyPrinted, .sortedKeys])
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
