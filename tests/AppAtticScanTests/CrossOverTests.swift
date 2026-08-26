import XCTest
@testable import AppAtticScan

final class CrossOverTests: XCTestCase {
    func testListsBottlesWithCxBottleConf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cx-bottles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBottle(root, "Steam")
        try writeBottle(root, "Notepad++")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)

        let names = Set(listCrossOverBottleDirs(bottlesDir: root.path).map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(names, ["Steam", "Notepad++"])
    }

    func testFindBottlesAsCrossOverSoftware() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cx-sw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBottle(root, "Notepad++")

        let apps = findCrossOverBottles(bottlesDir: root.path)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].displayName, "Notepad++")
        XCTAssertEqual(apps[0].path, root.appendingPathComponent("Notepad++").path)
        XCTAssertEqual(apps[0].extra["crossover_bottle"], "1")
        XCTAssertEqual(apps[0].sourceDir, "crossover")

        let software = buildSoftware(apps: apps, brew: BrewSnapshot(available: false), dataItems: [], history: HistoryIndex())
        XCTAssertEqual(software[0].source, "crossover")
        XCTAssertEqual(softwareDisplaySummary(software[0]), "CrossOver bottle")
        XCTAssertNotEqual(evaluate(software[0]).tier, "remove")
        XCTAssertFalse(skipLiveDu(apps[0]), "bottle size must be measured during the size pass")
    }

    func testHelperAppYieldsToBottle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cx-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBottle(root, "Steam")

        let helper = AppRecord(
            path: "/Users/x/Applications/CrossOver/Steam/Steam.app",
            displayName: "Steam",
            bundleId: "com.codeweavers.CrossOverHelper.abc"
        )
        var apps = [helper]
        var seen: Set<String> = [helper.path]
        appendCrossOverBottles(&apps, seen: &seen, bottlesDir: root.path)
        XCTAssertFalse(apps.contains { isCrossOverHelperPath($0.path) })
        XCTAssertEqual(apps.filter { $0.extra["crossover_bottle"] == "1" }.map(\.displayName), ["Steam"])
    }

    func testBottleOwnsLeftoverName() throws {
        let bottle = AppRecord(
            path: "/tmp/Bottles/Notepad++",
            displayName: "Notepad++",
            extra: ["crossover_bottle": "1"]
        )
        let id = Identity(apps: [bottle], brew: BrewSnapshot(available: false))
        XCTAssertEqual(id.classify("Notepad++", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("NotepadNext", kind: "dir").0, "orphaned")
    }

    func testCleanupDeletesBottleViaCxBottleNotRm() {
        let bottle = Software(
            name: "Notepad++",
            kind: "app",
            path: "/Users/x/Library/Application Support/CrossOver/Bottles/Notepad++",
            source: "crossover"
        )
        let result = ScanResult()
        result.software = [bottle]
        result.verdicts = [Verdict(software: bottle, tier: "remove", reason: "test")]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("cxbottle"), script)
        XCTAssertTrue(script.contains("--delete"), script)
        XCTAssertTrue(script.contains("--bottle"), script)
        XCTAssertTrue(script.contains("Notepad++"), script)
        XCTAssertFalse(script.contains("rm -rf"), script)
    }

    func testCrossoverDeleteContinuesIfUninstallFails() {
        let cmd = crossoverDeleteCommand(bottleName: "Steam")
        XCTAssertTrue(cmd.contains("--uninstall || true"), cmd)
        XCTAssertTrue(cmd.contains("--delete --force"), cmd)
        XCTAssertFalse(cmd.contains("rm -rf"), cmd)
        let bottle = Software(
            name: "Steam",
            kind: "app",
            path: "/Users/x/Library/Application Support/CrossOver/Bottles/Steam",
            source: "crossover"
        )
        let result = ScanResult()
        result.software = [bottle]
        result.verdicts = [Verdict(software: bottle, tier: "remove", reason: "test")]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("--uninstall || true"), script)
        XCTAssertTrue(script.contains("--delete --force"), script)
    }

    func testCleanupDoesNotRmHelper() {
        let helper = Software(
            name: "Steam",
            kind: "app",
            path: "/Users/x/Applications/CrossOver/Steam/Steam.app",
            source: "pkg/other"
        )
        let result = ScanResult()
        result.software = [helper]
        result.verdicts = [Verdict(software: helper, tier: "remove", reason: "test")]
        let script = cleanupScript(result)
        XCTAssertFalse(script.contains("rm -rf"), script)
        XCTAssertFalse(script.contains("--delete"), script)
        XCTAssertTrue(script.contains("CrossOver"), script)
    }

    func testSteamGameInsideBottleDoesNotUseNativeUninstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cx-steam-\(UUID().uuidString)/CrossOver/Bottles")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let wineSteam = root.appendingPathComponent("Steam/drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: wineSteam.appendingPathComponent("steamapps/common/WinGame"), withIntermediateDirectories: true)
        try """
        "AppState"
        {
        \t"appid"\t\t"42"
        \t"name"\t\t"WinGame"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"WinGame"
        }
        """.write(to: wineSteam.appendingPathComponent("steamapps/appmanifest_42.acf"), atomically: true, encoding: .utf8)
        try writeBottle(root, "Steam")

        let libs = crossoverSteamLibraryRoots(bottlesDir: root.path)
        XCTAssertEqual(libs, [wineSteam.path])
        let games = findSteamApps(libraryRoots: libs)
        XCTAssertEqual(games.map(\.displayName), ["WinGame"])
        XCTAssertTrue(games[0].path.lowercased().contains("/crossover/bottles/"), games[0].path)

        let sw = Software(
            name: "WinGame",
            kind: "app",
            path: games[0].path,
            source: "steam",
            extra: ["steam_appid": "42"]
        )
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [Verdict(software: sw, tier: "remove", reason: "test")]
        let script = cleanupScript(result)
        XCTAssertFalse(script.contains("steam://uninstall"), script)
        XCTAssertFalse(script.contains("rm -rf"), script)
    }

    func testBottleStampListsNamesNotDriveC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cx-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBottle(root, "Steam")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Steam/drive_c/windows"),
            withIntermediateDirectories: true
        )
        let stamp = crossoverBottleStamp(bottlesDir: root.path)
        XCTAssertTrue(stamp.contains("Steam"), stamp)
        XCTAssertFalse(stamp.contains("drive_c"), stamp)
    }

    func testScanDataRoundTripKeepsCrossOverSource() {
        let sw = Software(
            name: "Notepad++",
            kind: "app",
            path: "/tmp/Bottles/Notepad++",
            source: "crossover",
            extra: ["crossover_bottle": "1"]
        )
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [Verdict(software: sw, tier: "review", reason: "bottle")]
        let restored = scanResult(from: result.toScanData())
        XCTAssertEqual(restored.software[0].source, "crossover")
        XCTAssertEqual(restored.software[0].extra["crossover_bottle"], "1")
        XCTAssertEqual(softwareDisplaySummary(restored.software[0]), "CrossOver bottle")
    }

    private func writeBottle(_ root: URL, _ name: String) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[Bottle]\n\"WineArch\" = \"win64\"\n".write(to: dir.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
    }
}
