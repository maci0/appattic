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

    /// Every row of the README entry-point table, called with the labels the
    /// table prints. A row that renames, reorders, or drops a label stops the
    /// test target from building, which is the point: the table is the contract
    /// a consumer copies from.
    func testDocumentedEntryPointsResolve() throws {
        let data = emptyScanData(scannedAt: "2026-08-17T12:00:00Z")
        let now = Date(timeIntervalSince1970: 1_786_968_000)

        let result = scanResult(from: data, ignoringLeftovers: [], now: now)
        XCTAssertEqual(result.scannedAt, now)
        XCTAssertTrue(cleanupScript(from: data, ignoringLeftovers: [], now: now).hasPrefix("#!/bin/sh"))
        XCTAssertTrue(updateScript(from: data, selectedIds: []).contains("Nothing to update"))
        let exported = exportedScanData(from: data, ignoringLeftovers: [], fromCache: true, now: now)
        XCTAssertEqual(exported.from_cache, true)

        let cache = ScanCacheFile(fingerprint: "ver:test", includeSystem: false, data: data)
        XCTAssertFalse(isScanCacheStale(cache, includeSystem: false, fingerprint: "ver:test", now: now, maxAge: scanCacheMaxAge))
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: true, fingerprint: "ver:test", now: now, maxAge: scanCacheMaxAge))
        XCTAssertFalse(scanFingerprint(which: { _ in nil }, run: { _, _ in (1, "", "") }).isEmpty)
        XCTAssertFalse(appAtticVersion.isEmpty)

        let settings = AppAtticSettings(includeSystem: true, confirmDelete: false, ignoredLeftoverPaths: ["/tmp/Hide"])
        XCTAssertTrue(effectiveIncludeSystem(cliFlag: false, settings: settings))
        XCTAssertFalse(effectiveIncludeSystem(cliFlag: false, settings: .default))
        XCTAssertEqual(AppAtticSettings.default.confirmDelete, true)
        XCTAssertFalse(settingsErrorUserMessage(SettingsError.invalid(path: "/x", reason: "y")).isEmpty)
        XCTAssertFalse(cliHelpText.isEmpty)
        XCTAssertFalse(cliUsageHint.isEmpty)
    }

    func testDocumentedCacheEntryPointsResolve() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-resolve-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_786_968_000)
        let data = emptyScanData(scannedAt: "2026-08-17T12:00:00Z")

        let live = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: false,
            cacheURL: url,
            now: now,
            fingerprintFn: { "ver:test" },
            liveScan: { _ in data }
        )
        XCTAssertFalse(live.fromCache)
        XCTAssertNil(live.cacheWriteFailure)
        XCTAssertEqual(try readScanCache(from: url).fingerprint, "ver:test")

        let cached = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: url,
            now: now,
            fingerprintFn: { "ver:test" },
            liveScan: { _ in
                XCTFail("a current cache must not trigger a live scan")
                return data
            }
        )
        XCTAssertTrue(cached.fromCache)
        XCTAssertNotNil(loadScanCache(from: url))
        XCTAssertNotNil(try? readScanCache(from: url))
    }

    func testDocumentedDiskEntryPointsResolve() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.bin")
        try Data(repeating: 7, count: 64).write(to: file)

        XCTAssertNoThrow(try validateDiskRoot(root.path))
        var caught: DiskRootError?
        XCTAssertThrowsError(try validateDiskRoot(file.path)) { caught = $0 as? DiskRootError }
        XCTAssertEqual(caught, DiskRootError.notADirectory(path: file.path))
        let node = scanDiskUsage(root: root.path, oneFileSystem: true, cancel: { false })
        XCTAssertEqual(node.name, root.lastPathComponent)
        XCTAssertEqual(node.children.map(\.name), ["one.bin"])
        XCTAssertTrue(formatDiskTree(node, allocatedSize: true, top: nil, depth: 0).contains("one.bin"))
        XCTAssertEqual(diskTreeHiddenEntries(node, top: 0), 1)
        XCTAssertTrue(String(decoding: try diskUsageJSON(node), as: UTF8.self).contains("one.bin"))
        // `mountsText` is the Linux mount table; Darwin reads the real one, so
        // only the shape is asserted there.
        for volume in listDiskVolumes(home: root.path, mountsText: "") {
            XCTAssertFalse(volume.rootPath.isEmpty)
        }
    }

    func testDocumentedErrorTypesCarryACaseAndAMessage() {
        XCTAssertEqual(
            AppAtticIOError.readFailed(path: "/x", message: "y").description,
            "Could not read /x: y"
        )
        let errors: [Error] = [
            AppAtticIOError.encodeFailed(message: "y"),
            SettingsError.unreadable(path: "/x", reason: "y"),
            DiskRootError.missing(path: "/x"),
            CLIParseError.conflictingFilters,
        ]
        for error in errors {
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    private func emptyScanData(scannedAt: String = "") -> ScanData {
        ScanData(
            scanned_at: scannedAt,
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
