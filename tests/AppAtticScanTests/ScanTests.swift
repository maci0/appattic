import XCTest
@testable import AppAtticScan

final class ScanTests: XCTestCase {
    func testScanDataMatchesVerdictsBySoftwareIdentity() {
        let first = Software(name: "First", kind: "app", path: "/First.app", source: "test")
        let second = Software(name: "Second", kind: "app", path: "/Second.app", source: "test")
        let result = ScanResult(
            software: [first, second],
            verdicts: [
                Verdict(software: second, tier: "remove", reason: "second"),
                Verdict(software: first, tier: "review", reason: "first"),
            ]
        )

        let rows = result.toScanData().software
        XCTAssertEqual(rows.map(\.tier), ["review", "remove"])
        XCTAssertEqual(rows.map(\.reason), ["first", "second"])
    }

    func testTempTreeOrphanWithEmptyBrew() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let orphan = td.appendingPathComponent("DeadApp")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
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

    func testPerformScanVerdictsFollowInjectedNow() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let app = AppRecord(
            path: "/Applications/The Unarchiver.app",
            displayName: "The Unarchiver",
            lastUsed: now.addingTimeInterval(-400 * 86400)
        )
        let brew = BrewSnapshot(
            available: true,
            casks: [Cask(name: "the-unarchiver", appPaths: ["/Applications/The Unarchiver.app"])]
        )
        func scan(at t: Date) -> ScanResult {
            performScan(
                includeSystem: false,
                apps: [app],
                brew: brew,
                leftoverItems: [],
                leftoverAgents: [],
                linuxOutdated: [],
                appStoreOutdated: [],
                packages: [],
                history: HistoryIndex(),
                skipLiveUsage: true,
                now: t
            )
        }
        let stale = scan(at: now)
        XCTAssertEqual(stale.scannedAt, now)
        XCTAssertEqual(stale.verdicts.first?.tier, "remove")
        let recent = scan(at: now.addingTimeInterval(-395 * 86400))
        XCTAssertEqual(recent.scannedAt, now.addingTimeInterval(-395 * 86400))
        XCTAssertEqual(recent.verdicts.first?.tier, "keep")
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

    func testDryRunClassesKeepSystemDistroAndPackagesSeparate() {
        let orphan = DataItem(
            path: "/tmp/DeadApp",
            name: "DeadApp",
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
        let system = DataItem(
            path: "/tmp/SysLeftover",
            name: "SysLeftover",
            rootLabel: "Caches",
            kind: "dir",
            status: "system"
        )
        let keep = Software(
            name: "KeepMe",
            kind: "app",
            path: "/tmp/KeepMe.app",
            source: "app"
        )
        let remove = Software(
            name: "RemoveMe",
            kind: "app",
            path: "/tmp/RemoveMe.app",
            source: "brew-cask",
            lastUsed: Date().addingTimeInterval(-400 * 86400),
            caskName: "remove-me"
        )
        let result = ScanResult()
        result.dataItems = [orphan, shadow, system]
        result.software = [keep, remove]
        result.verdicts = [
            Verdict(software: keep, tier: "keep", reason: "in use"),
            Verdict(software: remove, tier: "remove", reason: "idle"),
        ]
        result.outdated = [
            OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2"),
        ]
        result.packages = [
            PackageEntry(name: "libfoo", manager: "pacman", kind: "orphan"),
        ]

        let leftovers = dryRunScript(command: "leftovers", result: result)
        XCTAssertTrue(leftovers.hasPrefix("#!/bin/sh"), leftovers)
        XCTAssertTrue(leftovers.contains("/tmp/DeadApp"), leftovers)
        XCTAssertTrue(leftovers.contains("/tmp/overlay/python3"), leftovers)
        XCTAssertFalse(leftovers.contains("/tmp/SysLeftover"), leftovers)
        XCTAssertFalse(leftovers.contains("KeepMe"), leftovers)
        XCTAssertFalse(leftovers.contains("RemoveMe"), leftovers)
        XCTAssertFalse(leftovers.contains("pacman -S"), leftovers)
        XCTAssertFalse(leftovers.contains("-Syu"), leftovers)
        XCTAssertFalse(leftovers.contains("pacman -Rns"), leftovers)

        let stale = dryRunScript(command: "stale", result: result)
        XCTAssertTrue(stale.hasPrefix("#!/bin/sh"), stale)
        XCTAssertTrue(stale.contains("brew uninstall --cask remove-me"), stale)
        XCTAssertFalse(stale.contains("KeepMe"), stale)
        XCTAssertFalse(stale.contains("/tmp/DeadApp"), stale)
        XCTAssertFalse(stale.contains("pacman -S"), stale)
        XCTAssertFalse(stale.contains("-Syu"), stale)
        XCTAssertFalse(stale.contains("upgrade"), stale)

        let outdated = dryRunScript(command: "outdated", result: result)
        XCTAssertTrue(outdated.contains("# pacman -S firefox"), outdated)
        XCTAssertFalse(scriptHasActionableCommands(outdated), outdated)
        XCTAssertFalse(outdated.contains("\npacman -S firefox"), outdated)
        XCTAssertFalse(outdated.contains("-Syu"), outdated)

        let update = dryRunScript(command: "update", result: result)
        XCTAssertTrue(update.contains("rootcmd pacman --noconfirm -S firefox"), update)
        XCTAssertFalse(update.contains("-Syu"), update)
        XCTAssertTrue(scriptHasActionableCommands(update), update)

        let packages = dryRunScript(command: "packages", result: result)
        XCTAssertTrue(packages.hasPrefix("#!/bin/sh"), packages)
        XCTAssertTrue(packages.contains("pacman -Rns libfoo"), packages)
        XCTAssertFalse(packages.contains("/tmp/DeadApp"), packages)
        XCTAssertFalse(packages.contains("brew uninstall"), packages)
        XCTAssertFalse(packages.contains("-Syu"), packages)
        XCTAssertFalse(packages.contains("upgrade"), packages)
        XCTAssertNotEqual(packages, leftovers)
        XCTAssertNotEqual(packages, stale)
        XCTAssertNotEqual(packages, outdated)

        let report = dryRunScript(command: "report", result: result)
        XCTAssertTrue(report.contains("/tmp/DeadApp"), report)
        XCTAssertTrue(report.contains("/tmp/overlay/python3"), report)
        XCTAssertTrue(report.contains("brew uninstall --cask remove-me"), report)
        XCTAssertTrue(report.contains("# pacman -S firefox"), report)
        XCTAssertFalse(report.contains("/tmp/SysLeftover"), report)
        XCTAssertFalse(report.contains("KeepMe"), report)
        XCTAssertFalse(report.contains("pacman -Rns"), report)
        XCTAssertFalse(report.contains("-Syu"), report)
        XCTAssertFalse(report.contains("\npacman -S firefox"), report)
    }
}

extension CLIFlagTests {
    func testHelpTextIncludesShortFlagsNoColorAndStderr() {
        XCTAssertTrue(cliHelpText.contains("--help, -h"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--version, -v"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--no-color"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("NO_COLOR"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("TERM=dumb"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("stderr"), cliHelpText)
        XCTAssertEqual(cliUsageHint, "Try 'appattic --help' for more information.")
    }

    func testUnknownShortOptionIsNotACommand() {
        XCTAssertEqual(parseCLIArguments(["-q"]).error, "unknown option: -q")
        XCTAssertEqual(parseCLIArguments(["-q"]).parseError, .unknownOption("-q"))
        XCTAssertEqual(parseCLIArguments(["leftovers", "-x"]).parseError, .unknownOption("-x"))
    }

    func testNoColorFlag() {
        XCTAssertFalse(parseCLIArguments(["report"]).noColor)
        let opts = parseCLIArguments(["report", "--no-color"])
        XCTAssertTrue(opts.noColor)
        XCTAssertNil(opts.error)
    }

    func testJsonRejectsFlagShapedPath() {
        XCTAssertEqual(parseCLIArguments(["--json", "--help"]).parseError, .jsonRequiresPath)
        XCTAssertEqual(parseCLIArguments(["--json=--help"]).parseError, .jsonRequiresPath)
        XCTAssertEqual(parseCLIArguments(["report", "--json", "-"]).parseError, .jsonRequiresPath)
    }

    func testColorEnabledHonorsTTYNoColorAndDumbTerm() {
        XCTAssertTrue(cliColorEnabled(stdoutIsTTY: true, env: [:]))
        XCTAssertFalse(cliColorEnabled(stdoutIsTTY: false, env: [:]))
        XCTAssertFalse(cliColorEnabled(stdoutIsTTY: true, env: [:], noColorFlag: true))
        XCTAssertFalse(cliColorEnabled(stdoutIsTTY: true, env: ["NO_COLOR": "1"]))
        XCTAssertTrue(cliColorEnabled(stdoutIsTTY: true, env: ["NO_COLOR": ""]))
        XCTAssertFalse(cliColorEnabled(stdoutIsTTY: true, env: ["TERM": "dumb"]))
        XCTAssertTrue(cliColorEnabled(stdoutIsTTY: true, env: ["TERM": "xterm-256color"]))
        XCTAssertFalse(cliColorEnabled(stdoutIsTTY: true, env: ["NO_COLOR": "1", "TERM": "xterm"]))
    }
}

final class ScriptPreviewTests: XCTestCase {
    func testBrewUninstallCommandsSkipAlreadyRemovedPackages() {
        XCTAssertEqual(
            uninstallCommand(source: "brew-formula", name: "jq", path: "/opt/homebrew/bin/jq", caskName: nil, steamAppId: nil),
            "if brew list --formula jq >/dev/null 2>&1; then brew uninstall jq; fi"
        )
        XCTAssertEqual(
            uninstallCommand(source: "brew-cask", name: "Firefox", path: "/Applications/Firefox.app", caskName: "firefox", steamAppId: nil),
            "if brew list --cask firefox >/dev/null 2>&1; then brew uninstall --cask firefox; fi"
        )
    }

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

        let packaged = uninstallCommand(
            source: "pkg/other",
            name: "Firefox",
            path: "/usr/bin/firefox",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertTrue(packaged.hasPrefix("#"), packaged)
        XCTAssertFalse(packaged.contains("rm -rf"), packaged)
        let packagedImage = uninstallCommand(
            source: "appimage",
            name: "Foo",
            path: "/usr/local/Foo.AppImage",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertTrue(packagedImage.hasPrefix("#"), packagedImage)
        XCTAssertFalse(packagedImage.contains("rm -rf"), packagedImage)
    }

    func testLinuxUninstallPrefersPkgIdWhenDesktopNameDiffers() {
        let item = SoftwareItem(
            name: "Firefox",
            kind: "app",
            path: "/home/u/.local/share/flatpak/exports/share/applications/firefox.desktop",
            source: "flatpak",
            pkg_id: "org.mozilla.Firefox"
        )
        XCTAssertEqual(uninstallCommand(for: item), "flatpak uninstall -y org.mozilla.Firefox")
        XCTAssertEqual(
            uninstallCommand(
                source: "flatpak",
                name: "Firefox",
                path: item.path,
                caskName: nil,
                steamAppId: nil
            ),
            "flatpak uninstall -y firefox"
        )
        let snap = SoftwareItem(
            name: "Code",
            kind: "app",
            path: "/var/lib/snapd/desktop/applications/code_code.desktop",
            source: "snap",
            pkg_id: "code"
        )
        XCTAssertEqual(uninstallCommand(for: snap), "snap remove code")
    }

    func testScanDataRoundTripKeepsPkgIdForUninstall() {
        let sw = Software(
            name: "Firefox",
            kind: "app",
            path: "/home/u/.local/share/flatpak/exports/share/applications/firefox.desktop",
            source: "flatpak",
            pkgId: "org.mozilla.Firefox"
        )
        let result = ScanResult()
        result.software = [sw]
        result.verdicts = [Verdict(software: sw, tier: "remove", reason: "test")]
        let restored = scanResult(from: result.toScanData())
        XCTAssertEqual(restored.software[0].pkgId, "org.mozilla.Firefox")
        XCTAssertEqual(result.toScanData().software[0].pkg_id, "org.mozilla.Firefox")
        restored.verdicts = [Verdict(software: restored.software[0], tier: "remove", reason: "test")]
        XCTAssertTrue(cleanupScript(restored).contains("flatpak uninstall -y org.mozilla.Firefox"))
        XCTAssertFalse(cleanupScript(restored).contains("flatpak uninstall -y firefox\n"))
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
