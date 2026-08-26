import XCTest
@testable import AppAtticScan

final class ModelTests: XCTestCase {
    func testLeftoverJSONRoundTrip() throws {
        let item = LeftoverItem(
            name: "Foo",
            path: "/tmp/Foo",
            root: "Caches",
            kind: "dir",
            status: "orphaned",
            owner: nil,
            size_bytes: 12,
            size_measured: true,
            mtime: "2026-08-17T00:00:00Z",
            reason: "No installed app claims this Caches data.",
            summary: "Caches folder named Foo"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LeftoverItem.self, from: data)
        XCTAssertEqual(decoded.name, "Foo")
        XCTAssertEqual(decoded.reason, item.reason)
        XCTAssertEqual(decoded.summary, item.summary)
    }

    func testLeftoverJSONMtimePrefersNestedActivity() {
        let folder = Date(timeIntervalSince1970: 1_700_000_000)
        let nested = Date(timeIntervalSince1970: 1_750_000_000)
        let item = DataItem(
            path: "/tmp/Foo",
            name: "Foo",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            mtime: folder,
            activityMtime: nested
        )
        XCTAssertEqual(item.toLeftoverItem().mtime, isoString(nested))
    }
}
