import Foundation
public func restrictOwnerOnlyFile(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

public func restrictOwnerOnlyDirectory(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Owner-only mode on a private data file. If the parent directory is named
/// `appattic`, that directory is owner-only as well. Other parents are left alone.
public func restrictPrivateDataFile(at url: URL) throws {
    try restrictOwnerOnlyFile(at: url)
    let dir = url.deletingLastPathComponent()
    if dir.lastPathComponent.posixLowercased() == "appattic" {
        try restrictOwnerOnlyDirectory(at: dir)
    }
}

public func writeOwnerOnlyFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try restrictOwnerOnlyFile(at: url)
}
