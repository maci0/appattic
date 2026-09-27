import Foundation

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
public func prepareStateDirectory(_ dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

public func writeOwnerOnlyFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try restrictOwnerOnlyFile(at: url)
}
