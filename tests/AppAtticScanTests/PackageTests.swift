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
        XCTAssertEqual(packageRemoveCommand(pkgs[0]), "if dpkg -s oldpkg >/dev/null 2>&1; then apt-get purge -y oldpkg; fi")
        // An rc row is a Debian distro package, so it takes the apt manual
        // marker. Losing this hid the only corrective action on a config remnant.
        XCTAssertTrue(pkgs[0].canMarkManual)
        XCTAssertEqual(packageMarkManualCommand(pkgs[0]), "apt-mark manual oldpkg")
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
    }

    /// Every removal is guarded so a second run over an already-removed
    /// package is a no-op instead of a `set -e` abort that strands the
    /// packages below it in the script.
    func testPackageRemoveCommandsAreNamedAndQuoted() {
        XCTAssertEqual(packageRemoveCommand(entry("libfoo", "pacman", "orphan")), "if pacman -Qq libfoo >/dev/null 2>&1; then pacman -Rns libfoo; fi")
        XCTAssertEqual(packageRemoveCommand(entry("libfoo0", "apt", "orphan")), "if dpkg -s libfoo0 >/dev/null 2>&1; then apt-get purge -y libfoo0; fi")
        XCTAssertEqual(packageRemoveCommand(entry("libfoo", "dnf", "orphan")), "if rpm -q libfoo >/dev/null 2>&1; then dnf remove -y libfoo; fi")
        XCTAssertEqual(packageRemoveCommand(entry("libfoo", "zypper", "orphan")), "if rpm -q libfoo >/dev/null 2>&1; then zypper --non-interactive rm libfoo; fi")
        XCTAssertEqual(
            packageRemoveCommand(entry("typescript", "npm", "global")),
            "if npm ls -g --depth=0 | grep -qF -- typescript@ >/dev/null 2>&1; then npm -g uninstall typescript; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("nx", "pnpm", "global")),
            "if pnpm ls -g --depth=0 | grep -qF -- nx@ >/dev/null 2>&1; then pnpm remove -g nx; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("prettier", "bun", "global")),
            "if bun pm ls -g | grep -qF -- prettier@ >/dev/null 2>&1; then bun remove -g prettier; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("httpie", "pipx", "global")),
            "if pipx list | grep -qF -- 'package httpie ' >/dev/null 2>&1; then pipx uninstall httpie; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("ruff", "uv", "global")),
            "if uv tool list | grep -qF -- 'ruff v' >/dev/null 2>&1; then uv tool uninstall ruff; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("httpie", "pip", "global")),
            "if pip show httpie >/dev/null 2>&1; then pip uninstall -y --user httpie; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("file_server", "deno", "global")),
            "if test -e ~/.deno/bin/file_server >/dev/null 2>&1; then deno uninstall --global file_server; fi"
        )
        XCTAssertEqual(
            packageRemoveCommand(entry("foo; rm /usr/bin/snap", "npm", "global")),
            "if npm ls -g --depth=0 | grep -qF -- 'foo; rm /usr/bin/snap@' >/dev/null 2>&1; then npm -g uninstall 'foo; rm /usr/bin/snap'; fi"
        )
    }

    /// The guard's presence query has to be a read-only listing, never the
    /// removal itself, or the guard is what runs the removal.
    func testPackageRemoveGuardsDoNotRemove() throws {
        for manager in ["pacman", "aur", "apt", "dpkg", "dnf", "yum", "zypper",
                        "npm", "pnpm", "bun", "pipx", "uv", "pip", "deno"] {
            let cmd = packageRemoveCommand(entry("libfoo", manager, "orphan"))
            let split = try XCTUnwrap(parseGuardedRemove(cmd), manager)
            for word in ["purge", "uninstall", "remove", "rm "] {
                XCTAssertFalse(split.present.contains(word), "\(manager) guard removes: \(cmd)")
            }
        }
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
        XCTAssertTrue(script.contains("if pacman -Qq libfoo >/dev/null 2>&1; then rootcmd pacman -Rns libfoo; fi"), script)
        XCTAssertTrue(script.contains("then npm -g uninstall typescript; fi"), script)
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

    func testFilterPackagesSearchMatchesAnFDNameAgainstAnNFCCQuery() {
        // macOS hands back NFD; the search box takes NFC.
        let rows = [entry("libCafe\u{0301}", "apt", "orphan", size: 10)]
        XCTAssertEqual(filterPackages(rows, filter: .all, search: "café").map(\.name), ["libCafe\u{0301}"])
        XCTAssertEqual(filterPackages(rows, filter: .all, search: "CAFÉ").map(\.name), ["libCafe\u{0301}"])
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
        let cmdsLock = NSLock()
        let pkgs = collectPackages(
            which: { name in
                ["pacman", "npm"].contains(name) ? "/usr/bin/\(name)" : nil
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
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
        let cmdsLock = NSLock()
        let pkgs = collectPackages(
            which: { name in ["dnf", "dnf5"].contains(name) ? "/usr/bin/\(name)" : nil },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
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
        let cmdsLock = NSLock()
        let pkgs = collectPackages(
            which: { name in name == "apt-get" ? "/usr/bin/apt-get" : nil },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
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
        let cmdsLock = NSLock()
        let pkgs = collectPackages(
            which: { name in
                ["pacman", "apt", "apt-get"].contains(name) ? "/usr/bin/\(name)" : nil
            },
            run: { cmd, _ in
                cmdsLock.lock()
                cmds.append(cmd)
                cmdsLock.unlock()
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

    /// A manager that answers with a failure status produced an unknown, not
    /// an empty list. Without a record of it the scan cache keeps the empty
    /// list for `scanCacheMaxAge` and serves it as "no orphans".
    func testFailedPackageQueryIsRecordedNotAnEmptyAnswer() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        // 2, not 1: `pacman -Qdt` exits 1 when it found no orphans, which is a
        // real answer, so 1 cannot stand in for "the command failed" here.
        let pkgs = collectPackages(
            which: { name in ["pacman", "npm"].contains(name) ? "/usr/bin/\(name)" : nil },
            run: { _, _ in (2, "", "boom") },
            osRelease: "ID=arch\n"
        )
        XCTAssertTrue(pkgs.isEmpty)
        XCTAssertEqual(scanCheckFailures(), ["npm", "pacman"])
    }

    /// `pacman -Qdt` exits 1 on a machine with no orphans. That is the answer
    /// "none", not a check that failed, and recording it would keep every such
    /// scan out of the cache for good.
    func testPacmanNoOrphansExitIsAnEmptyAnswerNotAFailure() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let pkgs = collectPackages(
            which: { name in name == "pacman" ? "/usr/bin/pacman" : nil },
            run: { _, _ in (1, "", "") },
            osRelease: "ID=arch\n"
        )
        XCTAssertTrue(pkgs.isEmpty)
        XCTAssertTrue(scanCheckFailures().isEmpty, "\(scanCheckFailures())")
    }

    /// The other half of the same rule: a manager that is not installed has
    /// nothing to report, which is a real empty answer and not a failure.
    func testMissingManagerIsNotRecordedAsAFailure() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let pkgs = collectPackages(
            which: { _ in nil },
            run: { _, _ in (1, "", "") },
            osRelease: "ID=arch\n"
        )
        XCTAssertTrue(pkgs.isEmpty)
        XCTAssertTrue(scanCheckFailures().isEmpty)
    }

    /// `pipx list --json` failing on an old pipx leaves the check alone when
    /// the plain listing answered.
    func testPackageQueryChainRecordsOnlyWhenEverySpellingFails() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        _ = collectPackages(
            which: { name in name == "pipx" ? "/usr/bin/pipx" : nil },
            run: { cmd, _ in cmd.contains("--json") ? (1, "", "no such option") : (0, "venvs []", "") },
            osRelease: "ID=arch\n"
        )
        XCTAssertTrue(scanCheckFailures().isEmpty)
        resetScanCheckFailures()
        _ = collectPackages(
            which: { name in name == "pipx" ? "/usr/bin/pipx" : nil },
            run: { _, _ in (1, "", "boom") },
            osRelease: "ID=arch\n"
        )
        XCTAssertEqual(scanCheckFailures(), ["pipx"])
    }

    /// The failure has to survive into the scan the cache sees, or the empty
    /// list is still written and still served for a day. Every manager reads
    /// as installed and every command fails, so the check is attempted on any
    /// distro: `performScan` takes no os-release.
    func testFailedPackageQueryKeepsTheScanOutOfTheCache() throws {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let result = performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(available: false),
            leftoverItems: [],
            leftoverAgents: [],
            linuxOutdated: [],
            appStoreOutdated: [],
            history: HistoryIndex(),
            which: { _ in "/usr/bin/appattic-missing" },
            run: { _, _ in (1, "", "boom") },
            skipLiveUsage: true
        )
        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.toScanData().incomplete, true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-failed-package-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try commitScanCache(includeSystem: false, data: result.toScanData(), before: "a", after: "a", to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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
