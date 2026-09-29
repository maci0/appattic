import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The one directory the app owns end to end. A state file under it is
/// private, so the directory gets owner-only mode too; any other parent is
/// left alone, because the app does not own it.
private let appStateDirectoryName = "appattic"

private func isAppStateDirectory(_ dir: URL) -> Bool {
    dir.lastPathComponent.posixLowercased() == appStateDirectoryName
}

public func restrictOwnerOnlyFile(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

public func restrictOwnerOnlyDirectory(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Makes `dir` exist, owner-only when it is the app's own state directory. A
/// state file's parent has to be ready and locked down before the file is
/// written, so callers do this first rather than after.
///
/// An existing entry is left to the caller: when it is a directory there is
/// nothing to make, and when it is a file this is not a directory-creation
/// failure to report. The write that follows fails on the real reason, which
/// names the file the caller asked for instead of its parent.
public func prepareStateDirectory(_ dir: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) {
        // Something is already there. A directory is ready as it stands; a
        // file is the caller's own problem, and the write that follows names
        // it. Either way this is not a directory-creation failure, and
        // `createDirectory` would report the file as one.
        guard isDirectory.boolValue else { return }
    } else {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    if isAppStateDirectory(dir) {
        try restrictOwnerOnlyDirectory(at: dir)
    }
}

/// Owner-only mode on a private data file. If the parent directory is the app's
/// own, that directory is owner-only as well. Other parents are left alone.
public func restrictPrivateDataFile(at url: URL) throws {
    try restrictOwnerOnlyFile(at: url)
    let dir = url.deletingLastPathComponent()
    if isAppStateDirectory(dir) {
        try restrictOwnerOnlyDirectory(at: dir)
    }
}

/// Write `data` to `url` with owner-only mode, with no window in which the
/// content is readable by anyone else.
///
/// `Data.write(options: .atomic)` renames a file that was created at the umask
/// default (`0644` under the usual `022`), and the `0600` only arrives on the
/// next statement. The payload is private (a generated script listing the
/// account's paths, an exported scan), and the destinations include the
/// world-writable shared temp directory, so that window is readable by every
/// local account. `mkstemp` creates at `0600` and fails if the name is taken,
/// and `rename` puts the result in place atomically, so a reader sees either no
/// file or the final private one.
public func writeOwnerOnlyFile(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    let template = dir.appendingPathComponent(".appattic-\(UUID().uuidString).XXXXXX")
    var nameBytes = Array(template.path.utf8CString)
    let fd: Int32 = nameBytes.withUnsafeMutableBufferPointer { buf -> Int32 in
        guard let base = buf.baseAddress else { return -1 }
        return mkstemp(base)
    }
    guard fd >= 0 else {
        throw AppAtticIOError.writeFailed(path: url.path, message: String(cString: strerror(errno)))
    }
    let finalName = String(decoding: nameBytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    defer { close(fd) }
    do {
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw AppAtticIOError.writeFailed(
                        path: url.path,
                        message: String(cString: strerror(errno))
                    )
                }
                written += n
            }
        }
    } catch {
        unlink(finalName)
        throw error
    }
    // The data has to reach the disk before the name does: a rename publishes
    // the file while its contents are still in the page cache, so a crash
    // between the two leaves a complete, correctly named file holding a
    // truncated write. The two callers that publish over a previous file (the
    // scan cache and the settings) replace it entirely, so a half-written one
    // is not a recoverable state; the script temp files and a `--json` export
    // are new paths, where a failed write leaves nothing rather than a
    // truncated file.
    if fsync(fd) != 0 {
        let message = String(cString: strerror(errno))
        unlink(finalName)
        throw AppAtticIOError.writeFailed(path: url.path, message: message)
    }
    guard rename(finalName, url.path) == 0 else {
        let message = String(cString: strerror(errno))
        unlink(finalName)
        throw AppAtticIOError.writeFailed(path: url.path, message: message)
    }
    // The rename is its own commit point: the directory entry that names the
    // new file is in the page cache until the directory itself is written out.
    // A crash after the fsync above and before this one can leave the
    // destination as it was before the write, or with no entry at all, which
    // for `settings.json` is the only copy of the ignore list gone.
    //
    // A failure here is not the file's failure to write: the bytes are on disk
    // and the name resolves, so the caller has what it wrote. Reporting it
    // would make a durable write look like a failed one and lose the
    // distinction the caller acts on, so it is not reported. `open` on a
    // directory with `O_RDONLY` fails on a filesystem that cannot fsync one
    // (some network mounts), and there the rename is as durable as that
    // filesystem can make it.
    let dirFD = open(dir.path, O_RDONLY)
    if dirFD >= 0 {
        _ = fsync(dirFD)
        close(dirFD)
    }
}
