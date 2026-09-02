import XCTest
@testable import AppAtticScan

final class ShadowTests: XCTestCase {
    func testLocalBinFileShadowingPackageBinIsListed() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-bin-\(UUID().uuidString)")
        let overlay = td.appendingPathComponent("overlay")
        let packaged = td.appendingPathComponent("usr").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try writeExec(overlay.appendingPathComponent("python3"), body: "#!/bin/sh\necho user\n")
        try writeExec(packaged.appendingPathComponent("python3"), body: "#!/bin/sh\necho distro\n")
        try writeExec(overlay.appendingPathComponent("only-user"), body: "#!/bin/sh\necho mine\n")
        try FileManager.default.createDirectory(
            at: overlay.appendingPathComponent("not-a-file"),
            withIntermediateDirectories: true
        )

        let hits = listShadowingOverlays(
            overlays: [(overlay.path, ".local/bin", "file")],
            packageDirs: [packaged.path]
        )
        XCTAssertEqual(hits.map(\.name), ["python3"])
        XCTAssertEqual(hits[0].status, "shadow")
        XCTAssertEqual(hits[0].kind, "file")
        XCTAssertEqual(hits[0].rootLabel, ".local/bin")
        XCTAssertEqual(hits[0].path, overlay.appendingPathComponent("python3").path)
        XCTAssertEqual(hits[0].shadows, packaged.appendingPathComponent("python3").path)
        XCTAssertTrue(hits[0].extraPaths.isEmpty)
    }

    func testSymlinkToPackagedFileIsNotAShadow() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-link-\(UUID().uuidString)")
        let overlay = td.appendingPathComponent("overlay")
        let packaged = td.appendingPathComponent("usr").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let pkg = packaged.appendingPathComponent("git")
        try writeExec(pkg, body: "#!/bin/sh\necho distro\n")
        try FileManager.default.createSymbolicLink(
            atPath: overlay.appendingPathComponent("git").path,
            withDestinationPath: pkg.path
        )

        let hits = listShadowingOverlays(
            overlays: [(overlay.path, ".local/bin", "file")],
            packageDirs: [packaged.path]
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testBrokenOverlayLinkIsNotAShadow() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-broken-\(UUID().uuidString)")
        let overlay = td.appendingPathComponent("overlay")
        let packaged = td.appendingPathComponent("usr").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try writeExec(packaged.appendingPathComponent("git"), body: "#!/bin/sh\necho distro\n")
        try FileManager.default.createSymbolicLink(
            atPath: overlay.appendingPathComponent("git").path,
            withDestinationPath: td.appendingPathComponent("gone").path
        )

        let hits = listShadowingOverlays(
            overlays: [(overlay.path, ".local/bin", "file")],
            packageDirs: [packaged.path]
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testDesktopOverlayShadowsPackagedDesktop() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-desktop-\(UUID().uuidString)")
        let overlay = td.appendingPathComponent("applications")
        let packaged = td.appendingPathComponent("usr-share-applications")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try Data("[Desktop Entry]\nName=User Firefox\n".utf8).write(
            to: overlay.appendingPathComponent("firefox.desktop")
        )
        try Data("[Desktop Entry]\nName=Distro Firefox\n".utf8).write(
            to: packaged.appendingPathComponent("firefox.desktop")
        )

        let hits = listShadowingOverlays(
            overlays: [(overlay.path, ".local/share/applications", "desktop")],
            packageDirs: [packaged.path]
        )
        XCTAssertEqual(hits.map(\.name), ["firefox.desktop"])
        XCTAssertEqual(hits[0].status, "shadow")
        XCTAssertEqual(hits[0].kind, "desktop")
        XCTAssertEqual(hits[0].rootLabel, ".local/share/applications")
        XCTAssertEqual(hits[0].shadows, packaged.appendingPathComponent("firefox.desktop").path)
    }

    func testShadowCopyDoesNotClaimTheToolIsGone() {
        let what = leftoverSummary(
            rootLabel: ".local/bin",
            kind: "file",
            name: "python3",
            shadows: "/usr/bin/python3"
        )
        XCTAssertTrue(what.contains("python3"), what)
        XCTAssertTrue(what.localizedCaseInsensitiveContains("PATH overlay"), what)
        XCTAssertTrue(what.contains("/usr/bin/python3"), what)
        XCTAssertTrue(what.localizedCaseInsensitiveContains("hides the packaged"), what)
        XCTAssertFalse(what.localizedCaseInsensitiveContains("no longer installed"), what)
        XCTAssertTrue(leftoverWhatLooksCurrent(what))

        let why = leftoverWhyText(
            rootLabel: ".local/bin",
            kind: "file",
            shadows: "/usr/bin/python3"
        )
        XCTAssertTrue(why.contains("/usr/bin/python3"), why)
        XCTAssertTrue(why.localizedCaseInsensitiveContains("package-manager"), why)
        XCTAssertFalse(why.localizedCaseInsensitiveContains("the tool is gone"), why)
        XCTAssertTrue(leftoverWhyLooksCurrent(why))

        let desktop = leftoverSummary(
            rootLabel: ".local/share/applications",
            kind: "desktop",
            name: "firefox.desktop",
            shadows: "/usr/share/applications/firefox.desktop"
        )
        XCTAssertTrue(desktop.localizedCaseInsensitiveContains("desktop overlay"), desktop)
        XCTAssertTrue(desktop.contains("/usr/share/applications/firefox.desktop"), desktop)
    }

    func testApplyOrphanReasonsKeepsShadowCopy() {
        let item = DataItem(
            path: "/Users/x/.local/bin/python3",
            name: "python3",
            rootLabel: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3"
        )
        applyOrphanReasons([item])
        XCTAssertEqual(item.status, "shadow")
        XCTAssertTrue(item.summary?.contains("/usr/bin/python3") == true, item.summary ?? "")
        XCTAssertTrue(item.reason?.contains("/usr/bin/python3") == true, item.reason ?? "")
        XCTAssertFalse(item.summary?.localizedCaseInsensitiveContains("no longer installed") == true, item.summary ?? "")
    }

    func testShadowCleanupRemovesOverlayNotPackagedFile() {
        let item = LeftoverItem(
            name: "python3",
            path: "/home/u/.local/bin/python3",
            root: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3"
        )
        let cmd = leftoverRemoveCommand(for: item)
        XCTAssertTrue(cmd.contains("/home/u/.local/bin/python3"), cmd)
        XCTAssertFalse(cmd.contains("/usr/bin/python3"), cmd)
    }

    func testVisibleLeftoversIncludeShadowsAndRespectIgnore() {
        let leftovers = [
            LeftoverItem(
                name: "python3",
                path: "/tmp/overlay/python3",
                root: ".local/bin",
                kind: "file",
                status: "shadow",
                shadows: "/usr/bin/python3"
            ),
            LeftoverItem(name: "Sys", path: "/tmp/Sys", root: "Caches", kind: "dir", status: "system"),
            LeftoverItem(name: "Foo", path: "/tmp/Foo", root: "Caches", kind: "dir", status: "orphaned"),
        ]
        XCTAssertEqual(
            visibleOrphanedLeftovers(leftovers, ignoring: []).map(\.path),
            ["/tmp/overlay/python3", "/tmp/Foo"]
        )
        XCTAssertEqual(
            visibleOrphanedLeftovers(leftovers, ignoring: ["/tmp/overlay/python3"]).map(\.path),
            ["/tmp/Foo"]
        )
    }

    func testGroupOrphanedLeftoversDoesNotMergeShadows() {
        let orphan = DataItem(
            path: "/tmp/Caches/python3",
            name: "python3",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned"
        )
        let shadow = DataItem(
            path: "/tmp/overlay/python3",
            name: "python3",
            rootLabel: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3"
        )
        let grouped = groupOrphanedLeftovers([orphan, shadow])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.filter { $0.status == "shadow" }.count, 1)
        XCTAssertEqual(grouped.filter { $0.status == "orphaned" }.count, 1)
    }

    func testRecentActivityDoesNotClearShadowStatus() {
        let item = DataItem(
            path: "/tmp/overlay/python3",
            name: "python3",
            rootLabel: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3",
            mtime: Date()
        )
        applyRecentActivity([item])
        XCTAssertEqual(item.status, "shadow")
    }

    func testOrphanedItemsIncludeShadows() {
        let result = ScanResult(dataItems: [
            DataItem(path: "/tmp/Foo", name: "Foo", rootLabel: "Caches", kind: "dir", status: "orphaned"),
            DataItem(
                path: "/tmp/overlay/python3",
                name: "python3",
                rootLabel: ".local/bin",
                kind: "file",
                status: "shadow",
                shadows: "/usr/bin/python3"
            ),
            DataItem(path: "/tmp/Sys", name: "Sys", rootLabel: "Caches", kind: "dir", status: "system"),
        ])
        XCTAssertEqual(Set(result.orphanedItems.map(\.status)), ["orphaned", "shadow"])
    }

    func testLeftoverJSONRoundTripKeepsShadows() throws {
        let item = LeftoverItem(
            name: "python3",
            path: "/home/u/.local/bin/python3",
            root: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3"
        )
        let decoded = try JSONDecoder().decode(LeftoverItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.shadows, "/usr/bin/python3")
        XCTAssertEqual(decoded.status, "shadow")
    }

    func testScanResultRoundTripKeepsShadows() {
        let item = DataItem(
            path: "/home/u/.local/bin/python3",
            name: "python3",
            rootLabel: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3"
        )
        let result = ScanResult()
        result.dataItems = [item]
        let data = result.toScanData()
        XCTAssertEqual(data.leftovers[0].shadows, "/usr/bin/python3")
        let restored = scanResult(from: data)
        XCTAssertEqual(restored.dataItems[0].shadows, "/usr/bin/python3")
        XCTAssertEqual(restored.dataItems[0].status, "shadow")
        XCTAssertTrue(leftoverMatchesCategory(restored.dataItems[0], categories: ["/usr/bin/python3"]))
        let exported = exportedScanData(from: data)
        XCTAssertEqual(exported.leftovers[0].shadows, "/usr/bin/python3")
    }

    func testDefaultOverlayRootsIncludeLocalBinAndDesktop() {
        let roots = defaultOverlayShadowRoots(home: "/home/u", env: [:])
        XCTAssertTrue(roots.contains { $0.dir == "/home/u/.local/bin" && $0.kind == "file" })
        XCTAssertTrue(roots.contains { $0.dir == "/home/u/.local/share/applications" && $0.kind == "desktop" })
        XCTAssertTrue(roots.contains { $0.dir.hasSuffix("/.cargo/bin") && $0.kind == "file" })
        let pkgs = defaultPackageShadowDirs(home: "/home/u", env: [:], which: { _ in nil })
        XCTAssertTrue(pkgs.contains("/usr/bin"))
        XCTAssertTrue(pkgs.contains("/usr/share/applications"))
        XCTAssertTrue(pkgs.contains("/home/u/.local/share/flatpak/exports/bin"))
        XCTAssertFalse(pkgs.contains("/home/u/.local/bin"))
    }

    func testOverlayAndPackageDirsHonorXdgDataHome() {
        let env = ["XDG_DATA_HOME": "/tmp/myshare"]
        let roots = defaultOverlayShadowRoots(home: "/home/u", env: env)
        XCTAssertTrue(roots.contains { $0.dir == "/tmp/myshare/applications" && $0.kind == "desktop" })
        XCTAssertTrue(roots.contains { $0.dir == "/home/u/.local/share/applications" && $0.kind == "desktop" })
        let pkgs = defaultPackageShadowDirs(home: "/home/u", env: env, which: { _ in nil })
        XCTAssertTrue(pkgs.contains("/tmp/myshare/flatpak/exports/bin"))
        XCTAssertTrue(pkgs.contains("/tmp/myshare/flatpak/exports/share/applications"))
        XCTAssertTrue(pkgs.contains("/home/u/.local/share/flatpak/exports/bin"))
    }

    func testLeftoverMatchesCategoryFindsPackagedPath() {
        let item = DataItem(
            path: "/home/u/.local/bin/python3",
            name: "python3",
            rootLabel: ".local/bin",
            kind: "file",
            status: "shadow",
            shadows: "/usr/bin/python3"
        )
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["shadow"]))
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["python3"]))
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["/usr/bin/python3"]))
        XCTAssertFalse(leftoverMatchesCategory(item, categories: ["firefox"]))
        let exported = item.toLeftoverItem()
        XCTAssertTrue(leftoverMatchesCategory(exported, categories: ["/usr/bin/python3"]))
        XCTAssertTrue(leftoverMatchesCategory(exported, categories: ["shadow"]))
        XCTAssertFalse(leftoverMatchesCategory(exported, categories: ["firefox"]))
    }

    private func writeExec(_ url: URL, body: String) throws {
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
