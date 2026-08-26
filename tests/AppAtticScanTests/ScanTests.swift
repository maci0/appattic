import XCTest
@testable import AppAtticScan

final class ScanTests: XCTestCase {
    func testTempTreeOrphanWithEmptyBrew() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let orphan = td.appendingPathComponent("DeadApp")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "x".write(to: orphan.appendingPathComponent("cache.dat"), atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-200 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: orphan.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: orphan.appendingPathComponent("cache.dat").path)

        let result = performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(available: false),
            leftoverRoots: [("Application Support", td.path, "dir")],
            linuxOutdated: [],
            appStoreOutdated: [],
            packages: [],
            history: HistoryIndex(),
            skipLiveUsage: true
        )
        let orphans = result.orphanedItems
        XCTAssertTrue(orphans.contains { $0.name == "DeadApp" })
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("rm -rf"))
        XCTAssertTrue(script.contains("DeadApp"))
        XCTAssertFalse(script.contains("\nbrew upgrade "))
        let data = result.toScanData()
        XCTAssertGreaterThanOrEqual(data.totals.orphaned_items, 1)
        try? FileManager.default.removeItem(at: td)
    }

    func testSystemAppLeftoversOwnedWhenIncludeSystemOff() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let imovie = td.appendingPathComponent("iMovie")
        try FileManager.default.createDirectory(at: imovie, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-200 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: imovie.path)
        defer { try? FileManager.default.removeItem(at: td) }
        let app = AppRecord(
            path: "/Applications/iMovie.app",
            displayName: "iMovie",
            bundleId: "com.apple.iMovie",
            isSystem: true
        )
        let result = performScan(
            includeSystem: false,
            apps: [app],
            brew: BrewSnapshot(available: false),
            leftoverRoots: [("Application Support", td.path, "dir")],
            linuxOutdated: [],
            appStoreOutdated: [],
            packages: [],
            history: HistoryIndex(),
            skipLiveUsage: true
        )
        XCTAssertFalse(result.apps.contains { $0.isSystem }, "system apps stay out of the installed list")
        XCTAssertFalse(
            result.orphanedItems.contains { $0.name == "iMovie" },
            "installed system apps must not produce leftover false positives"
        )
        XCTAssertEqual(result.dataItems.first { $0.name == "iMovie" }?.status, "owned")
    }

    func testCleanupScriptUninstallsRemoveTierFormula() {
        let sw = Software(name: "jq", kind: "formula", path: "/opt/homebrew/bin/jq", source: "brew-formula", isLeaf: true, bins: ["jq"], historySpanDays: 400)
        let v = evaluate(sw)
        XCTAssertEqual(v.tier, "remove")
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [v]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("set -e"), script)
        XCTAssertTrue(script.contains("brew uninstall jq"))
    }

    func testCleanupScriptUninstallsRemoveTierOtherCask() {
        let lastUsed = Date().addingTimeInterval(-400 * 86400)
        let sw = Software(
            name: "quarto",
            kind: "other",
            path: "/Applications/quarto",
            source: "brew-cask",
            lastUsed: lastUsed,
            caskName: "quarto"
        )
        let v = evaluate(sw)
        XCTAssertEqual(v.tier, "remove")
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [v]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("brew uninstall --cask quarto"), script)
    }

    func testDryRunLeftoversOmitsStaleUninstallsAndHonorsCategory() {
        let orion = DataItem(
            path: "/Users/x/Library/Application Support/Orion",
            name: "Orion",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            extraPaths: ["/Users/x/Library/Caches/com.kagi.kagimacOS"]
        )
        let whisky = DataItem(
            path: "/Users/x/Library/Application Support/com.isaacmarovitz.Whisky",
            name: "com.isaacmarovitz.Whisky",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned"
        )
        let sw = Software(
            name: "The Unarchiver",
            kind: "app",
            path: "/Applications/The Unarchiver.app",
            source: "brew-cask",
            lastUsed: Date().addingTimeInterval(-400 * 86400),
            caskName: "the-unarchiver"
        )
        let result = ScanResult()
        result.dataItems = [orion, whisky]
        result.software = [sw]
        result.verdicts = [evaluate(sw)]
        result.outdated = [OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1", latestVersion: "2")]
        XCTAssertEqual(result.verdicts[0].tier, "remove")
        let leftovers = dryRunScript(command: "leftovers", result: result, category: ["orion"])
        XCTAssertTrue(leftovers.contains("Orion"), leftovers)
        XCTAssertTrue(leftovers.contains("com.kagi.kagimacOS"), leftovers)
        XCTAssertFalse(leftovers.contains("Whisky"), leftovers)
        XCTAssertFalse(leftovers.contains("brew uninstall"), leftovers)
        XCTAssertFalse(leftovers.contains("brew upgrade"), leftovers)
        let stale = dryRunScript(command: "stale", result: result)
        XCTAssertTrue(stale.contains("brew uninstall --cask the-unarchiver"), stale)
        XCTAssertFalse(stale.contains("Orion"), stale)
        let outdated = dryRunScript(command: "outdated", result: result)
        XCTAssertTrue(outdated.contains("# brew upgrade wget"), outdated)
        XCTAssertFalse(scriptHasActionableCommands(outdated), outdated)
        XCTAssertFalse(outdated.contains("rm -rf"), outdated)
        let update = dryRunScript(command: "update", result: result)
        XCTAssertTrue(scriptHasActionableCommands(update), update)
        XCTAssertTrue(update.contains("brew upgrade wget"), update)
        let report = dryRunScript(command: "report", result: result)
        XCTAssertTrue(report.contains("Orion"), report)
        XCTAssertTrue(report.contains("Whisky"), report)
        XCTAssertTrue(report.contains("brew uninstall --cask the-unarchiver"), report)
        let leftoversOnly = dryRunScript(command: "report", result: result, leftoversOnly: true)
        XCTAssertTrue(leftoversOnly.contains("Orion"), leftoversOnly)
        XCTAssertTrue(leftoversOnly.contains("Whisky"), leftoversOnly)
        XCTAssertFalse(leftoversOnly.contains("brew uninstall"), leftoversOnly)
        let staleOnly = dryRunScript(command: "report", result: result, staleOnly: true)
        XCTAssertTrue(staleOnly.contains("brew uninstall --cask the-unarchiver"), staleOnly)
        XCTAssertFalse(staleOnly.contains("Orion"), staleOnly)
    }

    func testDryRunLeftoversHonorsTop() {
        let big = DataItem(
            path: "/tmp/Big",
            name: "Big",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 100
        )
        let small = DataItem(
            path: "/tmp/Small",
            name: "Small",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 1
        )
        let result = ScanResult()
        result.dataItems = [small, big]
        let script = dryRunScript(command: "leftovers", result: result, top: 1)
        XCTAssertTrue(script.contains("/tmp/Big"), script)
        XCTAssertFalse(script.contains("/tmp/Small"), script)
        let report = dryRunScript(command: "report", result: result, top: 1)
        XCTAssertTrue(report.contains("/tmp/Big"), report)
        XCTAssertFalse(report.contains("/tmp/Small"), report)
    }

    func testReportDryRunHonorsCategory() {
        let orion = DataItem(
            path: "/tmp/Orion",
            name: "Orion",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 10
        )
        let whisky = DataItem(
            path: "/tmp/Whisky",
            name: "Whisky",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 20
        )
        let result = ScanResult()
        result.dataItems = [orion, whisky]
        let script = dryRunScript(command: "report", result: result, category: ["orion"])
        XCTAssertTrue(script.contains("/tmp/Orion"), script)
        XCTAssertFalse(script.contains("/tmp/Whisky"), script)
    }
}

final class CLIFlagTests: XCTestCase {
    func testDefaultCommandIsReport() {
        XCTAssertEqual(parseCLIArguments([]).command, "report")
    }

    func testVersionFlag() {
        XCTAssertTrue(parseCLIArguments(["--version"]).version)
        XCTAssertTrue(parseCLIArguments(["report", "--version"]).version)
    }

    func testCommandsAndFlags() {
        let opts = parseCLIArguments(["leftovers", "--json", "/tmp/out.json", "--include-system", "--dry-run", "--top", "5", "--category", "caches"])
        XCTAssertEqual(opts.command, "leftovers")
        XCTAssertEqual(opts.json, "/tmp/out.json")
        XCTAssertTrue(opts.includeSystem)
        XCTAssertTrue(opts.dryRun)
        XCTAssertEqual(opts.top, 5)
        XCTAssertEqual(opts.category, ["caches"])
        XCTAssertNil(opts.error)
    }

    func testUnknownCommand() {
        XCTAssertEqual(parseCLIArguments(["serve"]).error, "unknown command: serve")
        XCTAssertEqual(parseCLIArguments(["brew-leaves"]).error, "unknown command: brew-leaves")
    }

    func testUpdateCommand() {
        XCTAssertEqual(parseCLIArguments(["update"]).command, "update")
        XCTAssertTrue(parseCLIArguments(["update", "--dry-run"]).dryRun)
    }

    func testPackagesCommand() {
        XCTAssertEqual(parseCLIArguments(["packages"]).command, "packages")
        XCTAssertTrue(cliHelpText.contains("packages"))
    }

    func testReportOnlyFlags() {
        let leftovers = parseCLIArguments(["--leftovers-only"])
        XCTAssertTrue(leftovers.leftoversOnly)
        XCTAssertNil(leftovers.error)
        let both = parseCLIArguments(["--leftovers-only", "--stale-only"])
        XCTAssertEqual(both.error, "--leftovers-only and --stale-only cannot be combined")
    }

    func testTopRejectsNegative() {
        XCTAssertEqual(parseCLIArguments(["--top", "-1"]).error, "--top requires a non-negative integer")
        XCTAssertEqual(parseCLIArguments(["--top=-2"]).error, "--top requires a non-negative integer")
        XCTAssertEqual(parseCLIArguments(["--top", "3"]).top, 3)
    }

    func testFreshFlag() {
        XCTAssertFalse(parseCLIArguments(["report"]).fresh)
        let opts = parseCLIArguments(["report", "--fresh"])
        XCTAssertTrue(opts.fresh)
        XCTAssertNil(opts.error)
        XCTAssertTrue(cliHelpText.contains("--fresh"))
    }

    func testCategoryEqualsForm() {
        let opts = parseCLIArguments(["leftovers", "--category=caches"])
        XCTAssertEqual(opts.category, ["caches"])
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["leftovers", "--category="]).error, "--category requires a value")
    }

    func testJsonEqualsForm() {
        let opts = parseCLIArguments(["report", "--json=/tmp/out.json"])
        XCTAssertEqual(opts.json, "/tmp/out.json")
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["report", "--json="]).error, "--json requires a file path")
    }
}

final class ScriptPreviewTests: XCTestCase {
    func testCommentOnlyCleanupIsNotActionable() {
        let steam = uninstallCommand(
            source: "steam",
            name: "Game",
            path: "/Users/x/Library/Application Support/Steam/steamapps/common/Game",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertTrue(steam.hasPrefix("#"), steam)
        let script = ["#!/bin/sh", "set -e", steam].joined(separator: "\n") + "\n"
        XCTAssertFalse(scriptHasActionableCommands(script), script)
        XCTAssertTrue(scriptHasActionableCommands("#!/bin/sh\nset -e\nrm -rf /tmp/Foo\n"))
        XCTAssertTrue(scriptHasActionableCommands("#!/bin/sh\nset -e\nbrew uninstall jq\n"))
    }

    func testLinuxPackageUninstallUsesNativeCommandsNotWrapperRm() {
        let flatpak = uninstallCommand(
            source: "flatpak",
            name: "Firefox",
            path: "/var/lib/flatpak/exports/share/applications/org.mozilla.Firefox.desktop",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertEqual(flatpak, "flatpak uninstall -y org.mozilla.Firefox")
        XCTAssertFalse(flatpak.contains("rm -rf"), flatpak)

        let snap = uninstallCommand(
            source: "snap",
            name: "Firefox",
            path: "/var/lib/snapd/desktop/applications/firefox_firefox.desktop",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertEqual(snap, "snap remove firefox")
        XCTAssertFalse(snap.contains("rm -rf"), snap)

        let image = uninstallCommand(
            source: "appimage",
            name: "Foo",
            path: "/home/u/Apps/Foo.AppImage",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertEqual(image, "rm -rf /home/u/Apps/Foo.AppImage")
    }

    func testPreviewScriptSkipsEmptyCleanupHeader() {
        let cleanup = "#!/bin/sh\nset -e\n# AppAttic cleanup\n\n"
        let update = "#!/bin/sh\nset -e\n# AppAttic package update\n\nbrew upgrade wget\n"
        let preview = previewScript(cleanup: cleanup, update: update)
        XCTAssertFalse(preview.contains("# AppAttic cleanup"), preview)
        XCTAssertTrue(preview.contains("brew upgrade wget"), preview)
        let both = previewScript(
            cleanup: "#!/bin/sh\nset -e\nrm -rf /tmp/Foo\n",
            update: update
        )
        XCTAssertTrue(both.contains("rm -rf /tmp/Foo"), both)
        XCTAssertTrue(both.contains("brew upgrade wget"), both)
        XCTAssertTrue(both.contains("Delete in the UI does not run these lines"), both)
        let steam = "#!/bin/sh\nset -e\n# AppAttic cleanup\n# EmuDevz: uninstall from Steam. Do not delete /tmp/steamapps/common/EmuDevz\n"
        let mixed = previewScript(cleanup: steam, update: update)
        XCTAssertTrue(mixed.contains("uninstall from Steam"), mixed)
        XCTAssertTrue(mixed.contains("brew upgrade wget"), mixed)
    }
}
