import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func intFromSizeAttribute(_ raw: Any?) -> Int {
    let v: Int64
    if let u = raw as? UInt64 {
        if u > UInt64(Int64.max) { return Int.max }
        v = Int64(u)
    } else if let n = raw as? NSNumber {
        v = n.int64Value
    } else if let i = raw as? Int {
        v = Int64(i)
    } else if let i = raw as? Int64 {
        v = i
    } else {
        return 0
    }
    if v < 0 { return 0 }
    if v > Int64(Int.max) { return Int.max }
    return Int(v)
}

public func fileSize(_ path: String) -> Int {
    intFromSizeAttribute(try? FileManager.default.attributesOfItem(atPath: path)[.size])
}

public func duSize(_ path: String, timeout: TimeInterval = 8, run: CommandRun = runCommand) -> (Int, Bool) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        return (0, false)
    }
    if !isDir.boolValue {
        return (fileSize(path), true)
    }
    if path.hasSuffix(".app"), let bytes = spotlightFSSize(path, run: run) {
        return (bytes, true)
    }
    for exe in ["/usr/bin/du", "du"] {
        let (rc, out, _) = run([exe, "-sk", path], timeout)
        if rc == 0 {
            let pair = parseDuKB(out)
            if pair.1, pair.0 > 0 { return pair }
        }
    }
    return directoryByteSize(path, timeout: timeout)
}

public func spotlightFSSize(_ path: String, run: CommandRun = runCommand) -> Int? {
    let (rc, out, _) = run(["/usr/bin/mdls", "-name", "kMDItemFSSize", "-raw", path], 5)
    guard rc == 0 else { return nil }
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "(null)" { return nil }
    guard let n = Int(trimmed), n > 0 else { return nil }
    return n
}

func parseDuKB(_ out: String) -> (Int, Bool) {
    guard let first = out.split(whereSeparator: \.isWhitespace).first, let kb = Int(first), kb > 0 else {
        return (0, false)
    }
    let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
    if overflow { return (0, false) }
    return (bytes, true)
}

/// Batch `du -sk` for many directories: one spawn per chunk instead of one
/// per path. A full leftover scan spawns `du` hundreds of times (~50 ms each);
/// batching cuts that to a handful. Missing/error lines fall back to the
/// in-process walk, never to another spawn.
///
/// `du` separates size and path with a tab. Paths containing newlines cannot
/// round-trip through line parsing; unmatched lines fall back safely, but a
/// mangled fragment could theoretically collide with another queried path.
public func duSizes(
    _ paths: [String],
    timeout: TimeInterval = 8,
    run: CommandRun = runCommand
) -> [String: (Int, Bool)] {
    var out: [String: (Int, Bool)] = [:]
    var dirs: [String] = []
    for path in paths {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            out[path] = (0, false)
            continue
        }
        if !isDir.boolValue {
            out[path] = (fileSize(path), true)
            continue
        }
        dirs.append(path)
    }
    // Chunk well under ARG_MAX even for very long paths.
    for chunk in chunked(dirs, into: 128) {
        var missing = Set(chunk)
        for exe in ["/usr/bin/du", "du"] {
            let (rc, duOut, _) = run([exe, "-sk"] + chunk, timeout)
            if rc != 0, duOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            var parsedAny = false
            for raw in duOut.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let tab = raw.firstIndex(of: "\t") else { continue }
                guard let kb = Int(raw[..<tab]), kb > 0 else { continue }
                let p = String(raw[raw.index(after: tab)...])
                guard missing.contains(p) else { continue }
                let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
                guard !overflow else { continue }
                out[p] = (bytes, true)
                missing.remove(p)
                parsedAny = true
            }
            // The binary ran: leftovers are genuinely unreadable by du, so
            // fall back to the walk instead of retrying another binary.
            if parsedAny || rc == 0 { break }
        }
        for path in missing {
            out[path] = directoryByteSize(path, timeout: timeout)
        }
    }
    return out
}

/// Logical file bytes for a directory tree: sum of regular-file `st_size`,
/// symlinks not followed.
///
/// Uses `opendir`/`fstatat` rather than `FileManager.enumerator` +
/// `resourceValues`. On corelibs-foundation those populate owner names, which
/// costs an NSS lookup per entry (~0.5 ms here: `libnss_systemd` D-Bus round
/// trip), so a 2 300-file tree took 1.2 s instead of ~3 ms.
///
/// The Bool is "measured", not "complete": on a deadline overrun the total is
/// the partial sum of what was walked, so a caller must not present it as the
/// full size. It is also false when the path could not be read at all.
public func directoryByteSize(
    _ path: String,
    timeout: TimeInterval = 8,
    clock: MonotonicFn = monotonicSeconds
) -> (Int, Bool) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        return (0, false)
    }
    if !isDir.boolValue {
        return (fileSize(path), true)
    }
    let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard fd >= 0 else {
        return (0, false)
    }
    defer { close(fd) }
    var total = 0
    var sawError = false
    let complete = walkLogicalBytes(
        fd: fd,
        total: &total,
        sawError: &sawError,
        deadline: clock() + timeout,
        clock: clock
    )
    if !complete { return (total, false) }
    return (total, !sawError)
}

/// Returns false when the deadline passed before the tree was fully walked.
func walkLogicalBytes(
    fd: Int32,
    total: inout Int,
    sawError: inout Bool,
    deadline: TimeInterval,
    clock: MonotonicFn = monotonicSeconds
) -> Bool {
    if clock() > deadline { return false }
    let dupfd = dup(fd)
    guard dupfd >= 0 else {
        sawError = true
        return true
    }
    guard let dirp = fdopendir(dupfd) else {
        close(dupfd)
        sawError = true
        return true
    }
    defer { closedir(dirp) }
    while true {
        errno = 0
        guard let ent = readdir(dirp) else {
            if errno != 0 { sawError = true }
            break
        }
        guard let name = direntName(ent) else {
            // A name that is not UTF-8 has no byte-faithful path to descend.
            sawError = true
            continue
        }
        if name == "." || name == ".." { continue }
        var st = stat()
        guard name.withCString({ fstatat(fd, $0, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            sawError = true
            continue
        }
        let kind = Int32(st.st_mode) & Int32(S_IFMT)
        if kind == Int32(S_IFDIR) {
            let childFd = name.withCString { openat(fd, $0, childDirFlags) }
            if childFd < 0 {
                sawError = true
            } else {
                let complete = walkLogicalBytes(
                    fd: childFd,
                    total: &total,
                    sawError: &sawError,
                    deadline: deadline,
                    clock: clock
                )
                close(childFd)
                if !complete { return false }
            }
        } else if kind == Int32(S_IFREG) {
            total = addBytes(total, Int(st.st_size))
        }
        if clock() > deadline { return false }
    }
    return true
}
