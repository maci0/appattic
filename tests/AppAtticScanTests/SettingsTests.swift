import XCTest
@testable import AppAtticScan

final class SettingsTests: XCTestCase {
    func testMissingSettingsFileReturnsDefaults() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-missing-\(UUID().uuidString).json")
        let settings = loadSettings(from: url)
        XCTAssertFalse(settings.includeSystem)
        XCTAssertTrue(settings.confirmDelete)
        XCTAssertEqual(settings.ignoredLeftoverPaths, [])
    }

    func testSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = AppAtticSettings.default
        settings.includeSystem = true
        settings.confirmDelete = false
        settings = addIgnoredLeftover("/tmp/Foo", to: settings)
        settings = addIgnoredLeftover("/tmp/Foo", to: settings)
        settings = addIgnoredLeftover("/tmp/Bar", to: settings)
        saveSettings(settings, to: url)
        let loaded = loadSettings(from: url)
        XCTAssertTrue(loaded.includeSystem)
        XCTAssertFalse(loaded.confirmDelete)
        XCTAssertEqual(loaded.ignoredLeftoverPaths, ["/tmp/Foo", "/tmp/Bar"])
    }

    func testPartialSettingsJSONUsesDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-partial-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"includeSystem\":true}".utf8).write(to: url)
        let loaded = loadSettings(from: url)
        XCTAssertTrue(loaded.includeSystem)
        XCTAssertTrue(loaded.confirmDelete)
        XCTAssertEqual(loaded.ignoredLeftoverPaths, [])
    }

    func testVisibleOrphanedLeftoversHidesIgnoredPaths() {
        let leftovers = [
            LeftoverItem(name: "Foo", path: "/tmp/Foo", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
            LeftoverItem(name: "Bar", path: "/tmp/Bar", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 20),
            LeftoverItem(name: "Sys", path: "/tmp/Sys", root: "Caches", kind: "dir", status: "system", size_bytes: 30),
        ]
        let visible = visibleOrphanedLeftovers(leftovers, ignoring: ["/tmp/Foo"])
        XCTAssertEqual(visible.map(\.path), ["/tmp/Bar"])
    }

    func testAddIgnoredLeftoversRecordsEveryPathInGroup() {
        let item = LeftoverItem(
            name: "Whisky",
            path: "/tmp/Whisky",
            root: "Application Support",
            kind: "dir",
            status: "orphaned",
            extra_paths: ["/tmp/Whisky.plist", "/tmp/Containers/Whisky"]
        )
        let settings = addIgnoredLeftovers(leftoverIgnorePaths(item), to: .default)
        XCTAssertEqual(
            Set(settings.ignoredLeftoverPaths),
            ["/tmp/Whisky", "/tmp/Whisky.plist", "/tmp/Containers/Whisky"]
        )
    }

    func testVisibleOrphanedLeftoversHidesGroupWhenExtraPathIgnored() {
        let leftovers = [
            LeftoverItem(
                name: "Whisky",
                path: "/tmp/Whisky",
                root: "Application Support",
                kind: "dir",
                status: "orphaned",
                size_bytes: 100,
                extra_paths: ["/tmp/Whisky.plist"]
            ),
        ]
        XCTAssertTrue(visibleOrphanedLeftovers(leftovers, ignoring: []).map(\.path).contains("/tmp/Whisky"))
        XCTAssertTrue(visibleOrphanedLeftovers(leftovers, ignoring: ["/tmp/Whisky.plist"]).isEmpty)
        let data = sampleScanData(leftovers: leftovers)
        let script = cleanupScript(from: data, ignoringLeftovers: ["/tmp/Whisky.plist"])
        XCTAssertFalse(script.contains("/tmp/Whisky"))
    }

    func testClearIgnoredLeftovers() {
        var settings = AppAtticSettings.default
        settings = addIgnoredLeftover("/tmp/Foo", to: settings)
        settings = clearIgnoredLeftovers(settings)
        XCTAssertEqual(settings.ignoredLeftoverPaths, [])
    }

    func testPruneSelectionDropsGoneAndIgnored() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned"),
                LeftoverItem(name: "Hide", path: "/tmp/Hide", root: "Caches", kind: "dir", status: "orphaned"),
            ],
            software: [
                SoftwareItem(name: "App", kind: "app", path: "/Apps/App.app", source: "app", tier: "remove"),
            ],
            outdated: [
                OutdatedEntry(name: "jq", manager: "brew-formula"),
            ]
        )
        let pruned = pruneCleanupSelection(
            leftovers: ["/tmp/Keep", "/tmp/Hide", "/tmp/Gone"],
            apps: ["/Apps/App.app", "/Apps/Missing.app"],
            outdated: ["brew-formula:jq", "brew-formula:wget"],
            data: data,
            ignoring: ["/tmp/Hide"]
        )
        XCTAssertEqual(pruned.leftovers, Set(["/tmp/Keep"]))
        XCTAssertEqual(pruned.apps, Set(["/Apps/App.app"]))
        XCTAssertEqual(pruned.outdated, Set(["brew-formula:jq"]))
    }

    func testPruneSelectionDropsKeepTierAndNonUpdatableOutdated() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned"),
            ],
            software: [
                SoftwareItem(name: "KeepMe", kind: "app", path: "/Apps/Keep.app", source: "app", tier: "keep"),
                SoftwareItem(name: "ReviewMe", kind: "app", path: "/Apps/Review.app", source: "app", tier: "review"),
                SoftwareItem(name: "RemoveMe", kind: "app", path: "/Apps/Remove.app", source: "app", tier: "remove"),
            ],
            outdated: [
                OutdatedEntry(name: "jq", manager: "brew-formula"),
                OutdatedEntry(name: "sketchy", manager: "brew-cask", kind: "untrusted"),
                OutdatedEntry(name: "Pages", manager: "app-store"),
            ]
        )
        let pruned = pruneCleanupSelection(
            leftovers: ["/tmp/Keep"],
            apps: ["/Apps/Keep.app", "/Apps/Review.app", "/Apps/Remove.app"],
            outdated: ["brew-formula:jq", "brew-cask:sketchy", "app-store:Pages"],
            data: data,
            ignoring: []
        )
        XCTAssertEqual(pruned.leftovers, Set(["/tmp/Keep"]))
        XCTAssertEqual(pruned.apps, Set(["/Apps/Review.app", "/Apps/Remove.app"]))
        XCTAssertEqual(pruned.outdated, Set(["brew-formula:jq"]))
    }

    func testResolvedSelectionFallsBackWhenHidden() {
        XCTAssertEqual(resolvedSelection("gone", visibleIds: ["a", "b"]), "a")
        XCTAssertEqual(resolvedSelection("b", visibleIds: ["a", "b"]), "b")
        XCTAssertNil(resolvedSelection("gone", visibleIds: []))
        XCTAssertEqual(resolvedSelection(nil, visibleIds: ["a"]), "a")
    }

    func testCommandFailureMessageIncludesStderr() {
        XCTAssertEqual(
            commandFailureMessage(status: 1, stderr: ""),
            "Command failed (exit 1). Selection kept."
        )
        XCTAssertEqual(
            commandFailureMessage(status: 2, stderr: "  brew: no such keg  "),
            "Command failed (exit 2). brew: no such keg"
        )
    }

    func testCleanupScriptSkipsIgnoredLeftovers() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned"),
                LeftoverItem(name: "Hide", path: "/tmp/Hide", root: "Caches", kind: "dir", status: "orphaned"),
            ]
        )
        let script = cleanupScript(from: data, ignoringLeftovers: ["/tmp/Hide"])
        XCTAssertTrue(script.contains("/tmp/Keep"))
        XCTAssertFalse(script.contains("/tmp/Hide"))
    }

    func testExportedScanDataDropsIgnoredLeftovers() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
                LeftoverItem(name: "Hide", path: "/tmp/Hide", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 20),
            ]
        )
        let exported = exportedScanData(from: data, ignoringLeftovers: ["/tmp/Hide"], fromCache: true)
        XCTAssertEqual(exported.leftovers.map(\.path), ["/tmp/Keep"])
        XCTAssertEqual(exported.totals.orphaned_items, 1)
        XCTAssertEqual(exported.totals.orphaned_bytes, 10)
        XCTAssertEqual(exported.from_cache, true)
    }

    func testExportedScanDataKeepsAppsInstalledCount() {
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
            brew_available: false,
            totals: ScanTotals(
                apps_installed: 7,
                orphaned_items: 1,
                orphaned_bytes: 10,
                system_leftover_bytes: 0,
                reclaimable_bytes: 10,
                stale_apps: 0,
                outdated_apps: 0
            ),
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
            ],
            software: [
                SoftwareItem(name: "Foo", kind: "app", path: "/Apps/Foo.app", source: "app"),
            ]
        )
        let exported = exportedScanData(from: data, ignoringLeftovers: [], fromCache: false)
        XCTAssertEqual(exported.totals.apps_installed, 7)
        XCTAssertEqual(exported.leftovers.count, 1)
    }

    func testToggleListedSelectionDeselectClearsWholeSet() {
        let selected: Set = ["/a", "/b", "/c"]
        XCTAssertEqual(toggleListedSelection(selected: selected, visible: ["/a"]), [])
        XCTAssertEqual(toggleListedSelection(selected: ["/a"], visible: ["/a", "/b"]), ["/a", "/b"])
    }

    func testScanResultRestoresVersionFromCurrentVersion() {
        let data = sampleScanData(
            software: [
                SoftwareItem(
                    name: "jq",
                    kind: "formula",
                    path: "/opt/homebrew/bin/jq",
                    source: "brew-formula",
                    current_version: "1.7"
                ),
            ]
        )
        let result = scanResult(from: data)
        XCTAssertEqual(result.software[0].version, "1.7")
    }

    func testVisibleStaleSoftwareIncludesSystemWhenAsked() {
        let items = [
            SoftwareItem(name: "Idle", kind: "app", path: "/Apps/Idle.app", source: "app", tier: "review"),
            SoftwareItem(name: "Safari", kind: "app", path: "/Apps/Safari.app", source: "system", tier: "system"),
            SoftwareItem(name: "Keep", kind: "app", path: "/Apps/Keep.app", source: "app", tier: "keep"),
        ]
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: false).map(\.name), ["Idle"])
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: true).map(\.name), ["Idle", "Safari"])
    }

    func testRemainingCommentOnlyAppPathsKeepsSteamGuidance() {
        let leftover = SoftwareItem(name: "Foo", kind: "app", path: "/Apps/Foo.app", source: "app", tier: "remove")
        let steam = SoftwareItem(name: "EmuDevz", kind: "app", path: "/tmp/steamapps/common/EmuDevz", source: "steam", tier: "remove")
        let kept = remainingCommentOnlyAppPaths(
            selected: [leftover.path, steam.path],
            software: [leftover, steam]
        )
        XCTAssertEqual(kept, [steam.path])
    }

    func testRemainingPendingAppPathsKeepsSteamHandoff() {
        let leftover = SoftwareItem(name: "Foo", kind: "app", path: "/Apps/Foo.app", source: "app", tier: "remove")
        let steam = SoftwareItem(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/steamapps/common/EmuDevz",
            source: "steam",
            tier: "remove",
            steam_appid: "4260720"
        )
        XCTAssertTrue(isHandoffUninstallCommand(uninstallCommand(
            source: steam.source,
            name: steam.name,
            path: steam.path,
            caskName: nil,
            steamAppId: steam.steam_appid
        )))
        let kept = remainingPendingAppPaths(
            selected: [leftover.path, steam.path],
            software: [leftover, steam]
        )
        XCTAssertEqual(kept, [steam.path])
    }

    func testVisibleStaleCountIncludesSystemWhenAsked() {
        let items = [
            SoftwareItem(name: "Idle", kind: "app", path: "/Apps/Idle.app", source: "app", tier: "review"),
            SoftwareItem(name: "Safari", kind: "app", path: "/Apps/Safari.app", source: "system", tier: "system"),
        ]
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: true).count, 2)
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: false).count, 1)
    }
}

final class ResolveScanTests: XCTestCase {
    func testUsesCacheWhenFreshAndFingerprintMatch() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cached = sampleScanData(scannedAt: "2026-08-17T12:00:00Z")
        saveScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: cached), to: cacheURL)
        var liveCalls = 0
        let resolved = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in
                liveCalls += 1
                return sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
            }
        )
        XCTAssertEqual(liveCalls, 0)
        XCTAssertTrue(resolved.fromCache)
        XCTAssertEqual(resolved.data.scanned_at, "2026-08-17T12:00:00Z")
        XCTAssertEqual(resolved.data.from_cache, true)
    }

    func testFreshOrForceLiveSkipsCache() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-fresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        saveScanCache(
            ScanCacheFile(fingerprint: "fp", includeSystem: false, data: sampleScanData(scannedAt: "2026-08-17T12:00:00Z")),
            to: cacheURL
        )
        var liveCalls = 0
        let live = sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
        let fresh = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in
                liveCalls += 1
                return live
            }
        )
        XCTAssertEqual(liveCalls, 1)
        XCTAssertFalse(fresh.fromCache)
        XCTAssertEqual(fresh.data.scanned_at, "2026-08-17T13:00:00Z")

        liveCalls = 0
        let update = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: true,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in
                liveCalls += 1
                return live
            }
        )
        XCTAssertEqual(liveCalls, 1)
        XCTAssertFalse(update.fromCache)
    }

    func testStaleCacheRunsLiveScanAndSaves() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-stale-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        saveScanCache(
            ScanCacheFile(fingerprint: "old", includeSystem: false, data: sampleScanData(scannedAt: "2026-08-17T12:00:00Z")),
            to: cacheURL
        )
        let live = sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
        let resolved = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "new" },
            liveScan: { _ in live }
        )
        XCTAssertFalse(resolved.fromCache)
        let saved = try XCTUnwrap(loadScanCache(from: cacheURL))
        XCTAssertEqual(saved.fingerprint, "new")
        XCTAssertEqual(saved.data.scanned_at, "2026-08-17T13:00:00Z")
    }
}

func sampleScanData(
    scannedAt: String = "2026-08-17T12:00:00Z",
    leftovers: [LeftoverItem] = [],
    software: [SoftwareItem] = [],
    outdated: [OutdatedEntry] = [],
    packages: [PackageEntry] = []
) -> ScanData {
    ScanData(
        scanned_at: scannedAt,
        duration_s: 1,
        brew_available: false,
        totals: ScanTotals(
            apps_installed: 0,
            orphaned_items: leftovers.filter { $0.status == "orphaned" }.count,
            orphaned_bytes: leftovers.reduce(0) { $0 + ($1.size_bytes ?? 0) },
            system_leftover_bytes: 0,
            reclaimable_bytes: leftovers.reduce(0) { $0 + ($1.size_bytes ?? 0) },
            stale_apps: 0,
            outdated_apps: outdated.count
        ),
        leftovers: leftovers,
        software: software,
        outdated: outdated,
        packages: packages
    )
}
