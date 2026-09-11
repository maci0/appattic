import XCTest
@testable import AppAtticScan

final class PackageTests: XCTestCase {
    func testParsePacmanOrphansNameVersionAndQuiet() {
        let qdt = """
        libfoo 1.2.3-1
        libbar 2.0.0-1
        """
        let named = parsePacmanOrphans(qdt)
        XCTAssertEqual(named.map(\.name), ["libfoo", "libbar"])
        XCTAssertEqual(named[0].manager, "pacman")
        XCTAssertEqual(named[0].kind, "orphan")
        XCTAssertEqual(named[0].version, "1.2.3-1")
        XCTAssertEqual(named[1].version, "2.0.0-1")

        let quiet = parsePacmanOrphans("libfoo\nlibbar\n")
        XCTAssertEqual(quiet.map(\.name), ["libfoo", "libbar"])
        XCTAssertNil(quiet[0].version)
    }

    func testParseAptAutoremoveRemvLines() {
        let text = """
        Reading package lists... Done
        The following packages will be REMOVED:
          libfoo0 libbar1
        0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.
        Remv libfoo0 [1.2.3]
        Remv libbar1 [2.0.0]
        """
        let pkgs = parseAptAutoremove(text)
        XCTAssertEqual(pkgs.map(\.name), ["libfoo0", "libbar1"])
        XCTAssertEqual(pkgs[0].manager, "apt")
        XCTAssertEqual(pkgs[0].kind, "orphan")
        XCTAssertEqual(pkgs[0].version, "1.2.3")
        XCTAssertEqual(pkgs[1].version, "2.0.0")
    }

    func testParseDpkgRcKeepsConfigRemnants() {
        let text = """
        ii  bash           5.2.15-2     amd64        GNU Bourne Again SHell
        rc  oldpkg         1.0-1        amd64        leftover config
        rc  gone-lib       2.2-3        amd64        unused leftover
        """
        let pkgs = parseDpkgRc(text)
        XCTAssertEqual(pkgs.map(\.name), ["oldpkg", "gone-lib"])
        XCTAssertEqual(pkgs[0].manager, "dpkg")
        XCTAssertEqual(pkgs[0].kind, "orphan")
        XCTAssertEqual(pkgs[0].version, "1.0-1")
        XCTAssertEqual(packageRemoveCommand(pkgs[0]), "apt-get purge -y oldpkg")
        XCTAssertFalse(pkgs[0].canMarkManual)
    }

    func testParseDnfUnneededNames() {
        let text = """
        Last metadata expiration check: 1:23:45 ago on Wed 26 Aug 2026.
        Packages
        Finding unneeded
        Available Upgrades
        Obsoleting Packages
        libfoo
        python3-bar
        """
        let pkgs = parseDnfUnneeded(text)
        XCTAssertEqual(pkgs.map(\.name), ["libfoo", "python3-bar"])
        XCTAssertEqual(pkgs[0].manager, "dnf")
        XCTAssertEqual(pkgs[0].kind, "orphan")
    }

    func testParseZypperUnneededTable() {
        let text = """
        S | Name   | Type    | Version | Arch   | Repository
        --+--------+---------+---------+--------+-----------
        i | libfoo | package | 1.2.3-1 | x86_64 | repo
        i | libbar | package | 2.0.0-1 | x86_64 | repo
        """
        let pkgs = parseZypperUnneeded(text)
        XCTAssertEqual(pkgs.map(\.name), ["libfoo", "libbar"])
        XCTAssertEqual(pkgs[0].manager, "zypper")
        XCTAssertEqual(pkgs[0].kind, "orphan")
        XCTAssertEqual(pkgs[0].version, "1.2.3-1")
    }

    func testParseNpmGlobalDependenciesJSON() {
        let json = """
        {
          "name": "lib",
          "dependencies": {
            "typescript": { "version": "5.4.5" },
            "prettier": { "version": "3.3.0" }
          }
        }
        """
        let pkgs = parseNpmGlobalList(json)
        XCTAssertEqual(Set(pkgs.map(\.name)), ["typescript", "prettier"])
        XCTAssertEqual(pkgs[0].manager, "npm")
        XCTAssertEqual(pkgs[0].kind, "global")
        let byName = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.name, $0) })
        XCTAssertEqual(byName["typescript"]?.version, "5.4.5")

        let nested = """
        {"dependencies":{"@vue/cli":{"version":"5.0.8","dependencies":{"evil":{"version":"1.0.0"}}}}}
        """
        let scoped = parseNpmGlobalList(nested)
        XCTAssertEqual(scoped.map(\.name), ["@vue/cli"])
        XCTAssertEqual(scoped[0].version, "5.0.8")
        XCTAssertFalse(scoped.contains { $0.name == "evil" })
    }

    func testParsePnpmGlobalJSONObjectAndArray() {
        let object = """
        { "dependencies": { "nx": { "version": "19.0.0" } } }
        """
        XCTAssertEqual(parsePnpmGlobalList(object).map(\.name), ["nx"])
        XCTAssertEqual(parsePnpmGlobalList(object)[0].manager, "pnpm")
        let array = """
        [{ "dependencies": { "nx": { "version": "19.0.0" } } }]
        """
        XCTAssertEqual(parsePnpmGlobalList(array).map(\.name), ["nx"])
    }

    func testParseBunGlobalTree() {
        let text = """
        /home/user/.bun/install/global/node_modules
        ├── typescript@5.4.5
        └── prettier@3.3.0
        """
        let pkgs = parseBunGlobalList(text)
        XCTAssertEqual(pkgs.map(\.name), ["typescript", "prettier"])
        XCTAssertEqual(pkgs[0].manager, "bun")
        XCTAssertEqual(pkgs[0].kind, "global")
        XCTAssertEqual(pkgs[0].version, "5.4.5")

        let scoped = parseBunGlobalList("└── @vue/cli@5.0.8\n")
        XCTAssertEqual(scoped.map(\.name), ["@vue/cli"])
        XCTAssertEqual(scoped[0].version, "5.0.8")
    }

    func testParsePipxListJSONAndText() {
        let json = """
        {
          "venvs": {
            "httpie": {
              "metadata": {
                "main_package": {
                  "package": "httpie",
                  "package_version": "3.2.2"
                }
              }
            }
          }
        }
        """
        let fromJSON = parsePipxList(json)
        XCTAssertEqual(fromJSON.map(\.name), ["httpie"])
        XCTAssertEqual(fromJSON[0].manager, "pipx")
        XCTAssertEqual(fromJSON[0].kind, "global")
        XCTAssertEqual(fromJSON[0].version, "3.2.2")

        let text = """
        venvs are in /home/x/.local/share/pipx/venvs
           package httpie 3.2.2, installed using Python 3.12.3
            - http
        """
        let fromText = parsePipxList(text)
        XCTAssertEqual(fromText.map(\.name), ["httpie"])
        XCTAssertEqual(fromText[0].version, "3.2.2")
    }

    func testParseUvToolList() {
        let text = """
        ruff v0.6.8
        - ruff
        httpie v3.2.2
        - http
        """
        let pkgs = parseUvToolList(text)
        XCTAssertEqual(pkgs.map(\.name), ["ruff", "httpie"])
        XCTAssertEqual(pkgs[0].manager, "uv")
        XCTAssertEqual(pkgs[0].kind, "global")
        XCTAssertEqual(pkgs[0].version, "0.6.8")
        XCTAssertEqual(pkgs[1].version, "3.2.2")
    }

    func testParsePipUserListJSON() {
        let text = """
        [{"name":"httpie","version":"3.2.2"},{"name":"requests","version":"2.28.1"}]
        """
        let pkgs = parsePipUserList(text)
        XCTAssertEqual(pkgs.map(\.name), ["httpie", "requests"])
        XCTAssertEqual(pkgs[0].manager, "pip")
        XCTAssertEqual(pkgs[0].kind, "global")
        XCTAssertEqual(pkgs[0].version, "3.2.2")
        XCTAssertTrue(parsePipUserList("not json").isEmpty)
        XCTAssertTrue(parsePipUserList("[]").isEmpty)
    }

    func testParseDenoGlobalListSkipsRuntime() {
        let pkgs = parseDenoGlobalList("deno\nfile_server\ndeployctl\n")
        XCTAssertEqual(pkgs.map(\.name), ["file_server", "deployctl"])
        XCTAssertEqual(pkgs[0].manager, "deno")
        XCTAssertEqual(pkgs[0].kind, "global")
        XCTAssertTrue(parseDenoGlobalList("deno\n").isEmpty)
        XCTAssertTrue(parseDenoGlobalList("").isEmpty)
    }

    func testEmptyAndJunkParsersStayEmpty() {
        XCTAssertTrue(parsePacmanOrphans("").isEmpty)
        XCTAssertTrue(parseAptAutoremove("Reading package lists... Done\n0 upgraded, 0 newly installed, 0 to remove").isEmpty)
        XCTAssertTrue(parseDnfUnneeded("Packages\nFinding unneeded\nAvailable Upgrades\n").isEmpty)
        XCTAssertTrue(parseZypperUnneeded("S | Name | Type | Version | Arch\n--+---+---+---+-\n").isEmpty)
        XCTAssertTrue(parseNpmGlobalList("not json").isEmpty)
        XCTAssertTrue(parseNpmGlobalList(#"{}"#).isEmpty)
        XCTAssertTrue(parsePnpmGlobalList(#"{}"#).isEmpty)
        XCTAssertTrue(parseBunGlobalList("/home/user/.bun/install/global/node_modules\n").isEmpty)
        XCTAssertTrue(parsePipxList("nothing here").isEmpty)
        XCTAssertTrue(parseUvToolList("").isEmpty)
        XCTAssertTrue(parseUvToolList("- ruff\n").isEmpty)
        XCTAssertTrue(parsePipUserList("").isEmpty)
        XCTAssertTrue(parseDenoGlobalList("deno.exe\n").isEmpty)
    }

    func testPackageRemoveCommandsAreNamedAndQuoted() {
        XCTAssertEqual(packageRemoveCommand(entry("libfoo", "pacman", "orphan")), "pacman -Rns libfoo")
        XCTAssertEqual(packageRemoveCommand(entry("libfoo0", "apt", "orphan")), "apt-get purge -y libfoo0")
        XCTAssertEqual(packageRemoveCommand(entry("libfoo", "dnf", "orphan")), "dnf remove -y libfoo")
        XCTAssertEqual(packageRemoveCommand(entry("libfoo", "zypper", "orphan")), "zypper --non-interactive rm libfoo")
        XCTAssertEqual(packageRemoveCommand(entry("typescript", "npm", "global")), "npm -g uninstall typescript")
        XCTAssertEqual(packageRemoveCommand(entry("nx", "pnpm", "global")), "pnpm remove -g nx")
        XCTAssertEqual(packageRemoveCommand(entry("prettier", "bun", "global")), "bun remove -g prettier")
        XCTAssertEqual(packageRemoveCommand(entry("httpie", "pipx", "global")), "pipx uninstall httpie")
        XCTAssertEqual(packageRemoveCommand(entry("ruff", "uv", "global")), "uv tool uninstall ruff")
        XCTAssertEqual(packageRemoveCommand(entry("httpie", "pip", "global")), "pip uninstall -y --user httpie")
        XCTAssertEqual(packageRemoveCommand(entry("file_server", "deno", "global")), "deno uninstall --global file_server")
        XCTAssertEqual(
            packageRemoveCommand(entry("foo; rm /usr/bin/snap", "npm", "global")),
            "npm -g uninstall 'foo; rm /usr/bin/snap'"
        )
    }

    func testMarkManualOnlyForDistroOrphans() {
        XCTAssertEqual(packageMarkManualCommand(entry("libfoo", "apt", "orphan")), "apt-mark manual libfoo")
        XCTAssertEqual(packageMarkManualCommand(entry("libfoo", "pacman", "orphan")), "pacman -D --asexplicit libfoo")
        XCTAssertEqual(packageMarkManualCommand(entry("libfoo", "dnf", "orphan")), "dnf mark install libfoo")
        XCTAssertEqual(packageMarkManualCommand(entry("libfoo", "zypper", "orphan")), "zypper --non-interactive install libfoo")
        XCTAssertNil(packageMarkManualCommand(entry("typescript", "npm", "global")))
        XCTAssertNil(packageMarkManualCommand(entry("libfoo", "apt", "global")))
        XCTAssertTrue(entry("libfoo", "apt", "orphan").canMarkManual)
        XCTAssertFalse(entry("typescript", "npm", "global").canMarkManual)
    }

    func testPackageActionScriptNeverUpgradesOrDeletesWrappers() {
        let script = packageActionScript(
            remove: [
                entry("libfoo", "pacman", "orphan"),
                entry("typescript", "npm", "global"),
            ],
            markManual: [
                entry("libkeep", "apt", "orphan"),
            ]
        )
        XCTAssertTrue(script.contains("rootcmd pacman -Rns libfoo"), script)
        XCTAssertTrue(script.contains("npm -g uninstall typescript"), script)
        XCTAssertTrue(script.contains("rootcmd apt-mark manual libkeep"), script)
        XCTAssertFalse(script.contains("rootcmd npm"), script)
        XCTAssertFalse(script.contains("upgrade"), script)
        XCTAssertFalse(script.contains("-Syu"), script)
        XCTAssertFalse(script.contains("dist-upgrade"), script)
        XCTAssertFalse(script.contains("zypper dup"), script)
        XCTAssertFalse(script.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("apt") && t.contains("upgrade")
        })
        XCTAssertFalse(script.contains("rm /usr/bin/flatpak"), script)
        XCTAssertFalse(script.contains("rm /usr/bin/snap"), script)
        XCTAssertTrue(scriptHasActionableCommands(script))
    }

    func testFilterAllLeavesGlobalsAndSearch() {
        let rows = [
            entry("libfoo", "pacman", "orphan", size: 100),
            entry("libbar", "apt", "orphan", size: 50),
            entry("typescript", "npm", "global", size: 20),
        ]
        XCTAssertEqual(filterPackages(rows, filter: .all).map(\.name), ["libfoo", "libbar", "typescript"])
        XCTAssertEqual(filterPackages(rows, filter: .leaves).map(\.name), ["libfoo", "libbar"])
        XCTAssertEqual(filterPackages(rows, filter: .globals).map(\.name), ["typescript"])
        XCTAssertEqual(filterPackages(rows, filter: .all, search: "type").map(\.name), ["typescript"])
        XCTAssertEqual(filterPackages(rows, filter: .leaves, search: "foo").map(\.name), ["libfoo"])
        let unknownFirst = [
            entry("zeta", "npm", "global"),
            entry("alpha", "pacman", "orphan", size: 10),
        ]
        XCTAssertEqual(filterPackages(unknownFirst, filter: .all).map(\.name), ["alpha", "zeta"])
    }

    func testCollectPackagesRoutesArchOrphansAndGlobals() {
        var cmds: [[String]] = []
        let pkgs = collectPackages(
            which: { name in
                ["pacman", "npm"].contains(name) ? "/usr/bin/\(name)" : nil
            },
            run: { cmd, _ in
                cmds.append(cmd)
                let bin = cmd.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                if bin == "pacman" { return (0, "libfoo 1.0-1\n", "") }
                if bin == "npm" {
                    return (0, #"{"dependencies":{"typescript":{"version":"5.4.5"}}}"#, "")
                }
                return (1, "", "missing")
            },
            osRelease: "ID=arch\n"
        )
        XCTAssertTrue(cmds.contains { $0.contains("-Qdt") }, "\(cmds)")
        XCTAssertTrue(cmds.contains { $0.contains("ls") || $0.joined(separator: " ").contains("ls -g") }, "\(cmds)")
        XCTAssertEqual(Set(pkgs.map(\.kind)), ["orphan", "global"])
        XCTAssertTrue(pkgs.contains { $0.name == "libfoo" && $0.manager == "pacman" })
        XCTAssertTrue(pkgs.contains { $0.name == "typescript" && $0.manager == "npm" })
        XCTAssertFalse(cmds.contains { $0.contains { $0.lowercased().contains("choco") } })
        XCTAssertFalse(cmds.contains { $0.contains { $0.lowercased().contains("nuget") } })
        XCTAssertFalse(cmds.contains { $0.contains { $0.lowercased().contains("steam") } })
        XCTAssertFalse(cmds.contains { $0.contains("mas") })
    }

    func testCollectPackagesFedoraUsesRepoqueryNotLeaves() {
        var cmds: [[String]] = []
        let pkgs = collectPackages(
            which: { name in ["dnf", "dnf5"].contains(name) ? "/usr/bin/\(name)" : nil },
            run: { cmd, _ in
                cmds.append(cmd)
                if cmd.contains("leaves") { return (0, "should-not-run\n", "") }
                if cmd.contains("repoquery") { return (0, "libfoo\n", "") }
                return (1, "", "missing")
            },
            osRelease: "ID=fedora\n"
        )
        XCTAssertTrue(pkgs.contains { $0.name == "libfoo" && $0.manager == "dnf" })
        XCTAssertTrue(cmds.contains { $0.contains("repoquery") }, "\(cmds)")
        XCTAssertFalse(cmds.contains { $0.contains("leaves") }, "\(cmds)")
    }

    func testCollectPackagesDebianUsesAptGetDryRun() {
        var cmds: [[String]] = []
        let pkgs = collectPackages(
            which: { name in name == "apt-get" ? "/usr/bin/apt-get" : nil },
            run: { cmd, _ in
                cmds.append(cmd)
                return (0, "Remv libfoo0 [1.0]\n", "")
            },
            osRelease: "ID=ubuntu\nID_LIKE=debian\n"
        )
        XCTAssertEqual(pkgs.map(\.name), ["libfoo0"])
        XCTAssertEqual(pkgs.first?.manager, "apt")
        XCTAssertTrue(
            cmds.contains { $0.contains("-s") && $0.contains("autoremove") },
            "\(cmds)"
        )
        XCTAssertFalse(
            cmds.contains { $0.contains("autoremove") && !$0.contains("-s") },
            "live apt-get autoremove must not run: \(cmds)"
        )
        XCTAssertFalse(cmds.contains { $0.joined(separator: " ").contains("apt upgrade") })
    }

    func testCollectPackagesUnknownPrefersPacmanOverApt() {
        var cmds: [[String]] = []
        let pkgs = collectPackages(
            which: { name in
                ["pacman", "apt", "apt-get"].contains(name) ? "/usr/bin/\(name)" : nil
            },
            run: { cmd, _ in
                cmds.append(cmd)
                let bin = cmd.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                if bin == "pacman" { return (0, "libfoo 1.0-1\n", "") }
                if bin == "apt-get" || bin == "apt" { return (0, "Remv should-not-run [1]\n", "") }
                return (1, "", "missing")
            },
            osRelease: "ID=somethingweird\n"
        )
        XCTAssertTrue(pkgs.contains { $0.name == "libfoo" && $0.manager == "pacman" })
        XCTAssertFalse(pkgs.contains { $0.name == "should-not-run" })
        XCTAssertTrue(cmds.contains { $0.contains("-Qdt") }, "\(cmds)")
        XCTAssertFalse(cmds.contains { $0.contains("autoremove") }, "\(cmds)")
    }

    func testCollectPackagesSkipsMissingManagers() {
        let pkgs = collectPackages(
            which: { _ in nil },
            run: { _, _ in XCTFail("should not run"); return (1, "", "") },
            osRelease: "ID=arch\n"
        )
        XCTAssertTrue(pkgs.isEmpty)
    }

    func testScanDataPackagesOptionalInOldCache() throws {
        let json = """
        {
          "scanned_at": "2026-08-17T12:00:00Z",
          "duration_s": 1,
          "brew_available": false,
          "totals": {
            "apps_installed": 0,
            "orphaned_items": 0,
            "orphaned_bytes": 0,
            "system_leftover_bytes": 0,
            "reclaimable_bytes": 0,
            "stale_apps": 0,
            "outdated_apps": 0
          },
          "leftovers": [],
          "software": []
        }
        """
        let data = try JSONDecoder().decode(ScanData.self, from: Data(json.utf8))
        XCTAssertEqual(data.packages ?? [], [])
    }

    func testScanDataPackagesRoundTripAndPrune() {
        let row = entry("libfoo", "pacman", "orphan")
        let data = sampleScanData(packages: [row])
        let pruned = pruneCleanupSelection(
            leftovers: [],
            apps: [],
            outdated: [],
            packages: ["pacman:libfoo", "pacman:gone"],
            markManual: ["pacman:libfoo", "npm:typescript"],
            data: data,
            ignoring: []
        )
        XCTAssertEqual(pruned.packages, ["pacman:libfoo"])
        XCTAssertEqual(pruned.markManual, ["pacman:libfoo"])
        let restored = scanResult(from: data)
        XCTAssertEqual(restored.packages.map(\.id), ["pacman:libfoo"])
        XCTAssertEqual(restored.toScanData().packages?.map(\.id), ["pacman:libfoo"])
    }

    func testPerformScanUsesInjectedPackages() {
        let injected = entry("libfoo", "pacman", "orphan")
        let result = performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(available: false),
            leftoverItems: [],
            leftoverAgents: [],
            linuxOutdated: [],
            appStoreOutdated: [],
            packages: [injected],
            history: HistoryIndex(),
            skipLiveUsage: true
        )
        XCTAssertEqual(result.packages.map(\.name), ["libfoo"])
        XCTAssertEqual(result.toScanData().packages?.map(\.name), ["libfoo"])
    }

    func testPerformScanMarksIncompleteWhenBrewOutdatedFailed() {
        let result = performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(available: true, outdatedFailed: true),
            leftoverItems: [],
            leftoverAgents: [],
            linuxOutdated: [],
            appStoreOutdated: [],
            packages: [],
            history: HistoryIndex(),
            skipLiveUsage: true
        )
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.toScanData().incomplete, true)
        XCTAssertTrue(scanResult(from: result.toScanData()).incomplete)
    }

    func testFingerprintMentionsPackagesEpoch() {
        let fp = scanFingerprint(which: { _ in nil }, run: { _, _ in (1, "", "") })
        XCTAssertTrue(fp.contains("packages:1"), fp)
    }
}

private func entry(
    _ name: String,
    _ manager: String,
    _ kind: String,
    size: Int? = nil
) -> PackageEntry {
    PackageEntry(
        name: name,
        manager: manager,
        kind: kind,
        version: nil,
        size_bytes: size,
        size_measured: size != nil,
        summary: nil,
        reason: nil,
        children: nil
    )
}
