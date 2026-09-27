import XCTest
import AppAtticScan

/// The README quickstart, compiled. The import is deliberately not `@testable`:
/// a documented call that only resolves inside the module is not public API.
final class PublicAPITests: XCTestCase {
    private let item = LeftoverItem(
        name: "python3",
        path: "/home/u/.local/bin/python3",
        root: ".local/bin",
        kind: "file",
        status: "shadow",
        shadows: "/usr/bin/python3"
    )

    func testQuickstartResolvesAgainstExportedSymbols() throws {
        let leftovers = visibleOrphanedLeftovers([item], ignoring: [])
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertEqual(leftovers[0].leftoverStatus, .shadow)
        XCTAssertEqual(leftovers[0].shadows, "/usr/bin/python3")

        XCTAssertNotNil(parseCLIArguments(["--top", "-1"]).parseError)
        XCTAssertEqual(scanCacheMaxAge, 24 * 3600)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-public-api-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeScanCache(
            ScanCacheFile(fingerprint: "ver:test", includeSystem: false, data: emptyScanData()),
            to: url
        )
        XCTAssertEqual(try readScanCache(from: url).fingerprint, "ver:test")
    }

    func testRunFullScanAcceptsTrailingProgressClosure() {
        // Referenced, not run: a live scan reads the real machine. Binding the
        // closure to the documented signature is the assertion; the type system
        // rejects the test at build time if either label or arity drifts.
        let scan: (Bool, @escaping (String) -> Void) -> ScanData = { includeSystem, progress in
            runFullScan(includeSystem: includeSystem, progress: progress)
        }
        withExtendedLifetime(scan) {}
    }

    func testTypedAccessorsResolveWithoutTestableImport() {
        XCTAssertEqual(item.leftoverStatus, .shadow)
        XCTAssertTrue(item.isListedLeftover)
        XCTAssertEqual(item.totalBytes, 0)
        XCTAssertEqual(
            SoftwareItem(name: "Foo", kind: "app", path: "/tmp/Foo.app", source: "mac", tier: "remove").tierKind,
            .remove
        )
        XCTAssertEqual(
            OutdatedEntry(name: "foo", manager: "flatpak", kind: "outdated").upgradableManager,
            .flatpak
        )
        let sw = Software(name: "Foo", kind: "app", path: "/tmp/Foo.app", source: "mac")
        XCTAssertEqual(Verdict(software: sw, tier: "review").tierKind, .review)
        XCTAssertTrue(StaleTier.isSelectable(.remove))
        XCTAssertFalse(StaleTier.isSelectable(.keep))
        XCTAssertTrue(StaleTier.system.isVisibleStale(includeSystem: true))
        XCTAssertFalse(StaleTier.system.isVisibleStale(includeSystem: false))
    }

    private func emptyScanData() -> ScanData {
        ScanData(
            scanned_at: "",
            duration_s: 0,
            brew_available: false,
            totals: ScanTotals(
                apps_installed: 0,
                orphaned_items: 0,
                orphaned_bytes: 0,
                system_leftover_bytes: 0,
                reclaimable_bytes: 0,
                stale_apps: 0,
                outdated_apps: 0
            ),
            leftovers: [],
            software: []
        )
    }
}
