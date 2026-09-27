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
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "secret")
    }
}
