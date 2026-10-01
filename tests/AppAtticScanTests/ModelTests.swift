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

    /// The synthesized `Codable` takes its key names from the property names,
    /// so renaming `size_bytes` to `sizeBytes` leaves the round trip above green
    /// while breaking every `last-scan.json` already on disk and every `--json`
    /// consumer. A literal pins the wire names in both directions.
    func testLeftoverJSONWireKeysAreFixed() throws {
        let json = """
        {"name":"Foo","path":"/tmp/Foo","root":"Caches","kind":"dir","status":"orphaned",\
        "owner":"me","size_bytes":12,"size_measured":true,"mtime":"2026-08-17T00:00:00Z",\
        "reason":"r","summary":"s","extra_paths":["/tmp/Foo-cache"],"shadows":"/usr/bin/foo"}
        """
        let decoded = try JSONDecoder().decode(LeftoverItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.owner, "me")
        XCTAssertEqual(decoded.size_bytes, 12)
        XCTAssertTrue(decoded.size_measured)
        XCTAssertEqual(decoded.mtime, "2026-08-17T00:00:00Z")
        XCTAssertEqual(decoded.extra_paths, ["/tmp/Foo-cache"])
        XCTAssertEqual(decoded.shadows, "/usr/bin/foo")
        let keys = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(keys.keys),
            [
                "name", "path", "root", "kind", "status", "owner", "size_bytes",
                "size_measured", "mtime", "reason", "summary", "extra_paths", "shadows",
            ]
        )
    }

    /// Same wire contract for the software rows, which the dashboard and the
    /// `appattic --json` payload both read. Every optional carries a value:
    /// `nil` decodes and then drops its key on the way back out.
    func testSoftwareItemJSONWireKeysAreFixed() throws {
        let json = """
        {"name":"Sketch","kind":"app","path":"/Applications/Sketch.app","source":"applications",\
        "version":"100","size_bytes":2048,"size_measured":true,"data_bytes":512,\
        "data_measured":false,\
        "data_paths":["/Library/Application Support/Sketch"],"last_used":"2026-08-01T00:00:00Z",\
        "installed_at":"2026-01-01T00:00:00Z","usage_source":"history","running_service":false,\
        "tier":"keep","reason":"running","cask_name":"sketch","is_leaf":true,"outdated":false,\
        "current_version":"100","latest_version":"101","summary":"s","steam_appid":"440",\
        "pkg_id":"com.bohemiancoding.sketch3.pkg","bundle_id":"com.bohemiancoding.sketch3"}
        """
        let decoded = try JSONDecoder().decode(SoftwareItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.size_bytes, 2048)
        XCTAssertEqual(decoded.data_bytes, 512)
        XCTAssertEqual(decoded.data_measured, false)
        XCTAssertEqual(decoded.tier, "keep")
        XCTAssertEqual(decoded.bundle_id, "com.bohemiancoding.sketch3")
        XCTAssertEqual(decoded.data_paths, ["/Library/Application Support/Sketch"])
        let keys = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(keys.keys),
            [
                "name", "kind", "path", "source", "version", "size_bytes", "size_measured",
                "data_bytes", "data_measured", "data_paths", "last_used", "installed_at", "usage_source",
                "running_service", "tier", "reason", "cask_name", "is_leaf", "outdated",
                "current_version", "latest_version", "summary", "steam_appid", "pkg_id",
                "bundle_id",
            ]
        )
    }

    /// `totalBytes` is what the reclaimable total sums, so a dropped
    /// `data_bytes` under-reports every row's real cost. The sum saturates
    /// rather than trapping, like every other byte total here.
    func testSoftwareItemTotalBytesAddsDataBytesAndSaturates() {
        let row = SoftwareItem(
            name: "Sketch",
            kind: "app",
            path: "/Applications/Sketch.app",
            source: "applications",
            size_bytes: 2048,
            data_bytes: 512
        )
        XCTAssertEqual(row.totalBytes, 2560)
        let saturated = SoftwareItem(
            name: "Big",
            kind: "app",
            path: "/Applications/Big.app",
            source: "applications",
            size_bytes: Int.max,
            data_bytes: 1
        )
        XCTAssertEqual(saturated.totalBytes, Int.max)
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
        XCTAssertTrue(isListedLeftoverStatus(LeftoverStatus.orphaned))
        XCTAssertTrue(isListedLeftoverStatus(LeftoverStatus.shadow))
        XCTAssertFalse(isListedLeftoverStatus(LeftoverStatus.owned))
        XCTAssertTrue(isListedLeftoverStatus("orphaned"))
        XCTAssertTrue(isListedLeftoverStatus("shadow"))
        XCTAssertFalse(isListedLeftoverStatus("owned"))
        XCTAssertFalse(isListedLeftoverStatus("future"))
        XCTAssertTrue(outdatedIsUpdatable(manager: "brew-formula", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "flatpak", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "apt", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "pacman", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "aur", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "dnf", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "yum", kind: nil))
        XCTAssertTrue(outdatedIsUpdatable(manager: "zypper", kind: nil))
        XCTAssertFalse(outdatedIsUpdatable(manager: "snap", kind: nil))
        XCTAssertFalse(outdatedIsUpdatable(manager: "pip", kind: nil))
        XCTAssertFalse(outdatedIsUpdatable(manager: "brew-cask", kind: "untrusted"))
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
        XCTAssertEqual(data.leftovers[0].status, "shadow")
        XCTAssertEqual(data.software[0].pkg_id, "org.mozilla.Firefox")
        XCTAssertEqual(data.software[0].bundle_id, "org.mozilla.firefox")
        XCTAssertEqual(data.outdated?[0].bundle_id, "com.apple.iMovieApp")
        let restored = scanResult(from: data)
        XCTAssertEqual(restored.dataItems[0].shadows, "/usr/bin/python3")
        XCTAssertEqual(restored.software[0].pkgId, "org.mozilla.Firefox")
        XCTAssertEqual(restored.software[0].bundleId, "org.mozilla.firefox")
        XCTAssertEqual(restored.outdated[0].bundleId, "com.apple.iMovieApp")
        XCTAssertEqual(restored.verdicts[0].tier, "review")
        XCTAssertTrue(leftoverMatchesCategory(data.leftovers[0], categories: ["/usr/bin/python3"]))
        XCTAssertEqual(
            uninstallCommand(for: data.software[0]),
            "if flatpak info org.mozilla.Firefox >/dev/null 2>&1; then flatpak uninstall -y org.mozilla.Firefox; fi"
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

    /// A software row whose `size_measured` / `data_measured` keys are absent
    /// decodes as unmeasured, not as measured.
    ///
    /// Both keys are `Bool?` on the wire and the synthesised encode omits a
    /// nil, so absent means "this build cannot tell whether it was measured".
    /// `dataMeasured` is the safety gate `evaluateVerdict` reads: false holds
    /// the row at REVIEW, true lets it reach REMOVE. Defaulting the unknown to
    /// true therefore turns a dropped flag into a destructive verdict, so the
    /// unknown resolves the safe way round.
    func testScanResultTreatsAnAbsentMeasuredFlagAsUnmeasured() throws {
        let json = """
        {"scanned_at":"2026-08-17T12:00:00Z","duration_s":1,"brew_available":false,\
        "totals":{"apps_installed":0,"orphaned_items":0,"orphaned_bytes":0,\
        "system_leftover_bytes":0,"reclaimable_bytes":0,"stale_apps":0,"outdated_apps":0},\
        "leftovers":[],\
        "software":[{"name":"Sketch","kind":"app","path":"/Applications/Sketch.app",\
        "source":"applications","size_bytes":2048,"data_bytes":512}]}
        """
        let data = try JSONDecoder().decode(ScanData.self, from: Data(json.utf8))
        XCTAssertNil(data.software[0].size_measured)
        XCTAssertNil(data.software[0].data_measured)
        let restored = scanResult(from: data)
        XCTAssertFalse(restored.software[0].sizeMeasured)
        XCTAssertFalse(restored.software[0].dataMeasured)
        // The byte totals still read back: a number this build cannot vouch for
        // is still a number, and only the verdict gate changes.
        XCTAssertEqual(restored.software[0].sizeBytes, 2048)
        XCTAssertEqual(restored.software[0].dataBytes, 512)
        // And it is still reported as unmeasured on the way out, so an export
        // does not quietly promote the unknown to a fact.
        XCTAssertEqual(restored.toScanData().software[0].size_measured, false)
        XCTAssertEqual(restored.toScanData().software[0].data_measured, false)
    }

    /// An explicit `true` is the writer saying it did measure, and survives the
    /// round trip unchanged. Pins the other side of the fix above: the absent
    /// case is not fixed by making every row unmeasured.
    func testScanResultKeepsAnExplicitMeasuredFlag() throws {
        let json = """
        {"scanned_at":"2026-08-17T12:00:00Z","duration_s":1,"brew_available":false,\
        "totals":{"apps_installed":0,"orphaned_items":0,"orphaned_bytes":0,\
        "system_leftover_bytes":0,"reclaimable_bytes":0,"stale_apps":0,"outdated_apps":0},\
        "leftovers":[],\
        "software":[{"name":"Sketch","kind":"app","path":"/Applications/Sketch.app",\
        "source":"applications","size_bytes":2048,"size_measured":true,\
        "data_bytes":512,"data_measured":true}]}
        """
        let data = try JSONDecoder().decode(ScanData.self, from: Data(json.utf8))
        let restored = scanResult(from: data)
        XCTAssertTrue(restored.software[0].sizeMeasured)
        XCTAssertTrue(restored.software[0].dataMeasured)
    }

    func testUninstallCommandUsesPkgIdForSnap() {
        let item = SoftwareItem(
            name: "Code",
            kind: "app",
            path: "/var/lib/snapd/desktop/applications/code_code.desktop",
            source: "snap",
            pkg_id: "code"
        )
        XCTAssertEqual(uninstallCommand(for: item), "if snap list code >/dev/null 2>&1; then snap remove code; fi")
    }

    /// A package id from a hostile remote reaches `snap remove` as an
    /// argument, so a leading `-` has to be refused rather than quoted.
    func testUninstallCommandRefusesNameThatReadsAsAnOption() {
        let item = SoftwareItem(
            name: "Code",
            kind: "app",
            path: "/var/lib/snapd/desktop/applications/code_code.desktop",
            source: "snap",
            pkg_id: "--purge"
        )
        let cmd = uninstallCommand(for: item)
        XCTAssertEqual(cmd, "# skipped --purge: package id reads as a command option")
        XCTAssertNil(parseGuardedRemove(cmd))
    }

    /// A Steam app id comes from an `appmanifest_*.acf` on disk and is spliced
    /// into a `steam://uninstall/<id>` URI, so a quote in it ends the shell word
    /// and the rest runs as commands in the generated script. It was the one
    /// argument reaching a command line without the gate the others get.
    func testUninstallCommandRefusesASteamAppIdThatIsNotAnIdentifier() {
        let item = SoftwareItem(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/EmuDevz.app",
            source: "steam",
            steam_appid: "1';touch /tmp/appattic-pwned;'"
        )
        let cmd = uninstallCommand(for: item)
        XCTAssertEqual(cmd, "# skipped 1';touch /tmp/appattic-pwned;': Steam app id is not a plain identifier")
        XCTAssertFalse(cmd.contains("steam://uninstall/"), "no uninstall URI may reach the script")
    }

    /// A real app id is digits and must still be handed to the client, so the
    /// gate above cannot be a blanket refusal of the Steam branch.
    func testUninstallCommandKeepsAPlainSteamAppId() {
        let item = SoftwareItem(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/EmuDevz.app",
            source: "steam",
            steam_appid: "4260720"
        )
        XCTAssertTrue(uninstallCommand(for: item).contains("steam://uninstall/4260720"))
    }

    func testLeftoverStatusAccessor() {
        let item = LeftoverItem(
            name: "python3",
            path: "/home/u/.local/bin/python3",
            root: ".local/bin",
            kind: "file",
            status: "shadow",
            size_bytes: 7
        )
        XCTAssertEqual(item.leftoverStatus, .shadow)
        XCTAssertTrue(item.isListedLeftover)
        XCTAssertEqual(item.totalBytes, 7)

        let unknown = LeftoverItem(
            name: "x",
            path: "/tmp/x",
            root: "Caches",
            kind: "dir",
            status: "future-status"
        )
        XCTAssertNil(unknown.leftoverStatus)
        XCTAssertFalse(unknown.isListedLeftover)
        XCTAssertEqual(unknown.totalBytes, 0)

        let live = DataItem(path: "/tmp/x", name: "x", rootLabel: "Caches", kind: "dir", status: "shadow")
        XCTAssertEqual(live.leftoverStatus, .shadow)
        XCTAssertTrue(live.isListedLeftover)
        XCTAssertEqual(live.toLeftoverItem().leftoverStatus, .shadow)
    }

    func testStaleTierAccessors() {
        let sw = Software(name: "Foo", kind: "app", path: "/tmp/Foo.app", source: "mac")
        let keep = Verdict(software: sw, tier: "keep")
        let review = Verdict(software: sw, tier: "review")
        let remove = Verdict(software: sw, tier: "remove")
        let system = Verdict(software: sw, tier: "system")
        XCTAssertEqual(review.tierKind, .review)
        XCTAssertNil(Verdict(software: sw, tier: "").tierKind)

        XCTAssertEqual(staleVerdicts([keep, review, remove]).count, 2)
        XCTAssertEqual(staleVerdicts([keep, review, remove, system]).count, 2)
        XCTAssertEqual(staleVerdicts([keep, review, remove, system], includeSystem: true).count, 3)

        XCTAssertTrue(StaleTier.isSelectable(review.tierKind))
        XCTAssertTrue(StaleTier.isSelectable(remove.tierKind))
        XCTAssertFalse(StaleTier.isSelectable(keep.tierKind))
        XCTAssertFalse(StaleTier.isSelectable(nil))
        XCTAssertEqual(selectableCleanupTiers, ["remove", "review"])

        let item = SoftwareItem(name: "Foo", kind: "app", path: "/tmp/Foo.app", source: "mac", tier: "remove")
        XCTAssertEqual(item.tierKind, .remove)
        XCTAssertNil(SoftwareItem(name: "Bar", kind: "app", path: "/tmp/Bar.app", source: "mac").tierKind)
        XCTAssertEqual(visibleStaleSoftware([item], includeSystem: false).count, 1)
    }

    func testUpgradableManagerMatchesOutdatableManagers() {
        for raw in ["brew-formula", "brew-cask", "flatpak", "apt", "pacman", "aur", "dnf", "yum", "zypper"] {
            let entry = OutdatedEntry(name: "foo", manager: raw)
            XCTAssertTrue(entry.updatable, "\(raw) should be updatable")
            XCTAssertNotNil(entry.upgradableManager, "\(raw) should map to a manager")
        }
        for raw in ["snap", "pip", "app-store", "npm", "future-manager"] {
            let entry = OutdatedEntry(name: "foo", manager: raw)
            XCTAssertFalse(entry.updatable, "\(raw) is report-only")
            XCTAssertNil(entry.upgradableManager)
        }
        let untrusted = OutdatedEntry(name: "foo", manager: "brew-cask", kind: "untrusted")
        XCTAssertFalse(untrusted.updatable)
        XCTAssertNil(untrusted.upgradableManager)

        for manager in ["apt", "pacman", "dnf", "zypper"] {
            XCTAssertTrue(
                PackageEntry(name: "libfoo", manager: manager, kind: "orphan").canMarkManual,
                "\(manager) orphans can be marked manual"
            )
        }
        for manager in ["npm", "pipx", "uv", "future"] {
            XCTAssertFalse(
                PackageEntry(name: "libfoo", manager: manager, kind: "orphan").canMarkManual,
                "\(manager) has no manual marker"
            )
        }
    }

    /// `updateCommand` and `upgradableManager` are one model, so a manager that
    /// reports updatable must also produce a command, and vice versa.
    func testUpdateCommandMatchesUpgradableManagers() {
        for manager in UpgradableManager.allCases {
            let pkg = OutdatedPkg(name: "pkg-1", manager: manager.rawValue)
            let cmd = updateCommand(pkg)
            XCTAssertNotNil(cmd, "\(manager.rawValue) should have an upgrade command")
            XCTAssertTrue(cmd?.contains("pkg-1") == true, "\(manager.rawValue) command should name the package")
        }
        for raw in ["snap", "app-store", "pip", "npm", "future-manager"] {
            XCTAssertNil(updateCommand(OutdatedPkg(name: "pkg-1", manager: raw)), "\(raw) is report-only")
        }
        XCTAssertNil(
            updateCommand(OutdatedPkg(name: "pkg-1", manager: "brew-cask", kind: "untrusted")),
            "an untrusted cask gets no upgrade command"
        )
    }
}
