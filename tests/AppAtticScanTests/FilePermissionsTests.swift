import XCTest
@testable import AppAtticScan

final class FilePermissionsTests: XCTestCase {
    func testRestrictOwnerOnlyClearsGroupAndOtherBits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-mode-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try restrictOwnerOnlyFile(at: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertNotEqual(mode, -1)
        XCTAssertEqual(mode & 0o077, 0)
        XCTAssertEqual(mode & 0o600, 0o600)
    }


    func testWriteOwnerOnlyFileIsOwnerReadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owner-only-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOwnerOnlyFile(Data("secret".utf8), to: url)
        XCTAssertEqual(try mode(of: url) & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "secret")
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// The state directory is the one parent the app owns, so it is created
    /// and then tightened. The mode is asserted, not the call: a
    /// `prepareStateDirectory` that never restricted the directory would
    /// otherwise leave the cache readable by every user on the machine.
    func testPrepareStateDirectoryLocksDownTheAppStateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-\(UUID().uuidString)")
            .appendingPathComponent("appattic")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try prepareStateDirectory(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(try mode(of: dir) & 0o777, 0o700)
    }

    /// Any other parent is not the app's to change, so its mode is left as it
    /// was. The starting mode is set rather than inherited, because the umask
    /// on the machine running the test would otherwise decide the answer.
    func testPrepareStateDirectoryLeavesAForeignParentAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-foreign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        try prepareStateDirectory(dir)
        XCTAssertEqual(try mode(of: dir) & 0o777, 0o755)
    }

    /// A private data file inside the state directory is unreadable by anyone
    /// but its owner, and so is the directory holding it.
    func testRestrictPrivateDataFileLocksDownTheStateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-\(UUID().uuidString)")
            .appendingPathComponent("appattic")
        let file = dir.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try prepareStateDirectory(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try writeOwnerOnlyFile(Data("{}".utf8), to: file)

        try restrictPrivateDataFile(at: file)
        XCTAssertEqual(try mode(of: file) & 0o777, 0o600)
        XCTAssertEqual(try mode(of: dir) & 0o777, 0o700)
    }

    func testWriteOwnerOnlyFileNarrowsAnExistingWorldReadableTarget() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("existing-\(UUID().uuidString).txt")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOwnerOnlyFile(Data("new".utf8), to: url)
        let mode = try mode(of: url)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
    }

    func testWriteOwnerOnlyFileLeavesNoTempFileBehind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeOwnerOnlyFile(Data("payload".utf8), to: dir.appendingPathComponent("out.txt"))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["out.txt"])
    }
}
