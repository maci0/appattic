import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        XCTAssertTrue(queryBrewStatus("").pkgs.isEmpty)
        XCTAssertFalse(queryBrewStatus("").failed)
        XCTAssertTrue(queryBrewStatus("/opt/homebrew/bin/brew", run: { _, _ in (1, "", "failed to fetch") }).pkgs.isEmpty)
        XCTAssertTrue(queryBrewStatus("/opt/homebrew/bin/brew", run: { _, _ in (1, "", "failed to fetch") }).failed)
        var calls: [([String], TimeInterval)] = []
        let empty = queryBrewStatus("/opt/homebrew/bin/brew", run: { cmd, timeout in
            calls.append((cmd, timeout))
            return (0, #"{"formulae":[],"casks":[]}"#, "")
        }).pkgs
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(calls[0].0, ["/opt/homebrew/bin/brew", "outdated", "--json=v2"])
        XCTAssertFalse(calls[0].0.contains("--greedy"))
        // Exactly, not `>= 60`: this call reaches the network, so a lower
        // bound is satisfied by an unbounded wait too.
        XCTAssertEqual(calls[0].1, 90, "brew outdated is bounded, not left open")
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
        let meta = brewPackageMeta(from: data)
        let (summaries, titles) = (meta.summaries, meta.titles)
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
        let callsLock = NSLock()
        let pkgs = queryFlatpak(which: { _ in "/usr/bin/flatpak" }, run: { cmd, _ in
            callsLock.lock()
            calls.append(cmd)
            callsLock.unlock()
            return (0, "org.mozilla.firefox\t128.0.3\tFirefox\tFast, Private & Safe Web Browser\n", "")
        })
        XCTAssertTrue(calls.contains { $0.joined(separator: " ").contains("name,description") })
        XCTAssertEqual(pkgs[0].title, "Firefox")
        XCTAssertEqual(pkgs[0].summary, "Fast, Private & Safe Web Browser")
    }

    /// `remote-ls` says which updates exist and `list` says which version is
    /// installed. With the second one failing every row reports no current
    /// version, and that is what the report prints and the scan cache stores:
    /// an unknown, recorded so the scan is not kept as a complete answer.
    func testFailedFlatpakListIsRecordedNotAVersionOfNothing() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let updates = "org.mozilla.firefox\t128.0.3\tFirefox\tFast, Private & Safe Web Browser\n"
        let pkgs = queryFlatpak(
            which: { _ in "/usr/bin/flatpak" },
            run: { cmd, _ in cmd.contains("remote-ls") ? (0, updates, "") : (1, "", "boom") }
        )
        XCTAssertEqual(pkgs.map(\.name), ["org.mozilla.firefox"])
        XCTAssertNil(pkgs[0].currentVersion)
        XCTAssertEqual(scanCheckFailures(), ["flatpak-list"])
    }

    /// The same for `snap`: the refresh list answered, so the update is real,
    /// but the current version behind it is unknown, not absent.
    func testFailedSnapListIsRecordedNotAVersionOfNothing() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let refresh = """
        Name     Version  Rev   Size   Publisher   Notes
        firefox  129.0    4336  250MB  mozilla*    -
        """
        let pkgs = querySnap(
            which: { _ in "/usr/bin/snap" },
            run: { cmd, _ in cmd.contains("refresh") ? (0, refresh, "") : (1, "", "boom") }
        )
        XCTAssertEqual(pkgs.map(\.name), ["firefox"])
        XCTAssertNil(pkgs[0].currentVersion)
        XCTAssertEqual(scanCheckFailures(), ["snap-list"])
    }

    /// `zypper list-updates` failing is not "no updates": it returns nothing,
    /// which is the same shape an up-to-date host produces, so the failure has
    /// to be recorded or the report claims the system is current. The command
    /// line is pinned too, since a changed flag makes the check fail on every
    /// SUSE host and the empty result would look like a clean bill of health.
    func testFailedZypperCheckIsRecordedAndAsksForTheListNonInteractively() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        var calls: [[String]] = []
        let callsLock = NSLock()
        let ok = queryZypper(
            which: { _ in "/usr/bin/zypper" },
            run: { cmd, _ in
                callsLock.lock()
                calls.append(cmd)
                callsLock.unlock()
                return (0, "", "")
            }
        )
        XCTAssertTrue(ok.isEmpty)
        XCTAssertEqual(calls.map { $0.joined(separator: " ") }, ["/usr/bin/zypper --non-interactive list-updates"])
        XCTAssertEqual(scanCheckFailures(), [])

        resetScanCheckFailures()
        let failed = queryZypper(
            which: { _ in "/usr/bin/zypper" },
            run: { _, _ in (1, "", "boom") }
        )
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(scanCheckFailures(), ["zypper"])

        // No zypper on the host is not a failed check: nothing to run means
        // nothing to report.
        resetScanCheckFailures()
        let absent = queryZypper(which: { _ in nil }, run: { _, _ in (1, "", "must not run") })
        XCTAssertTrue(absent.isEmpty)
        XCTAssertEqual(scanCheckFailures(), [])
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
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=cachyos\nID_LIKE=arch\n"), "arch")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=fedora\n"), "fedora")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=rhel\nID_LIKE=\"fedora\"\n"), "fedora")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=opensuse-tumbleweed\nID_LIKE=\"suse opensuse\"\n"), "suse")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=ubuntu\nID_LIKE=debian\n"), "debian")
        XCTAssertEqual(linuxDistroFamily(osRelease: "ID=arch\r\nID_LIKE=archlinux\r\n"), "arch")
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
        Packages
        Finding unneeded
        Obsoleting Packages
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
        let cmdsLock = NSLock()
        let pkgs = collectLinux(
            which: { name in
                switch name {
                case "pacman", "apt", "flatpak", "snap": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
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
        let cmdsLock = NSLock()
        let pkgs = collectLinux(
            which: { name in
                switch name {
                case "pacman", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
                if cmd.contains("--upgradable") {
                    return (0, "git/stable 1:2.39.5-0+deb12u2 amd64 [upgradable from: 1:2.39.2-1.1]\n", "")
                }
                return (0, "", "")
            },
            osRelease: "ID=ubuntu\nID_LIKE=debian\n"
        )
        XCTAssertEqual(pkgs.map(\.name), ["git"])
        XCTAssertEqual(pkgs.first?.manager, "apt")
        XCTAssertTrue(cmds.contains { $0.contains("--upgradable") })
        XCTAssertFalse(cmds.contains { $0.contains("-Qu") })
    }

    func testQueryAurUsesParuQuaAndIsUpdatable() {
        var cmds: [[String]] = []
        let pkgs = queryAur(
            which: { name in name == "paru" ? "/usr/bin/paru" : nil },
            run: { cmd, _ in
                cmds.append(cmd)
                return (1, "yay-bin 12.0-1 -> 12.1-1\n", "")
            }
        )
        XCTAssertEqual(pkgs.map(\.name), ["yay-bin"])
        XCTAssertEqual(pkgs.first?.manager, "aur")
        XCTAssertTrue(pkgs.first?.updatable ?? false)
        let cmd = updateCommand(pkgs[0]) ?? ""
        // Guarded on the helper's own update check: `paru -S` on a package
        // already at the newest version is a reinstall, not a no-op, so a
        // script that runs twice would otherwise do the work twice.
        XCTAssertEqual(
            cmd,
            "if paru -Qu yay-bin >/dev/null 2>&1; then paru --noconfirm -S yay-bin; fi"
        )
        XCTAssertTrue(cmds.contains { $0.contains("-Qua") }, "\(cmds)")
        XCTAssertFalse(cmds.contains { $0.contains("-S") })
    }

    func testQueryPacmanKeepsUpdatesWhenExitIsOne() {
        let pkgs = queryPacman(which: { _ in "/usr/bin/pacman" }, run: { _, _ in
            (1, "coreutils 9.5-1 -> 9.5-2\n", "")
        })
        XCTAssertEqual(pkgs.map(\.name), ["coreutils"])
    }

    func testCollectLinuxOnFedoraQueriesDnfNotApt() {
        var cmds: [[String]] = []
        let cmdsLock = NSLock()
        let pkgs = collectLinux(
            which: { name in
                switch name {
                case "dnf", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
                if cmd.contains("--upgrades") || cmd.contains("check-update") {
                    return (0, "git.x86_64                    2.45.1-1.fc40           updates\n", "")
                }
                return (0, "", "")
            },
            osRelease: "ID=fedora\n"
        )
        XCTAssertEqual(pkgs.map(\.name), ["git"])
        XCTAssertEqual(pkgs.first?.manager, "dnf")
        XCTAssertTrue(cmds.contains { $0.contains("--upgrades") || $0.contains("check-update") })
        XCTAssertFalse(cmds.contains { $0.contains("--upgradable") })
        XCTAssertFalse(cmds.contains { $0.contains("-Qu") })
    }

    func testCollectLinuxOnSuseQueriesZypperNotApt() {
        var cmds: [[String]] = []
        let cmdsLock = NSLock()
        let pkgs = collectLinux(
            which: { name in
                switch name {
                case "zypper", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
                if cmd.contains("list-updates") {
                    return (
                        0,
                        "S | Repository | Name | Current Version | Available Version | Arch\nv | Update | git | 2.43.0-1.1 | 2.45.1-1.1 | x86_64\n",
                        ""
                    )
                }
                return (0, "", "")
            },
            osRelease: "ID=opensuse-leap\nID_LIKE=\"suse opensuse\"\n"
        )
        XCTAssertEqual(pkgs.map(\.name), ["git"])
        XCTAssertEqual(pkgs.first?.manager, "zypper")
        XCTAssertEqual(pkgs.first?.latestVersion, "2.45.1-1.1")
        XCTAssertTrue(cmds.contains { $0.contains("list-updates") })
        XCTAssertFalse(cmds.contains { $0.contains("--upgradable") })
    }

    func testCollectLinuxUnknownPrefersPacmanOverApt() {
        var cmds: [[String]] = []
        let cmdsLock = NSLock()
        let pkgs = collectLinux(
            which: { name in
                switch name {
                case "pacman", "apt": return "/usr/bin/\(name)"
                default: return nil
                }
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
                if cmd.contains("-Qu") { return (1, "firefox 129.0-1 -> 129.0.1-1\n", "") }
                return (0, "", "")
            },
            osRelease: "ID=somethingweird\n"
        )
        XCTAssertEqual(pkgs.map(\.name), ["firefox"])
        XCTAssertEqual(pkgs.first?.manager, "pacman")
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

    func testScriptStampCarriesTheZoneOffset() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp = scriptStamp(when)
        let offset = TimeZone.current.secondsFromGMT(for: when)
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        let zone = String(format: "%02d%02d", magnitude / 3600, (magnitude % 3600) / 60)
        XCTAssertTrue(stamp.hasSuffix(" \(sign)\(zone)"), stamp)
    }

    /// The manager list in the footer is one fixed literal, so matching
    /// substrings of it against a pacman package proved nothing about pacman.
    /// What the input decides is which lines appear: an updatable package
    /// brings the upgrade line, a report-only manager brings the report-only
    /// line, and neither appears for the rest.
    func testOutdatedReportFooterLinesFollowThePackageManagers() throws {
        let pacman = OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2")
        let untrusted = OutdatedPkg(
            name: "notepadnext",
            manager: "brew-cask",
            currentVersion: "1",
            latestVersion: nil,
            kind: "untrusted"
        )
        let store = OutdatedPkg(name: "iMovie", manager: "app-store", currentVersion: "1", latestVersion: "2")
        let upgradeLine = try XCTUnwrap(outdatedReportFooter([pacman]).first)
        XCTAssertEqual(outdatedReportFooter([pacman]).count, 1)
        XCTAssertTrue(upgradeLine.contains("appattic update --dry-run"), upgradeLine)
        XCTAssertFalse(upgradeLine.contains("report-only"), upgradeLine)
        XCTAssertEqual(
            outdatedReportFooter([untrusted]),
            ["Untrusted casks stay listed. AppAttic will not trust the tap."],
            "an untrusted cask is neither upgradable nor report-only, so it raises its line alone"
        )
        XCTAssertEqual(
            outdatedReportFooter([store]),
            ["App Store and Snap stay report-only."],
            "a report-only manager is never offered as an upgrade"
        )
        XCTAssertEqual(
            outdatedReportFooter([pacman, untrusted, store]),
            [upgradeLine, "Untrusted casks stay listed. AppAttic will not trust the tap.", "App Store and Snap stay report-only."],
            "one line per branch that fires, in branch order"
        )
    }

    func testUpdateScriptIncludesNamedPacmanUpgrade() {
        let script = updateScript([
            OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2"),
        ])
        XCTAssertTrue(script.contains("rootcmd pacman --noconfirm -S firefox"), script)
        XCTAssertTrue(script.contains("Not a full distro upgrade"), script)
        XCTAssertFalse(script.contains("-Syu"), script)
    }

    func testUpdateScriptIncludesNamedAptAurYumZypper() {
        let script = updateScript([
            OutdatedPkg(name: "git", manager: "apt", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "yay-bin", manager: "aur", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "htop", manager: "yum", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "vim", manager: "zypper", currentVersion: "1", latestVersion: "2"),
        ])
        XCTAssertTrue(script.contains("rootcmd apt-get -y install --only-upgrade git"), script)
        XCTAssertTrue(
            script.contains("paru --noconfirm -S yay-bin")
                || script.contains("yay --noconfirm -S yay-bin")
                || script.contains("pikaur --noconfirm -S yay-bin"),
            script
        )
        XCTAssertTrue(script.contains("rootcmd yum upgrade -y htop"), script)
        XCTAssertTrue(script.contains("rootcmd zypper --non-interactive update vim"), script)
        XCTAssertFalse(script.contains("apt upgrade"), script)
        XCTAssertFalse(script.contains("-Syu"), script)
    }

    func testQueryYumSetsYumManagerAndUpgradeCommand() {
        let pkgs = queryDnf(which: { name in name == "yum" ? "/usr/bin/yum" : nil }, run: { _, _ in
            (100, "git.x86_64                    2.45.1-1.el7            updates\n", "")
        })
        XCTAssertEqual(pkgs.map(\.name), ["git"])
        XCTAssertEqual(pkgs.first?.manager, "yum")
        XCTAssertTrue(pkgs.first?.updatable ?? false)
        XCTAssertEqual(updateCommand(pkgs[0]), "yum upgrade -y git")
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
        XCTAssertEqual(firefox.version, "127.0")
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
        // Line by line, not by substring: `\nbrew upgrade wget\n` is only one
        // spelling, and `brew upgrade wget 2>&1` or a second space still runs
        // the upgrade.
        XCTAssertFalse(scriptHasActionableCommands(script), script)
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

    func testFailedUpdateCheckIsRecordedNotAnEmptyAnswer() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let pkgs = queryApt(which: { $0 == "apt" ? "/usr/bin/apt" : nil }, run: { _, _ in (1, "", "") })
        XCTAssertTrue(pkgs.isEmpty)
        XCTAssertEqual(scanCheckFailures(), ["apt"])
        // A check that answers is not a failure: same empty list, no record.
        resetScanCheckFailures()
        let clean = queryApt(which: { $0 == "apt" ? "/usr/bin/apt" : nil }, run: { _, _ in (0, "", "") })
        XCTAssertTrue(clean.isEmpty)
        XCTAssertTrue(scanCheckFailures().isEmpty)
    }

    func testFailedUpdateCheckKeepsTheScanOutOfTheCache() throws {
        // Every manager is "installed" and every command fails, so the check
        // is attempted on any distro and the result is an unknown, not an
        // empty outdated list.
        //
        // The failure set is process-global, so it is cleared on both sides:
        // a leftover entry from another test would satisfy the assertion
        // below without this scan recording anything.
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let result = performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(available: false),
            leftoverItems: [],
            leftoverAgents: [],
            packages: [],
            history: HistoryIndex(),
            which: { _ in "/usr/bin/appattic-missing" as String? },
            run: { _, _ in (1, "", "") },
            skipLiveUsage: true
        )
        XCTAssertTrue(result.incomplete)
        XCTAssertFalse(scanCheckFailures().isEmpty)
        let data = result.toScanData()
        XCTAssertEqual(data.incomplete, true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-failed-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try commitScanCache(includeSystem: false, data: data, before: "a", after: "a", to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCleanupScriptCommentsAppStoreDoesNotUpgrade() {
        let result = ScanResult()
        result.outdated = [OutdatedPkg(name: "com.apple.iMovieApp", manager: "app-store", currentVersion: "10.4.3", latestVersion: "10.4.4", title: "iMovie")]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("# App Store: com.apple.iMovieApp"))
        XCTAssertFalse(script.contains("mas upgrade"))
        XCTAssertFalse(script.contains("softwareupdate"))
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
        XCTAssertTrue(versionNewer(latest: "10.4.4", current: "10.4.3"))
        XCTAssertFalse(versionNewer(latest: "14.5.0", current: "14.5"))
        XCTAssertFalse(versionNewer(latest: "14.5", current: "14.5.0"))
        XCTAssertFalse(versionNewer(latest: "26.6", current: "26.6"))
        XCTAssertTrue(versionNewer(latest: "15.0", current: "14.5"))
        // An all-zero version is still a version: stripping it to an empty
        // list fell through to the string compare, which called "0" newer
        // than "1".
        XCTAssertFalse(versionNewer(latest: "0", current: "1"))
        XCTAssertTrue(versionNewer(latest: "1", current: "0.0.0"))
    }

    func testVersionNewerSurvivesOversizedDigitRun() {
        // A 20-digit component overflows Int: the version arrives from the
        // App Store, so it has to compare without trapping the scan.
        let huge = "99999999999999999999"
        XCTAssertTrue(versionNewer(latest: "\(huge).1", current: "2.0"))
        XCTAssertFalse(versionNewer(latest: "2.0", current: "\(huge).1"))
        XCTAssertFalse(versionNewer(latest: huge, current: huge))
        // Width alone no longer decides; the components after it still do.
        XCTAssertTrue(versionNewer(latest: "\(huge).2", current: "\(huge).1"))
        XCTAssertFalse(versionNewer(latest: "\(huge).1", current: "\(huge).2"))
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
        let idx = indexItunesResults(data)
        XCTAssertNil(idx["com.apple.iWork.Keynote"])
        XCTAssertEqual(idx["com.apple.Keynote"]?["version"] as? String, "15.3")
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
        XCTAssertEqual(pkgs?[0].title, "iMovie")
        XCTAssertNil(queryMas(which: { _ in nil }))
    }

    func testApplyMarksAppStoreByBundleId() {
        let movie = Software(name: "iMovie", kind: "app", path: "/Applications/iMovie.app", source: "pkg/other", version: "10.4.3", bundleId: "com.apple.iMovieApp")
        applyOutdated([movie], pkgs: [OutdatedPkg(name: "com.apple.iMovieApp", manager: "app-store", currentVersion: "10.4.3", latestVersion: "10.4.4", title: "iMovie")])
        XCTAssertTrue(movie.outdated)
        XCTAssertEqual(movie.latestVersion, "10.4.4")
    }

    func testOutdatedEntrySummaryFallbackUsesTheManagerLabel() {
        let entry = OutdatedEntry(name: "iMovie", manager: "app-store")
        XCTAssertEqual(outdatedSummaryFallback(entry), "Package managed by the App Store")
    }

    func testOutdatedEntryReasonNamesTheSurface() {
        let entry = OutdatedEntry(
            name: "wget",
            manager: "brew-formula",
            current_version: "1.21.4",
            latest_version: "1.24.5"
        )
        let text = outdatedReason(entry, page: "this page")
        XCTAssertTrue(text.contains("Homebrew"))
        XCTAssertTrue(text.contains("this page"))
        XCTAssertEqual(outdatedReason(entry), outdatedReason(OutdatedPkg(
            name: "wget",
            manager: "brew-formula",
            currentVersion: "1.21.4",
            latestVersion: "1.24.5"
        )))
    }

    func testOutdatedEntryKeepsAnExistingReason() {
        let entry = OutdatedEntry(name: "wget", manager: "brew-formula", reason: "already explained")
        XCTAssertEqual(outdatedReason(entry, page: "this page"), "already explained")
    }

    func testItunesRequestReportsFailedLookup() {
        var failures: [String] = []
        let rows = itunesRequest(["bundleId": "com.example.app", "country": "us"], session: stubURLSession(status: 403)) { failures.append($0) }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(failures, ["HTTP 403"])
    }

    func testItunesRequestReportsTransportFailure() {
        var failures: [String] = []
        let rows = itunesRequest(["bundleId": "com.example.app", "country": "us"], session: stubURLSession(status: 0, error: URLError(.notConnectedToInternet))) { failures.append($0) }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].hasPrefix("no response"), failures[0])
    }

    func testItunesRequestKeepsQuietOnSuccess() {
        var failures: [String] = []
        let body = Data(#"{"results":[{"bundleId":"com.example.app","trackName":"Example","version":"2.0"}]}"#.utf8)
        let rows = itunesRequest(["bundleId": "com.example.app", "country": "us"], session: stubURLSession(status: 200, body: body)) { failures.append($0) }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(rows["com.example.app"]?["trackName"] as? String, "Example")
    }

    func testItunesRequestReportsBodyThatIsNotJSON() {
        var failures: [String] = []
        let rows = itunesRequest(["bundleId": "com.example.app", "country": "us"], session: stubURLSession(status: 200, body: Data("<html>rate limited</html>".utf8))) { failures.append($0) }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(failures, ["the response was not JSON"])
    }

    // The storefront decides which country's prices and releases the App Store
    // answers with, so it is part of a scan's result rather than a display
    // preference. It is read from `defaults` and `LANG`: both are per-host
    // answers, and neither is reachable through a replay's substituted `run`
    // unless the caller supplies both. These pin that the seam is really the
    // one that answers, so a host whose `AppleLocale` disagrees with the
    // replayed run cannot change what the replay reports.
    func testStoreCountriesReadsDefaultsThroughTheInjectedRunner() {
        var asked: [[String]] = []
        let run: CommandRun = { cmd, _ in
            asked.append(cmd)
            return (0, "en_GB\n", "")
        }
        XCTAssertEqual(storeCountries(nil, run: run), ["gb", "us"])
        XCTAssertEqual(asked, [["defaults", "read", "-g", "AppleLocale"]])
    }

    func testStoreCountriesFallsBackToTheSuppliedEnvironment() {
        // `defaults` answered nothing usable: the answer then has to come from
        // the injected environment, not from whatever `LANG` the host running
        // the test happens to have.
        let failing: CommandRun = { _, _ in (1, "", "") }
        XCTAssertEqual(
            storeCountries(nil, run: failing, env: ["LANG": "de_DE.UTF-8"]),
            ["de", "us"]
        )
        XCTAssertEqual(
            storeCountries(nil, run: failing, env: [:]),
            ["us"],
            "no locale anywhere still answers us rather than reading the host"
        )
    }

    func testItunesLookupBatchTakesItsStorefrontFromTheInjectedRunner() {
        var asked: [[String]] = []
        let run: CommandRun = { cmd, _ in
            asked.append(cmd)
            return (0, "ja_JP.UTF-8", "")
        }
        // An empty id list returns before any storefront is resolved, so the
        // runner is never asked: nothing reaches the host either way.
        XCTAssertTrue(
            itunesLookupBatch([], session: stubURLSession(status: 200), run: run).isEmpty
        )
        XCTAssertTrue(asked.isEmpty, "no ids means no storefront lookup and no request")
    }
}

/// Answers every request with one canned status, body, or error.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubURLSession(status: Int, body: Data = Data(), error: Error? = nil) -> URLSession {
    StubURLProtocol.status = status
    StubURLProtocol.body = body
    StubURLProtocol.error = error
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}
