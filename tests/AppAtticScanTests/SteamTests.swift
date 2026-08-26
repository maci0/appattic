import XCTest
@testable import AppAtticScan

final class SteamTests: XCTestCase {
    func testParseAppManifestReadsInstalledGame() {
        let text = """
        "AppState"
        {
        \t"appid"\t\t"2060160"
        \t"name"\t\t"The Farmer Was Replaced"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"The Farmer Was Replaced"
        \t"LastPlayed"\t\t"1769229316"
        \t"SizeOnDisk"\t\t"484359177"
        \t"InstalledDepots"
        \t{
        \t\t"2060162"
        \t\t{
        \t\t\t"size"\t\t"1"
        \t\t}
        \t}
        }
        """
        let m = parseSteamAppManifest(text)
        XCTAssertEqual(m?.appId, "2060160")
        XCTAssertEqual(m?.name, "The Farmer Was Replaced")
        XCTAssertEqual(m?.installDir, "The Farmer Was Replaced")
        XCTAssertEqual(m?.lastPlayed, Date(timeIntervalSince1970: 1_769_229_316))
        XCTAssertEqual(m?.sizeOnDisk, 484_359_177)
        XCTAssertTrue(m?.isInstalled ?? false)
    }

    func testParseAppManifestSkipsUninstalled() {
        let text = """
        "AppState"
        {
        \t"appid"\t\t"1"
        \t"name"\t\t"Gone"
        \t"StateFlags"\t\t"0"
        \t"installdir"\t\t"Gone"
        }
        """
        XCTAssertNil(parseSteamAppManifest(text))
    }

    func testParseLibraryFoldersReadsExtraPaths() {
        let text = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/me/Library/Application Support/Steam"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"/Volumes/Games/SteamLibrary"
        \t}
        }
        """
        let paths = parseSteamLibraryFolders(text)
        XCTAssertEqual(paths, [
            "/Users/me/Library/Application Support/Steam",
            "/Volumes/Games/SteamLibrary",
        ])
    }

    func testFindSteamAppsReadsBundleAndSkipsHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-lib-\(UUID().uuidString)")
        let common = root.appendingPathComponent("steamapps/common/The Farmer Was Replaced")
        let game = common.appendingPathComponent("TheFarmerWasReplaced.app")
        let helper = common.appendingPathComponent("TheFarmerWasReplaced Helper.app")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try plist(["CFBundleName": "TheFarmerWasReplaced", "CFBundleIdentifier": "com.TheFarmerWasReplaced.TheFarmerWasReplaced"])
            .write(to: game.appendingPathComponent("Contents/Info.plist"))
        try plist(["CFBundleName": "Helper", "CFBundleIdentifier": "com.TheFarmerWasReplaced.Helper"])
            .write(to: helper.appendingPathComponent("Contents/Info.plist"))
        try """
        "AppState"
        {
        \t"appid"\t\t"2060160"
        \t"name"\t\t"The Farmer Was Replaced"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"The Farmer Was Replaced"
        \t"LastPlayed"\t\t"1769229316"
        \t"SizeOnDisk"\t\t"484359177"
        }
        """.write(to: root.appendingPathComponent("steamapps/appmanifest_2060160.acf"), atomically: true, encoding: .utf8)

        let apps = findSteamApps(libraryRoots: [root.path])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].displayName, "The Farmer Was Replaced")
        XCTAssertEqual(apps[0].bundleId, "com.TheFarmerWasReplaced.TheFarmerWasReplaced")
        XCTAssertEqual(apps[0].path, game.path)
        XCTAssertEqual(apps[0].extra["steam_appid"], "2060160")
        XCTAssertEqual(apps[0].sizeBytes, 484_359_177)
        XCTAssertEqual(apps[0].lastUsed, Date(timeIntervalSince1970: 1_769_229_316))
        XCTAssertEqual(apps[0].lastUsedSource, "steam")
        XCTAssertFalse(apps.contains { $0.path.contains("Helper") })
    }

    func testSteamGameOwnsLeftoversAndSteamFolder() {
        let game = AppRecord(
            path: "/tmp/TheFarmerWasReplaced.app",
            displayName: "The Farmer Was Replaced",
            bundleId: "com.TheFarmerWasReplaced.TheFarmerWasReplaced",
            extra: [
                "steam_appid": "2060160",
                "steam_installdir": "The Farmer Was Replaced",
            ]
        )
        let id = Identity(apps: [game], brew: BrewSnapshot(available: false))
        XCTAssertEqual(id.classify("com.TheFarmerWasReplaced.TheFarmerWasReplaced.plist", kind: "plist").0, "owned")
        XCTAssertEqual(id.classify("The Farmer Was Replaced", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("Steam", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("SHENZHEN IO", kind: "dir").0, "orphaned")
    }

    func testSteamShenzhenNameMatchesInstallDir() {
        let game = AppRecord(
            path: "/tmp/Shenzhen IO.app",
            displayName: "SHENZHEN I/O",
            bundleId: "com.zachtronics.Shenzhen",
            extra: ["steam_appid": "504210", "steam_installdir": "SHENZHEN IO"]
        )
        XCTAssertEqual(Identity(apps: [game], brew: BrewSnapshot(available: false)).classify("SHENZHEN IO", kind: "dir").0, "owned")
    }

    func testSteamSoftwareIsNotPkgOther() {
        let app = AppRecord(
            path: "/tmp/EmuDevz.app",
            displayName: "EmuDevz",
            bundleId: "io.r-labs.emudevz",
            extra: ["steam_appid": "4260720"]
        )
        let software = buildSoftware(apps: [app], brew: BrewSnapshot(available: false), dataItems: [], history: HistoryIndex())
        XCTAssertEqual(software.first?.source, "steam")
        XCTAssertEqual(evaluate(software[0]).tier, "review")
    }

    func testIsRealAppPathStillRejectsRandomSupportBundles() {
        XCTAssertFalse(isRealAppPath("/Users/x/Library/Application Support/Foo/Foo.app"))
        XCTAssertFalse(isRealAppPath("/Users/x/Library/Application Support/Steam/steamapps/common/EmuDevz/EmuDevz.app"))
    }

    func testFindSteamAppsIncludesClientWithoutGames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-client-\(UUID().uuidString)")
        let client = root.appendingPathComponent("Steam.AppBundle/Steam")
        try FileManager.default.createDirectory(at: client.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try plist(["CFBundleName": "Steam", "CFBundleIdentifier": "com.valvesoftware.steam"])
            .write(to: client.appendingPathComponent("Contents/Info.plist"))

        let apps = findSteamApps(libraryRoots: [root.path])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].displayName, "Steam")
        XCTAssertEqual(apps[0].bundleId, "com.valvesoftware.steam")
        XCTAssertEqual(apps[0].path, client.path)
        XCTAssertEqual(apps[0].extra["steam_client"], "1")
        XCTAssertNil(apps[0].extra["steam_appid"])
        XCTAssertFalse(skipLiveDu(apps[0]), "Steam client size must be measured during the size pass")
    }

    func testSteamClientOwnsSteamFolderWithNoGames() {
        let client = AppRecord(
            path: "/tmp/Steam.AppBundle/Steam",
            displayName: "Steam",
            bundleId: "com.valvesoftware.steam",
            extra: ["steam_client": "1"]
        )
        let id = Identity(apps: [client], brew: BrewSnapshot(available: false))
        XCTAssertEqual(id.classify("Steam", kind: "dir").0, "owned")
        XCTAssertEqual(evaluate(buildSoftware(apps: [client], brew: BrewSnapshot(available: false), dataItems: [], history: HistoryIndex())[0]).tier, "keep")
    }

    func testFindSteamAppsSkipsRuntimesButKeepsGames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeInstalledGame(library: root, appId: "228980", name: "Steamworks Common Redistributables", installDir: "Steamworks Shared")
        try writeInstalledGame(library: root, appId: "1493710", name: "Proton 8.0", installDir: "Proton 8.0")
        try writeInstalledGame(library: root, appId: "1391110", name: "Steam Linux Runtime 3.0 (sniper)", installDir: "sniper")
        try writeInstalledGame(library: root, appId: "1", name: "Proton Bus Simulator", installDir: "Proton Bus Simulator")

        let apps = findSteamApps(libraryRoots: [root.path])
        XCTAssertEqual(apps.map(\.displayName), ["Proton Bus Simulator"])
    }

    func testFindSteamAppsFindsNestedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-nested-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("steamapps/common/DeepGame/Mac/DeepGame.app")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try plist(["CFBundleName": "DeepGame", "CFBundleIdentifier": "com.example.deep"])
            .write(to: game.appendingPathComponent("Contents/Info.plist"))
        try writeManifest(library: root, appId: "9", name: "Deep Game", installDir: "DeepGame")

        let apps = findSteamApps(libraryRoots: [root.path])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].path, game.path)
        XCTAssertEqual(apps[0].bundleId, "com.example.deep")
    }

    func testBrowserShortcutYieldsToSteamGame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-pwa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("steamapps/common/EmuDevz/EmuDevz.app")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try plist(["CFBundleName": "EmuDevz", "CFBundleIdentifier": "io.r-labs.emudevz"])
            .write(to: game.appendingPathComponent("Contents/Info.plist"))
        try writeManifest(library: root, appId: "4260720", name: "EmuDevz", installDir: "EmuDevz")

        let pwa = AppRecord(
            path: "/Users/x/Applications/Brave Browser Apps.localized/EmuDevz.app",
            displayName: "EmuDevz",
            bundleId: "io.r-labs.emudevz"
        )
        var apps = [pwa]
        var seen: Set<String> = [pwa.path]
        appendSteamApps(&apps, seen: &seen, libraryRoots: [root.path])
        XCTAssertEqual(apps.map(\.path), [game.path])
        XCTAssertEqual(apps[0].extra["steam_appid"], "4260720")
    }

    func testSteamManifestStampUsesAcfNamesNotBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try writeManifest(library: root, appId: "2060160", name: "The Farmer Was Replaced", installDir: "The Farmer Was Replaced")
        let stamp = steamManifestStamp(libraryRoots: [root.path])
        XCTAssertTrue(stamp.contains("appmanifest_2060160.acf"), stamp)
        XCTAssertFalse(stamp.contains("TheFarmerWasReplaced.app"))
    }

    func testCleanupScriptUninstallsSteamViaProtocolNotRm() {
        let sw = Software(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/steamapps/common/EmuDevz/EmuDevz.app",
            source: "steam",
            extra: ["steam_appid": "4260720"]
        )
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [Verdict(software: sw, tier: "remove", reason: "test")]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("steam://uninstall/4260720"), script)
        XCTAssertFalse(script.contains("rm -rf"), script)
    }

    func testCleanupScriptDoesNotRmSteamPathWithoutAppId() {
        let sw = Software(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/steamapps/common/EmuDevz/EmuDevz.app",
            source: "steam"
        )
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [Verdict(software: sw, tier: "remove", reason: "test")]
        let script = cleanupScript(result)
        XCTAssertFalse(script.contains("rm -rf"), script)
        XCTAssertTrue(script.contains("uninstall from Steam"), script)
    }

    func testScanDataRoundTripKeepsSteamAppId() {
        let sw = Software(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/EmuDevz.app",
            source: "steam",
            extra: ["steam_appid": "4260720"]
        )
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [Verdict(software: sw, tier: "review", reason: "Steam game")]
        let restored = scanResult(from: result.toScanData())
        XCTAssertEqual(restored.software[0].extra["steam_appid"], "4260720")
        XCTAssertEqual(restored.software[0].source, "steam")
        restored.verdicts = [Verdict(software: restored.software[0], tier: "remove", reason: "test")]
        XCTAssertTrue(cleanupScript(restored).contains("steam://uninstall/4260720"))
    }

    func testSoftwareDisplaySummaryDistinguishesClient() {
        let client = Software(name: "Steam", kind: "app", path: "/tmp/Steam", source: "steam", extra: ["steam_client": "1"])
        let game = Software(name: "EmuDevz", kind: "app", path: "/tmp/EmuDevz.app", source: "steam", extra: ["steam_appid": "4260720"])
        XCTAssertEqual(softwareDisplaySummary(client), "Steam client")
        XCTAssertEqual(softwareDisplaySummary(game), "Steam game")
    }

    func testSoftwareDisplaySummaryDropsUnityCopyright() {
        let game = Software(
            name: "The Farmer Was Replaced",
            kind: "app",
            path: "/tmp/The Farmer Was Replaced.app",
            source: "steam",
            summary: "Unity Player version 6000.0.43f1 (97272b72f107). (c) 2005-2025 Unity Technologies. All rights reserved.",
            extra: ["steam_appid": "123"]
        )
        XCTAssertEqual(softwareDisplaySummary(game), "Steam game")
        let other = Software(
            name: "Boxedwine",
            kind: "app",
            path: "/tmp/Boxedwine.app",
            source: "pkg/other",
            summary: "Unity Player version 1.0. All rights reserved."
        )
        XCTAssertEqual(softwareDisplaySummary(other), "Installed application")
        let keep = Software(
            name: "The Unarchiver",
            kind: "app",
            path: "/tmp/The Unarchiver.app",
            source: "brew-cask",
            summary: "Unpacks archive files"
        )
        XCTAssertEqual(softwareDisplaySummary(keep), "Unpacks archive files")
    }

    func testSoftwareDisplaySummaryIgnoresGenericSteamCategory() {
        let game = Software(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/EmuDevz.app",
            source: "steam",
            summary: "Game",
            extra: ["steam_appid": "4260720"]
        )
        XCTAssertEqual(softwareDisplaySummary(game), "Steam game")
        let blurb = Software(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/EmuDevz.app",
            source: "steam",
            summary: "Build and debug emulators in the browser",
            extra: ["steam_appid": "4260720"]
        )
        XCTAssertEqual(softwareDisplaySummary(blurb), "Build and debug emulators in the browser")
    }

    private func writeInstalledGame(library: URL, appId: String, name: String, installDir: String) throws {
        let dir = library.appendingPathComponent("steamapps/common/\(installDir)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeManifest(library: library, appId: appId, name: name, installDir: installDir)
    }

    private func writeManifest(library: URL, appId: String, name: String, installDir: String) throws {
        try FileManager.default.createDirectory(at: library.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try """
        "AppState"
        {
        \t"appid"\t\t"\(appId)"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"\(installDir)"
        }
        """.write(to: library.appendingPathComponent("steamapps/appmanifest_\(appId).acf"), atomically: true, encoding: .utf8)
    }

    private func plist(_ info: [String: String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }
}
