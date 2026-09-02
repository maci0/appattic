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
            summary: "Caches folder named Foo",
            extra_paths: ["/tmp/Foo-cache"],
            shadows: "/usr/bin/foo"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LeftoverItem.self, from: data)
        XCTAssertEqual(decoded, item)
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

    func testSoftwareJSONRoundTripKeepsPkgId() throws {
        let item = SoftwareItem(
            name: "Firefox",
            kind: "app",
            path: "/home/u/.local/share/applications/firefox.desktop",
            source: "flatpak",
            pkg_id: "org.mozilla.Firefox"
        )
        let decoded = try JSONDecoder().decode(SoftwareItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.name, "Firefox")
        XCTAssertEqual(decoded.kind, "app")
        XCTAssertEqual(decoded.path, item.path)
        XCTAssertEqual(decoded.pkg_id, "org.mozilla.Firefox")
        XCTAssertEqual(decoded.source, "flatpak")
    }

    func testSoftwareJSONWithoutPkgIdStillDecodes() throws {
        let raw = """
        {"name":"Firefox","kind":"app","path":"/tmp/firefox.desktop","source":"flatpak"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SoftwareItem.self, from: raw)
        XCTAssertEqual(decoded.name, "Firefox")
        XCTAssertEqual(decoded.kind, "app")
        XCTAssertEqual(decoded.path, "/tmp/firefox.desktop")
        XCTAssertEqual(decoded.source, "flatpak")
        XCTAssertNil(decoded.pkg_id)
    }

    func testLeftoverAndSoftwareTypedEnums() {
        XCTAssertEqual(LeftoverItem(name: "a", path: "/a", root: "Caches", kind: "dir", status: "orphaned").leftoverStatus, .orphaned)
        XCTAssertEqual(LeftoverItem(name: "a", path: "/a", root: ".local/bin", kind: "file", status: "shadow").leftoverStatus, .shadow)
        XCTAssertNil(LeftoverItem(name: "a", path: "/a", root: "Caches", kind: "dir", status: "future").leftoverStatus)
        XCTAssertTrue(isListedLeftoverStatus(LeftoverStatus.orphaned))
        XCTAssertTrue(isListedLeftoverStatus(LeftoverStatus.shadow))
        XCTAssertFalse(isListedLeftoverStatus(LeftoverStatus.owned))
        XCTAssertTrue(isListedLeftoverStatus("orphaned"))
        XCTAssertTrue(isListedLeftoverStatus("shadow"))
        XCTAssertFalse(isListedLeftoverStatus("owned"))
        XCTAssertFalse(isListedLeftoverStatus("future"))
        XCTAssertTrue(outdatedIsUpdatable(manager: "brew-formula", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "flatpak", kind: nil))
        XCTAssertFalse(outdatedIsUpdatable(manager: "apt", kind: nil))
        XCTAssertFalse(outdatedIsUpdatable(manager: "brew-cask", kind: "untrusted"))
        XCTAssertEqual(SoftwareItem(name: "jq", kind: "formula", path: "/opt/jq", source: "brew-formula", tier: "remove").softwareTier, .remove)
        XCTAssertEqual(PackageEntry(name: "libfoo", manager: "pacman", kind: "orphan").packageKind, .orphan)
        XCTAssertEqual(PackageEntry(name: "tsc", manager: "npm", kind: "global").packageKind, .global)
    }

    func testScanResultRoundTripKeepsShadowsAndLinuxIds() {
        let leftover = DataItem(
            path: "/home/u/.local/bin/python3",
            name: "python3",
            rootLabel: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3",
            extraPaths: ["/home/u/bin/python3"]
        )
        let sw = Software(
            name: "Firefox",
            kind: "app",
            path: "/home/u/.local/share/flatpak/exports/share/applications/org.mozilla.Firefox.desktop",
            source: "flatpak",
            pkgId: "org.mozilla.Firefox",
            bundleId: "org.mozilla.firefox"
        )
        let outdated = OutdatedPkg(
            name: "iMovie",
            manager: "app-store",
            currentVersion: "10.4.3",
            latestVersion: "10.4.4",
            bundleId: "com.apple.iMovieApp"
        )
        let result = ScanResult(
            dataItems: [leftover],
            software: [sw],
            verdicts: [Verdict(software: sw, tier: "review", reason: "idle")],
            outdated: [outdated]
        )
        let data = result.toScanData()
        XCTAssertEqual(data.leftovers[0].shadows, "/usr/bin/python3")
        XCTAssertEqual(data.leftovers[0].leftoverStatus, .shadow)
        XCTAssertEqual(data.software[0].pkg_id, "org.mozilla.Firefox")
        XCTAssertEqual(data.software[0].bundle_id, "org.mozilla.firefox")
        XCTAssertEqual(data.outdated?[0].bundle_id, "com.apple.iMovieApp")
        let restored = scanResult(from: data)
        XCTAssertEqual(restored.dataItems[0].shadows, "/usr/bin/python3")
        XCTAssertEqual(restored.software[0].pkgId, "org.mozilla.Firefox")
        XCTAssertEqual(restored.software[0].bundleId, "org.mozilla.firefox")
        XCTAssertEqual(restored.outdated[0].bundleId, "com.apple.iMovieApp")
        XCTAssertEqual(restored.verdicts[0].softwareTier, .review)
        XCTAssertTrue(leftoverMatchesCategory(data.leftovers[0], categories: ["/usr/bin/python3"]))
        XCTAssertEqual(
            uninstallCommand(for: data.software[0]),
            "flatpak uninstall -y org.mozilla.Firefox"
        )
        let exported = exportedScanData(from: data, fromCache: true)
        XCTAssertEqual(exported.leftovers[0].shadows, "/usr/bin/python3")
        XCTAssertEqual(exported.software[0].pkg_id, "org.mozilla.Firefox")
        XCTAssertEqual(exported.from_cache, true)
    }

    func testScanResultFallsBackToInjectedNowWhenScannedAtMissing() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let data = ScanData(
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
        XCTAssertEqual(scanResult(from: data, now: now).scannedAt, now)
    }

    func testUninstallCommandUsesPkgIdForSnap() {
        let item = SoftwareItem(
            name: "Code",
            kind: "app",
            path: "/var/lib/snapd/desktop/applications/code_code.desktop",
            source: "snap",
            pkg_id: "code"
        )
        XCTAssertEqual(uninstallCommand(for: item), "snap remove code")
    }
}
