import XCTest
@testable import AppAtticScan

private let brewOutdatedV2 = """
{
  "formulae": [
    {
      "name": "wget",
      "installed_versions": ["1.21.4"],
      "current_version": "1.24.5",
      "pinned": false,
      "pinned_version": null
    }
  ],
  "casks": [
    {
      "name": "visual-studio-code",
      "installed_versions": ["1.90.0"],
      "current_version": "1.92.1",
      "pinned": false,
      "pinned_version": null
    }
  ]
}
"""

final class OutdatedTests: XCTestCase {
    func testParseFormulaAndCaskFromJSONV2() {
        let pkgs = parseBrewOutdatedJSON(brewOutdatedV2)
        let byName = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.name, $0) })
        XCTAssertEqual(byName["wget"]?.manager, "brew-formula")
        XCTAssertEqual(byName["wget"]?.currentVersion, "1.21.4")
        XCTAssertEqual(byName["wget"]?.latestVersion, "1.24.5")
        XCTAssertEqual(byName["visual-studio-code"]?.manager, "brew-cask")
        XCTAssertEqual(byName["visual-studio-code"]?.currentVersion, "1.90.0")
        XCTAssertEqual(byName["visual-studio-code"]?.latestVersion, "1.92.1")
    }

    func testEmptyAndInvalidJSON() {
        XCTAssertTrue(parseBrewOutdatedJSON(#"{"formulae":[],"casks":[]}"#).isEmpty)
        XCTAssertTrue(parseBrewOutdatedJSON("not json").isEmpty)
    }

    func testQueryBrewSkipsGreedyAndReturnsEmptyOnFailure() {
        XCTAssertTrue(queryBrew("").isEmpty)
        XCTAssertTrue(queryBrew("/opt/homebrew/bin/brew", run: { _, _ in (1, "", "failed to fetch") }).isEmpty)
        var calls: [([String], TimeInterval)] = []
        _ = queryBrew("/opt/homebrew/bin/brew", run: { cmd, timeout in
            calls.append((cmd, timeout))
            return (0, #"{"formulae":[],"casks":[]}"#, "")
        })
        XCTAssertEqual(calls[0].0, ["/opt/homebrew/bin/brew", "outdated", "--json=v2"])
        XCTAssertFalse(calls[0].0.contains("--greedy"))
        XCTAssertGreaterThanOrEqual(calls[0].1, 60)
    }

    func testBrewInfoJSONYieldsDescAndCaskTitle() {
        let data: [String: Any] = [
            "formulae": [["name": "wget", "full_name": "wget", "desc": "Internet file retriever"]],
            "casks": [[
                "token": "visual-studio-code",
                "name": ["Visual Studio Code"],
                "desc": "Open-source code editor",
            ]],
        ]
        let (summaries, titles) = brewPackageMeta(data)
        XCTAssertEqual(summaries["wget"], "Internet file retriever")
        XCTAssertEqual(summaries["visual-studio-code"], "Open-source code editor")
        XCTAssertEqual(titles["visual-studio-code"], "Visual Studio Code")
        XCTAssertNil(titles["wget"])
        let pkgs = parseBrewOutdatedJSON(brewOutdatedV2)
        attachSummaries(pkgs, summaries: summaries, titles: titles)
        let byName = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.name, $0) })
        XCTAssertEqual(byName["wget"]?.summary, "Internet file retriever")
        XCTAssertNil(byName["wget"]?.title)
        XCTAssertEqual(byName["visual-studio-code"]?.summary, "Open-source code editor")
        XCTAssertEqual(byName["visual-studio-code"]?.title, "Visual Studio Code")
        let d = byName["wget"]!.toEntry()
        XCTAssertEqual(d.summary, "Internet file retriever")
        XCTAssertNil(d.title)
    }

    func testParseFlatpakUpdatesWithInstalledVersions() {
        let updates = "org.mozilla.firefox\t128.0.3\ncom.spotify.Client\t1.2.37\n"
        let installed = "org.mozilla.firefox\t127.0\ncom.spotify.Client\t1.2.30\norg.gnome.Calculator\t46.0\n"
        let pkgs = parseFlatpakUpdates(updates, installedText: installed)
        let byName = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.name, $0) })
        XCTAssertEqual(byName["org.mozilla.firefox"]?.manager, "flatpak")
        XCTAssertEqual(byName["org.mozilla.firefox"]?.currentVersion, "127.0")
        XCTAssertEqual(byName["org.mozilla.firefox"]?.latestVersion, "128.0.3")
        XCTAssertNil(byName["org.gnome.Calculator"])
        XCTAssertNil(byName["org.mozilla.firefox"]?.summary)
        XCTAssertNil(byName["org.mozilla.firefox"]?.title)
    }

    func testParseFlatpakKeepsNameAndDescription() {
        let updates = "org.mozilla.firefox\t128.0.3\tFirefox\tFast, Private & Safe Web Browser\n"
        let installed = "org.mozilla.firefox\t127.0\tFirefox\tFast, Private & Safe Web Browser\n"
        let p = parseFlatpakUpdates(updates, installedText: installed)[0]
        XCTAssertEqual(p.name, "org.mozilla.firefox")
        XCTAssertEqual(p.title, "Firefox")
        XCTAssertEqual(p.summary, "Fast, Private & Safe Web Browser")
        XCTAssertEqual(p.currentVersion, "127.0")
        XCTAssertEqual(p.latestVersion, "128.0.3")
    }

    func testQueryFlatpakAsksForDescriptionColumns() {
        var calls: [[String]] = []
        let pkgs = queryFlatpak(which: { _ in "/usr/bin/flatpak" }, run: { cmd, _ in
            calls.append(cmd)
            return (0, "org.mozilla.firefox\t128.0.3\tFirefox\tFast, Private & Safe Web Browser\n", "")
        })
        XCTAssertTrue(calls.contains { $0.joined(separator: " ").contains("name,description") })
        XCTAssertEqual(pkgs[0].title, "Firefox")
        XCTAssertEqual(pkgs[0].summary, "Fast, Private & Safe Web Browser")
    }

    func testParseSnapRefreshList() {
        let refresh = """
        Name     Version  Rev   Size   Publisher   Notes
        firefox  129.0    4336  250MB  mozilla*    -
        lxd      5.21.2   29351 -      canonical*  -
        """
        let listed = """
        Name     Version  Rev    Tracking       Publisher   Notes
        firefox  128.0    4200   latest/stable  mozilla*    -
        lxd      5.21.1   29300  latest/stable  canonical*  -
        """
        let byName = Dictionary(uniqueKeysWithValues: parseSnapRefreshList(refresh, installedText: listed).map { ($0.name, $0) })
        XCTAssertEqual(byName["firefox"]?.manager, "snap")
        XCTAssertEqual(byName["firefox"]?.currentVersion, "128.0")
        XCTAssertEqual(byName["firefox"]?.latestVersion, "129.0")
        XCTAssertEqual(byName["lxd"]?.latestVersion, "5.21.2")
    }

    func testSnapAllUpToDateIsEmpty() {
        XCTAssertTrue(parseSnapRefreshList("All snaps up to date.\n").isEmpty)
    }

    func testParseAptUpgradable() {
        let text = """
        Listing...
        git/stable 1:2.39.5-0+deb12u2 amd64 [upgradable from: 1:2.39.2-1.1]
        code/stable 1.90.2-1718 amd64 [upgradable from: 1.90.0-1600]
        """
        let byName = Dictionary(uniqueKeysWithValues: parseAptUpgradable(text).map { ($0.name, $0) })
        XCTAssertEqual(byName["git"]?.manager, "apt")
        XCTAssertEqual(byName["git"]?.currentVersion, "1:2.39.2-1.1")
        XCTAssertEqual(byName["git"]?.latestVersion, "1:2.39.5-0+deb12u2")
        XCTAssertEqual(byName["code"]?.latestVersion, "1.90.2-1718")
    }

    func testMissingLinuxToolsYieldEmptyNoCrash() {
        XCTAssertTrue(collectLinux(which: { _ in nil }).isEmpty)
    }

    func testLinuxDistroFamilyFromOsRelease() {
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=arch\n"), "arch")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=\"manjaro\"\nID_LIKE=arch\n"), "arch")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=endeavouros\nID_LIKE=arch\n"), "arch")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=fedora\n"), "fedora")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=rhel\nID_LIKE=\"fedora\"\n"), "fedora")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=opensuse-tumbleweed\nID_LIKE=\"suse opensuse\"\n"), "suse")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=ubuntu\nID_LIKE=debian\n"), "debian")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=linuxmint\nID_LIKE=\"ubuntu debian\"\n"), "debian")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=pop\nID_LIKE=\"ubuntu debian\"\n"), "debian")
        XCTAssertEqual(linuxDistroFamily(osRelease: ""), "unknown")
    }

    func testParsePacmanQu() {
        let text = """
        coreutils 9.5-1 -> 9.5-2
        firefox 129.0-1 -> 129.0.1-1
        linux 6.10.5.arch1-1 -> 6.10.6.arch1-1 [ignored]
        """
        let byName = Dictionary(uniqueKeysWithValues: parsePacmanQu(text).map { ($0.name, $0) })
        XCTAssertEqual(byName["coreutils"]?.manager, "pacman")
        XCTAssertEqual(byName["coreutils"]?.currentVersion, "9.5-1")
        XCTAssertEqual(byName["coreutils"]?.latestVersion, "9.5-2")
        XCTAssertEqual(byName["firefox"]?.latestVersion, "129.0.1-1")
        XCTAssertEqual(byName["linux"]?.latestVersion, "6.10.6.arch1-1")
        XCTAssertTrue(parsePacmanQu("").isEmpty)
    }

    func testParseDnfUpgrades() {
        let text = """
        Last metadata expiration check: 0:12:00 ago on Tue 25 Aug 2026.
        Available Upgrades
        git.x86_64                    2.45.1-1.fc40           updates
        firefox.x86_64                129.0-1.fc40            updates
        """
        let byName = Dictionary(uniqueKeysWithValues: parseDnfUpgrades(text).map { ($0.name, $0) })
        XCTAssertEqual(byName["git"]?.manager, "dnf")
        XCTAssertEqual(byName["git"]?.latestVersion, "2.45.1-1.fc40")
        XCTAssertEqual(byName["firefox"]?.latestVersion, "129.0-1.fc40")
    }

    func testParseZypperListUpdates() {
        let text = """
        Loading repository data...
        S | Repository | Name | Current Version | Available Version | Arch
        --+------------+------+-----------------+-------------------+-------
        v | Update     | git  | 2.43.0-1.1      | 2.45.1-1.1        | x86_64
        v | OSS        | vim  | 9.1-1           | 9.1-2             | x86_64
        """
        let byName = Dictionary(uniqueKeysWithValues: parseZypperListUpdates(text).map { ($0.name, $0) })
        XCTAssertEqual(byName["git"]?.manager, "zypper")
        XCTAssertEqual(byName["git"]?.currentVersion, "2.43.0-1.1")
        XCTAssertEqual(byName["git"]?.latestVersion, "2.45.1-1.1")
        XCTAssertEqual(byName["vim"]?.latestVersion, "9.1-2")
    }

    func testCollectLinuxOnArchQueriesPacmanNotApt() {
        var cmds: [[String]] = []
        let pkgs = collectLinux(
            which: { name in
                switch name {
                case "pacman", "apt", "flatpak", "snap": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmds.append(cmd)
                if cmd.contains("-Qu") { return (1, "firefox 129.0-1 -> 129.0.1-1\n", "") }
                return (0, "", "")
            },
            osRelease: "ID=arch\nID_LIKE=archlinux\n"
        )
        XCTAssertEqual(pkgs.map(\.name), ["firefox"])
        XCTAssertEqual(pkgs.first?.manager, "pacman")
        XCTAssertTrue(cmds.contains { $0.contains("-Qu") })
        XCTAssertFalse(cmds.contains { $0.contains("list") && $0.contains("--upgradable") })
    }

    func testCollectLinuxOnUbuntuQueriesAptNotPacman() {
        var cmds: [[String]] = []
        _ = collectLinux(
            which: { name in
                switch name {
                case "pacman", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmds.append(cmd)
                return (0, "", "")
            },
            osRelease: "ID=ubuntu\nID_LIKE=debian\n"
        )
        XCTAssertTrue(cmds.contains { $0.contains("--upgradable") })
        XCTAssertFalse(cmds.contains { $0.contains("-Qu") })
    }

    func testQueryPacmanKeepsUpdatesWhenExitIsOne() {
        let pkgs = queryPacman(which: { _ in "/usr/bin/pacman" }, run: { _, _ in
            (1, "coreutils 9.5-1 -> 9.5-2\n", "")
        })
        XCTAssertEqual(pkgs.map(\.name), ["coreutils"])
    }

    func testCollectLinuxOnFedoraQueriesDnfNotApt() {
        var cmds: [[String]] = []
        _ = collectLinux(
            which: { name in
                switch name {
                case "dnf", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmds.append(cmd)
                return (0, "", "")
            },
            osRelease: "ID=fedora\n"
        )
        XCTAssertTrue(cmds.contains { $0.contains("--upgrades") || $0.contains("check-update") })
        XCTAssertFalse(cmds.contains { $0.contains("--upgradable") })
        XCTAssertFalse(cmds.contains { $0.contains("-Qu") })
    }

    func testCollectLinuxOnSuseQueriesZypperNotApt() {
        var cmds: [[String]] = []
        _ = collectLinux(
            which: { name in
                switch name {
                case "zypper", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmds.append(cmd)
                return (0, "", "")
            },
            osRelease: "ID=opensuse-leap\nID_LIKE=\"suse opensuse\"\n"
        )
        XCTAssertTrue(cmds.contains { $0.contains("list-updates") })
        XCTAssertFalse(cmds.contains { $0.contains("--upgradable") })
    }

    func testCollectLinuxUnknownPrefersPacmanOverApt() {
        var cmds: [[String]] = []
        _ = collectLinux(
            which: { name in
                switch name {
                case "pacman", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmds.append(cmd)
                return (0, "", "")
            },
            osRelease: "ID=somethingweird\n"
        )
        XCTAssertTrue(cmds.contains { $0.contains("-Qu") })
        XCTAssertFalse(cmds.contains { $0.contains("--upgradable") })
    }

    func testQueryDnfKeepsUpdatesWhenExitIsHundred() {
        let pkgs = queryDnf(which: { name in name == "dnf" ? "/usr/bin/dnf" : nil }, run: { _, _ in
            (100, "git.x86_64                    2.45.1-1.fc40           updates\n", "")
        })
        XCTAssertEqual(pkgs.map(\.name), ["git"])
        XCTAssertEqual(pkgs.first?.manager, "dnf")
        XCTAssertEqual(pkgs.first?.latestVersion, "2.45.1-1.fc40")
    }

    func testOutdatedReportCommentsNativeLinuxUpgrades() {
        let script = outdatedReportScript(
            [
                OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2"),
                OutdatedPkg(name: "git", manager: "dnf", currentVersion: "1", latestVersion: "2"),
                OutdatedPkg(name: "vim", manager: "zypper", currentVersion: "1", latestVersion: "2"),
            ],
            scannedAt: Date()
        )
        XCTAssertTrue(script.contains("# pacman -S firefox"), script)
        XCTAssertTrue(script.contains("# dnf upgrade git"), script)
        XCTAssertTrue(script.contains("# zypper update vim"), script)
    }

    func testOutdatedReportFooterMentionsNativeLinuxAsReportOnly() {
        let lines = outdatedReportFooter([
            OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2"),
        ])
        XCTAssertTrue(lines.contains(where: { $0.contains("report-only") && $0.contains("pacman") }), "\(lines)")
        XCTAssertTrue(lines.contains(where: { $0.contains("dnf") }), "\(lines)")
        XCTAssertTrue(lines.contains(where: { $0.contains("zypper") }), "\(lines)")
    }

    func testUpdateScriptEmptyMentionsNativeLinuxManagers() {
        let script = updateScript([
            OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2"),
        ])
        XCTAssertTrue(script.contains("pacman"), script)
        XCTAssertTrue(script.contains("dnf"), script)
        XCTAssertTrue(script.contains("zypper"), script)
        XCTAssertFalse(script.contains("\npacman -S "), script)
    }

    func testApplyMarksFormulaAndCaskSoftware() {
        let wget = Software(name: "wget", kind: "formula", path: "/opt/homebrew/bin/wget", source: "brew-formula", version: "1.21.4")
        let code = Software(name: "Visual Studio Code", kind: "app", path: "/Applications/Visual Studio Code.app", source: "brew-cask", version: "1.90.0", caskName: "visual-studio-code")
        let firefox = Software(name: "Firefox", kind: "app", path: "/usr/bin/firefox", source: "pkg/other", pkgId: "org.mozilla.firefox")
        applyOutdated([wget, code, firefox], pkgs: [
            OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1.21.4", latestVersion: "1.24.5", summary: "Internet file retriever"),
            OutdatedPkg(name: "visual-studio-code", manager: "brew-cask", currentVersion: "1.90.0", latestVersion: "1.92.1"),
            OutdatedPkg(name: "org.mozilla.firefox", manager: "flatpak", currentVersion: "127.0", latestVersion: "128.0.3"),
        ])
        XCTAssertTrue(wget.outdated)
        XCTAssertEqual(wget.latestVersion, "1.24.5")
        XCTAssertEqual(wget.summary, "Internet file retriever")
        XCTAssertTrue(code.outdated)
        XCTAssertTrue(firefox.outdated)
        XCTAssertEqual(firefox.currentVersion, "127.0")
    }

    func testOutdatedReasonNamesVersions() {
        let text = outdatedReason(OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1.21.4", latestVersion: "1.24.5"))
        XCTAssertTrue(text.contains("1.21.4"))
        XCTAssertTrue(text.contains("1.24.5"))
        XCTAssertTrue(text.contains("Homebrew"))
    }

    func testOutdatedCopiesSoftwareSummaryWhenMissing() {
        let pkg = OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1.21.4", latestVersion: "1.24.5")
        let sw = Software(name: "wget", kind: "formula", path: "/opt/homebrew/bin/wget", source: "brew-formula", summary: "Internet file retriever")
        attachSummariesFromSoftware([sw], pkgs: [pkg])
        XCTAssertEqual(pkg.summary, "Internet file retriever")
    }

    func testRecentlyUsedOutdatedAppStaysKeep() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "wget",
            kind: "formula",
            path: "/opt/homebrew/bin/wget",
            source: "brew-formula",
            lastUsed: now.addingTimeInterval(-86400),
            version: "1.21.4",
            isLeaf: true,
            bins: ["wget"],
            outdated: true,
            latestVersion: "1.24.5"
        )
        XCTAssertEqual(evaluate(sw, now: now).tier, "keep")
    }

    func testScanResultJSONIncludesOutdatedFields() {
        let sw = Software(name: "wget", kind: "formula", path: "/opt/homebrew/bin/wget", source: "brew-formula", version: "1.21.4", outdated: true, latestVersion: "1.24.5")
        let result = ScanResult()
        result.software = [sw]
        result.outdated = [OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1.21.4", latestVersion: "1.24.5")]
        let d = result.toScanData()
        XCTAssertEqual(d.totals.outdated_apps, 1)
        XCTAssertEqual(d.software[0].outdated, true)
        XCTAssertEqual(d.software[0].current_version, "1.21.4")
        XCTAssertEqual(d.outdated?[0].name, "wget")
        XCTAssertEqual(d.outdated?[0].kind, "formula")
        XCTAssertTrue(d.outdated?[0].reason?.contains("1.21.4") == true)
        XCTAssertEqual(d.outdated?[0].summary?.isEmpty, false)
    }

    func testCleanupScriptCommentsUpgradeDoesNotRunIt() {
        let result = ScanResult()
        result.software = [Software(name: "wget", kind: "formula", path: "/opt/homebrew/bin/wget", source: "brew-formula", outdated: true)]
        result.outdated = [OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1.21.4", latestVersion: "1.24.5")]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("# brew upgrade wget"))
        XCTAssertFalse(script.contains("\nbrew upgrade wget\n"))
    }

    func testUntrustedCaskIsListedAndNotUpdatable() {
        let wget = OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1.21.4", latestVersion: "1.24.5")
        let merged = applyUntrustedCasks([wget], refused: [UntrustedCask(name: "notepadnext", tap: "dail8859/notepadnext")])
        XCTAssertEqual(merged.count, 2)
        let untrusted = merged.first { $0.name == "notepadnext" }
        XCTAssertEqual(untrusted?.kind, "untrusted")
        XCTAssertFalse(untrusted?.updatable ?? true)
        XCTAssertTrue(untrusted?.reason?.contains("dail8859/notepadnext") == true)
        let data = ScanResult()
        data.outdated = merged
        let entries = data.toScanData().outdated ?? []
        XCTAssertTrue(entries.contains { $0.name == "notepadnext" && $0.kind == "untrusted" })
    }

    func testUpdateScriptUpgradesBrewAndFlatpakSkipsUntrustedAndMas() {
        let pkgs = [
            OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "iterm2", manager: "brew-cask", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "org.mozilla.firefox", manager: "flatpak", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "notepadnext", manager: "brew-cask", kind: "untrusted"),
            OutdatedPkg(name: "iMovie", manager: "app-store", currentVersion: "1", latestVersion: "2"),
        ]
        let script = updateScript(pkgs)
        XCTAssertTrue(script.contains("\nbrew upgrade wget\n"))
        XCTAssertTrue(script.contains("brew upgrade --cask iterm2"))
        XCTAssertTrue(script.contains("flatpak update -y org.mozilla.firefox"))
        XCTAssertFalse(script.contains("notepadnext"))
        XCTAssertFalse(script.contains("iMovie"))
        XCTAssertFalse(script.contains("mas "))
    }

    func testPerformScanSurfacesInjectedUntrustedCask() {
        let result = performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(
                available: true,
                casks: [Cask(name: "notepadnext", untrustedTap: "dail8859/notepadnext")],
                untrustedCasks: [UntrustedCask(name: "notepadnext", tap: "dail8859/notepadnext")]
            ),
            leftoverItems: [],
            leftoverAgents: [],
            linuxOutdated: [],
            appStoreOutdated: [],
            packages: [],
            history: HistoryIndex(),
            skipLiveUsage: true
        )
        XCTAssertTrue(result.outdated.contains { $0.name == "notepadnext" && $0.kind == "untrusted" })
    }

    func testCleanupScriptCommentsAppStoreDoesNotUpgrade() {
        let result = ScanResult()
        result.outdated = [OutdatedPkg(name: "com.apple.iMovieApp", manager: "app-store", currentVersion: "10.4.3", latestVersion: "10.4.4", title: "iMovie")]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("# App Store: com.apple.iMovieApp"))
        XCTAssertFalse(script.contains("mas upgrade"))
        XCTAssertFalse(script.contains("softwareupdate"))
    }

    func testOutdatedReportFooterDependsOnManagers() {
        let brew = OutdatedPkg(name: "wget", manager: "brew-formula", currentVersion: "1", latestVersion: "2")
        let store = OutdatedPkg(name: "iMovie", manager: "app-store", currentVersion: "1", latestVersion: "2")
        let untrusted = OutdatedPkg(
            name: "notepadnext",
            manager: "brew-cask",
            currentVersion: "1",
            latestVersion: nil,
            kind: "untrusted"
        )
        let brewLines = outdatedReportFooter([brew])
        XCTAssertTrue(brewLines.contains(where: { $0.contains("Homebrew and Flatpak") }))
        XCTAssertFalse(brewLines.contains(where: { $0.contains("report-only") }))
        let storeLines = outdatedReportFooter([store])
        XCTAssertFalse(storeLines.contains(where: { $0.contains("Homebrew and Flatpak") }))
        XCTAssertTrue(storeLines.contains(where: { $0.contains("report-only") }))
        let onlyUntrusted = outdatedReportFooter([untrusted])
        XCTAssertTrue(onlyUntrusted.contains(where: { $0.contains("Untrusted casks") }))
        XCTAssertFalse(onlyUntrusted.contains(where: { $0.contains("report-only") }))
        let mix = outdatedReportFooter([brew, store, untrusted])
        XCTAssertTrue(mix.contains(where: { $0.contains("Homebrew and Flatpak") }))
        XCTAssertTrue(mix.contains(where: { $0.contains("Untrusted casks") }))
        XCTAssertTrue(mix.contains(where: { $0.contains("report-only") }))
    }

    func testParseMasOutdatedLines() {
        let text = "409183694 Keynote (14.4 -> 14.5)\n408981434 iMovie (10.4.3 -> 10.4.4)\n"
        let pkgs = parseMasOutdated(text)
        let byTitle = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.title ?? "", $0) })
        XCTAssertEqual(byTitle["Keynote"]?.manager, "app-store")
        XCTAssertEqual(byTitle["Keynote"]?.name, "409183694")
        XCTAssertEqual(byTitle["Keynote"]?.currentVersion, "14.4")
        XCTAssertEqual(byTitle["iMovie"]?.currentVersion, "10.4.3")
        XCTAssertTrue(parseMasOutdated("").isEmpty)
        XCTAssertTrue(parseMasOutdated("No outdated apps\n").isEmpty)
    }

    func testStoreCountriesPrefersAppleRegion() {
        XCTAssertEqual(storeCountries("en_US@rg=sgzzzz"), ["sg", "us"])
        XCTAssertEqual(storeCountries("en_AU.UTF-8"), ["au", "us"])
        XCTAssertEqual(storeCountries(""), ["us"])
    }

    func testVersionNewerPadsAndStripsTrailingZeros() {
        XCTAssertTrue(versionNewer("10.4.4", "10.4.3"))
        XCTAssertFalse(versionNewer("14.5.0", "14.5"))
        XCTAssertFalse(versionNewer("14.5", "14.5.0"))
        XCTAssertFalse(versionNewer("26.6", "26.6"))
        XCTAssertTrue(versionNewer("15.0", "14.5"))
    }

    func testItunesRowRequiresExactBundleId() {
        let data: [String: Any] = [
            "resultCount": 1,
            "results": [[
                "bundleId": "com.apple.Keynote",
                "kind": "software",
                "version": "15.3",
                "trackName": "Keynote: Design Presentations",
                "description": "Make slides on iPhone.",
            ]],
        ]
        XCTAssertNil(itunesRowForBundle(data, bundleId: "com.apple.iWork.Keynote"))
        XCTAssertEqual(itunesRowForBundle(data, bundleId: "com.apple.Keynote")?["version"] as? String, "15.3")
    }

    func testPkgFromItunesRowWhenStoreIsNewer() {
        let row: [String: Any] = [
            "bundleId": "com.apple.iMovieApp",
            "kind": "mac-software",
            "version": "10.4.4",
            "trackName": "iMovie",
            "description": "With a streamlined design and intuitive editing features, iMovie lets you create Hollywood-style trailers.\n\nMore text.",
        ]
        let pkg = pkgFromItunes(displayName: "iMovie", bundleId: "com.apple.iMovieApp", current: "10.4.3", row: row)!
        XCTAssertEqual(pkg.manager, "app-store")
        XCTAssertEqual(pkg.name, "com.apple.iMovieApp")
        XCTAssertEqual(pkg.title, "iMovie")
        XCTAssertEqual(pkg.currentVersion, "10.4.3")
        XCTAssertEqual(pkg.latestVersion, "10.4.4")
        XCTAssertTrue(pkg.summary?.hasPrefix("With a streamlined design") == true)
        XCTAssertFalse(pkg.summary?.contains("More text") == true)
        XCTAssertNil(pkgFromItunes(displayName: "iMovie", bundleId: "com.apple.iMovieApp", current: "10.4.4", row: row))
        XCTAssertNil(pkgFromItunes(displayName: "iMovie", bundleId: "com.apple.iMovieApp", current: "10.4.4.0", row: ["bundleId": "com.apple.iMovieApp", "version": "10.4.4", "trackName": "iMovie"]))
    }

    func testCollectAppstoreUsesReceiptAppsAndLookup() {
        let movie = AppRecord(path: "/Applications/iMovie.app", displayName: "iMovie", bundleId: "com.apple.iMovieApp", extra: ["mas_receipt": "1", "version": "10.4.3"])
        let chrome = AppRecord(path: "/Applications/Google Chrome.app", displayName: "Google Chrome", bundleId: "com.google.Chrome", extra: ["version": "128.0"])
        let lookups: [String: [String: Any]] = [
            "com.apple.iMovieApp": [
                "bundleId": "com.apple.iMovieApp",
                "version": "10.4.4",
                "trackName": "iMovie",
                "description": "Edit video on your Mac.",
            ],
        ]
        let pkgs = collectAppstore([movie, chrome], lookup: { lookups[$0] })
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs[0].name, "com.apple.iMovieApp")
        XCTAssertEqual(pkgs[0].latestVersion, "10.4.4")
        XCTAssertEqual(pkgs[0].summary, "Edit video on your Mac.")
    }

    func testParseMdlsMasAdamIdAndCategory() {
        let text = """
        kMDItemAppStoreAdamID                   = 408981434
        kMDItemAppStoreCategory                 = "Video"
        """
        let (adam, cat) = parseMdlsMas(text)
        XCTAssertEqual(adam, "408981434")
        XCTAssertEqual(cat, "Video")
        let empty = parseMdlsMas("kMDItemAppStoreAdamID = (null)\nkMDItemAppStoreCategory = (null)\n")
        XCTAssertNil(empty.0)
        XCTAssertNil(empty.1)
    }

    func testIndexItunesResultsKeysIdAndBundle() {
        let data: [String: Any] = [
            "results": [[
                "trackId": 408981434,
                "bundleId": "com.apple.iMovieApp",
                "version": "10.4.4",
                "trackName": "iMovie",
                "description": "Edit video on your Mac.",
            ]],
        ]
        let idx = indexItunesResults(data)
        XCTAssertEqual(idx["408981434"]?["version"] as? String, "10.4.4")
        XCTAssertEqual(idx["com.apple.iMovieApp"]?["trackName"] as? String, "iMovie")
    }

    func testCollectAppstoreMatchesAdamIdCatalog() {
        let movie = AppRecord(
            path: "/Applications/iMovie.app",
            displayName: "iMovie",
            bundleId: "com.apple.iMovieApp",
            extra: ["mas_receipt": "1", "version": "10.4.3", "mas_adam_id": "408981434"]
        )
        let row: [String: Any] = [
            "trackId": 408981434,
            "bundleId": "com.apple.iMovieApp",
            "version": "10.4.4",
            "trackName": "iMovie",
            "description": "Edit video on your Mac.",
        ]
        let pkgs = collectAppstore([movie], catalog: ["408981434": row])
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs[0].latestVersion, "10.4.4")
    }

    func testAttachItunesMetaFillsBundleIdAndSummary() {
        let pkgs = [OutdatedPkg(name: "408981434", manager: "app-store", currentVersion: "10.4.3", latestVersion: "10.4.4", title: "iMovie")]
        attachItunesMeta(pkgs, catalog: [
            "408981434": [
                "trackId": 408981434,
                "bundleId": "com.apple.iMovieApp",
                "trackName": "iMovie",
                "description": "Edit video on your Mac.",
            ],
        ])
        XCTAssertEqual(pkgs[0].name, "com.apple.iMovieApp")
        XCTAssertEqual(pkgs[0].summary, "Edit video on your Mac.")
    }

    func testQueryMasSkipsAccurateFlag() {
        var calls: [[String]] = []
        let pkgs = queryMas(which: { _ in "/opt/homebrew/bin/mas" }, run: { cmd, _ in
            calls.append(cmd)
            return (0, "408981434 iMovie (10.4.3 -> 10.4.4)\n", "")
        })
        XCTAssertEqual(Array(calls[0].prefix(2)), ["/opt/homebrew/bin/mas", "outdated"])
        XCTAssertFalse(calls[0].contains("--accurate"))
        XCTAssertEqual(pkgs[0].title, "iMovie")
        XCTAssertTrue(queryMas(which: { _ in nil }).isEmpty)
    }

    func testApplyMarksAppStoreByBundleId() {
        let movie = Software(name: "iMovie", kind: "app", path: "/Applications/iMovie.app", source: "pkg/other", version: "10.4.3", bundleId: "com.apple.iMovieApp")
        applyOutdated([movie], pkgs: [OutdatedPkg(name: "com.apple.iMovieApp", manager: "app-store", currentVersion: "10.4.3", latestVersion: "10.4.4", title: "iMovie")])
        XCTAssertTrue(movie.outdated)
        XCTAssertEqual(movie.latestVersion, "10.4.4")
    }
}
