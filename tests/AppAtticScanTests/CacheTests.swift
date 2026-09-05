import XCTest
@testable import AppAtticScan

final class CacheTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1.5,
            brew_available: true,
            totals: ScanTotals(
                apps_installed: 2,
                orphaned_items: 1,
                orphaned_bytes: 10,
                system_leftover_bytes: 0,
                reclaimable_bytes: 10,
                stale_apps: 0,
                outdated_apps: 0
            ),
            leftovers: [
                LeftoverItem(
                    name: "Foo",
                    path: "/tmp/Foo",
                    root: "Caches",
                    kind: "dir",
                    status: "orphaned",
                    size_bytes: 10,
                    size_measured: true
                ),
            ],
            software: [],
            outdated: [],
            from_cache: true
        )
        saveScanCache(ScanCacheFile(fingerprint: "fp1", includeSystem: false, data: data), to: url)
        let loaded = try XCTUnwrap(loadScanCache(from: url))
        XCTAssertEqual(loaded.fingerprint, "fp1")
        XCTAssertFalse(loaded.includeSystem)
        XCTAssertEqual(loaded.data.scanned_at, data.scanned_at)
        XCTAssertEqual(loaded.data.leftovers, data.leftovers)
        XCTAssertEqual(loaded.data.leftovers[0].name, "Foo")
        XCTAssertEqual(loaded.data.leftovers[0].path, "/tmp/Foo")
        XCTAssertEqual(loaded.data.leftovers[0].status, "orphaned")
        XCTAssertEqual(loaded.data.leftovers[0].size_bytes, 10)
        XCTAssertEqual(loaded.data.from_cache, false)
        let mode = posixMode(url.path)
        XCTAssertNotEqual(mode, -1)
        XCTAssertEqual(mode & 0o077, 0)
    }

    func testStaleWhenFingerprintOrIncludeSystemOrAgeChanges() {
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
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
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        let now = parseISODate("2026-08-17T12:30:00Z")!
        XCTAssertFalse(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: now, maxAge: 3600))
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "b", now: now, maxAge: 3600))
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: true, fingerprint: "a", now: now, maxAge: 3600))
        let later = parseISODate("2026-08-18T12:30:00Z")!
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: later, maxAge: 3600))
        let clockMovedBack = parseISODate("2026-08-17T11:30:00Z")!
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: clockMovedBack, maxAge: 3600))
    }

    func testMissingCacheFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-missing-\(UUID().uuidString).json")
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertThrowsError(try readScanCache(from: url)) { error in
            guard case AppAtticIOError.readFailed = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
        }
    }

    func testWriteScanCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
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
        try writeScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: data), to: url)
        let loaded = try readScanCache(from: url)
        XCTAssertEqual(loaded.fingerprint, "fp")
        XCTAssertEqual(loaded.data.scanned_at, data.scanned_at)
        XCTAssertEqual(loaded.data.from_cache, false)
    }

    func testWriteScanCacheRestrictsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-perm-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("appattic")
        let url = dir.appendingPathComponent("last-scan.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
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
            leftovers: [
                LeftoverItem(
                    name: "Foo",
                    path: "/home/alice/.cache/Foo",
                    root: "Caches",
                    kind: "dir",
                    status: "orphaned"
                ),
            ],
            software: []
        )
        try writeScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: data), to: url)
        let fileMode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        let dirMode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(dirMode & 0o777, 0o700)
    }

    func testFingerprintIncludesAppVersion() {
        let fp = scanFingerprint(which: { _ in nil }, run: { _, _ in (1, "", "") })
        XCTAssertTrue(fp.contains("ver:\(appAtticVersion)"), fp)
        XCTAssertTrue(fp.contains("eval:20"), fp)
        XCTAssertTrue(fp.contains("packages:1"), fp)
    }

    func testFingerprintInventoryIncludesHomeLeavesAndSystemAgents() {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let fp = scanFingerprint(which: { _ in nil }, run: { _, _ in (1, "", "") })
        XCTAssertTrue(fp.contains("home-.mozilla"), fp)
        XCTAssertTrue(fp.contains("launchagents-system"), fp)
        XCTAssertFalse(fp.contains("brew-f:"), fp)
        XCTAssertFalse(fp.contains("mas:"), fp)
    }

    func testUserToolDirStampsSkipsEmptyAndHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-stamps-\(UUID().uuidString)")
        let local = root.appendingPathComponent("local")
        let usr = root.appendingPathComponent("usr")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usr, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: local.appendingPathComponent("herdr"))
        try Data("x".utf8).write(to: usr.appendingPathComponent("huginn"))
        try Data("x".utf8).write(to: usr.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(
            atPath: usr.appendingPathComponent("gone").path,
            withDestinationPath: "no-such-target"
        )
        let lines = userToolDirStamps([
            ("localbin", local.path),
            ("usrlocalbin", usr.path),
            ("missing", root.appendingPathComponent("nope").path),
        ])
        XCTAssertEqual(lines, ["localbin:herdr", "usrlocalbin:gone?,huginn"])
    }

    func testDirNameStampListsNonHiddenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("herdr"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden"))
        XCTAssertEqual(dirNameStamp("localbin", dir.path), "localbin:herdr")
        XCTAssertEqual(dirNameStamp("localbin", dir.appendingPathComponent("missing").path), "")
    }

    func testFingerprintStampsWineAndBrewPrefixBin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fp-tools-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: bin.appendingPathComponent("mytool"))
        try Data("x".utf8).write(to: bin.appendingPathComponent("brew"))
        let fp = scanFingerprint(
            which: { name in
                switch name {
                case "brew": return bin.appendingPathComponent("brew").path
                case "wine": return "/usr/bin/wine"
                default: return nil
                }
            },
            run: { _, _ in (1, "", "") }
        )
        XCTAssertTrue(fp.contains("path:wine"), fp)
        XCTAssertFalse(fp.contains("path:docker"), fp)
        XCTAssertTrue(fp.contains("brewbin:brew,mytool") || fp.contains("brewbin:mytool,brew"), fp)
    }

    func testLinuxPkgStampPathsCoverNativeManagers() {
        let labels = Set(linuxPkgStampPaths(home: "/home/u", env: [:]).map(\.0))
        XCTAssertTrue(labels.contains("pacman"), "\(labels)")
        XCTAssertTrue(labels.contains("dnf"), "\(labels)")
        XCTAssertTrue(labels.contains("rpm"), "\(labels)")
        XCTAssertTrue(labels.contains("zypp"), "\(labels)")
        XCTAssertTrue(labels.contains("dpkg"), "\(labels)")
        XCTAssertTrue(labels.contains("flatpak-user"), "\(labels)")
        let paths = Dictionary(uniqueKeysWithValues: linuxPkgStampPaths(home: "/home/u", env: [:]))
        XCTAssertEqual(paths["pacman"], "/var/lib/pacman/local")
        XCTAssertEqual(paths["flatpak-user"], "/home/u/.local/share/flatpak")
        let xdg = Dictionary(uniqueKeysWithValues: linuxPkgStampPaths(
            home: "/home/u",
            env: ["XDG_DATA_HOME": "/tmp/myshare"]
        ))
        XCTAssertEqual(xdg["flatpak-user"], "/tmp/myshare/flatpak")
        XCTAssertEqual(xdg["pacman"], "/var/lib/pacman/local")
    }

    func testPathMtimeStampSkipsMissingAndRecordsEpoch() throws {
        XCTAssertEqual(pathMtimeStamp("flatpak-user", "/nope/appattic-missing-flatpak"), "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtime-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = pathMtimeStamp("flatpak-user", dir.path)
        XCTAssertTrue(line.hasPrefix("flatpak-user:"), line)
        XCTAssertFalse(line.contains("missing"), line)
        XCTAssertNotNil(Int(line.split(separator: ":").last ?? ""), line)
    }

    func testAndroidSdkStampWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-stamp-\(UUID().uuidString)")
        let sdk = root.appendingPathComponent("Android")
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("emulator"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(androidSdkStamp(sdkDirs: [sdk.path]), "android-sdk")
        XCTAssertEqual(androidSdkStamp(sdkDirs: [root.appendingPathComponent("empty").path]), "")
    }

    func testRootInventoryStampIgnoresNestedWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("root-stamp-\(UUID().uuidString)")
        let alpha = dir.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = rootInventoryStamp("Caches", dir.path)
        XCTAssertEqual(first, "root:Caches:Alpha")
        try Data("nested".utf8).write(to: alpha.appendingPathComponent("inside.txt"))
        XCTAssertEqual(rootInventoryStamp("Caches", dir.path), first)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Beta"), withIntermediateDirectories: true)
        XCTAssertEqual(rootInventoryStamp("Caches", dir.path), "root:Caches:Alpha,Beta")
        XCTAssertEqual(rootInventoryStamp("Caches", dir.appendingPathComponent("missing").path), "root:Caches:missing")
    }

    func testStampJoinEscapesCommaAndNewline() {
        XCTAssertEqual(stampEscape("Alpha,Beta"), "Alpha\\,Beta")
        XCTAssertEqual(stampEscape("a\\b"), "a\\\\b")
        XCTAssertEqual(stampEscape("wget 1\ncurl 2"), "wget 1\\ncurl 2")
        XCTAssertEqual(stampJoin(["Alpha", "Beta"]), "Alpha,Beta")
        XCTAssertEqual(stampJoin(["Alpha,Beta"]), "Alpha\\,Beta")
        XCTAssertNotEqual(stampJoin(["Alpha,Beta"]), stampJoin(["Alpha", "Beta"]))
    }

    func testRootInventoryStampEscapesCommaInName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("root-comma-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Alpha,Beta"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(rootInventoryStamp("Caches", dir.path), "root:Caches:Alpha\\,Beta")
    }

    func testIncompleteCacheIsAlwaysStale() {
        var data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
            brew_available: true,
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
            software: [],
            incomplete: true
        )
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        let now = parseISODate("2026-08-17T12:30:00Z")!
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: now, maxAge: 3600))
        data.incomplete = nil
        let complete = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        XCTAssertFalse(isScanCacheStale(complete, includeSystem: false, fingerprint: "a", now: now, maxAge: 3600))
    }

    func testCommitScanCacheSkipsWhenFingerprintMovesOrIncomplete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-commit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
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
        XCTAssertFalse(commitScanCache(includeSystem: false, data: data, before: "a", after: "b", to: url))
        XCTAssertNil(loadScanCache(from: url))
        var incomplete = data
        incomplete.incomplete = true
        XCTAssertFalse(commitScanCache(includeSystem: false, data: incomplete, before: "a", after: "a", to: url))
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertTrue(commitScanCache(includeSystem: false, data: data, before: "a", after: "a", to: url))
        let saved = try XCTUnwrap(loadScanCache(from: url))
        XCTAssertEqual(saved.fingerprint, "a")
    }

    func testClearScanCacheRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
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
        saveScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: data), to: url)
        XCTAssertNotNil(loadScanCache(from: url))
        clearScanCache(at: url)
        XCTAssertNil(loadScanCache(from: url))
        clearScanCache(at: url)
    }
}
