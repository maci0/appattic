import Foundation
import XCTest
@testable import AppAtticScan

final class ConfigTests: XCTestCase {
    private func settingsFile(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-config-\(UUID().uuidString).json")
        try body.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEffectiveConfigNamesTheFileAndItsValues() throws {
        let url = try settingsFile(#"{"includeSystem": true, "confirmDelete": false}"#)
        let settings = AppAtticSettings(includeSystem: true, confirmDelete: false, ignoredLeftoverPaths: ["/tmp/a"])
        let config = EffectiveConfig(settings: settings, settingsURL: url, includeSystemFlag: false, env: [:])
        XCTAssertEqual(config.settingsPath, url.path)
        XCTAssertTrue(config.settingsFileExists)
        XCTAssertTrue(config.includeSystem)
        XCTAssertFalse(config.confirmDelete)
        XCTAssertEqual(config.ignoredLeftoverPaths, ["/tmp/a"])
    }

    func testIncludeSystemFlagOnlyTurnsItOn() {
        var settings = AppAtticSettings.default
        settings.includeSystem = true
        let off = EffectiveConfig(settings: settings, env: [:])
        let on = EffectiveConfig(settings: settings, includeSystemFlag: true, env: [:])
        XCTAssertTrue(off.includeSystem)
        XCTAssertTrue(on.includeSystem)
        XCTAssertEqual(off.includeSystem, effectiveIncludeSystem(cliFlag: false, settings: settings))
        XCTAssertEqual(on.includeSystem, effectiveIncludeSystem(cliFlag: true, settings: settings))
    }

    func testMissingFileSaysSoAndUsesDefaults() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-config-absent-\(UUID().uuidString).json")
        let config = EffectiveConfig(settings: .default, settingsURL: url, env: [:])
        XCTAssertFalse(config.settingsFileExists)
        XCTAssertFalse(config.includeSystem)
        XCTAssertTrue(config.confirmDelete)
        XCTAssertTrue(config.lines.contains { $0.contains("missing, using defaults") }, "\(config.lines)")
        XCTAssertTrue(config.lines.contains { $0.contains("includeSystem: false [default]") }, "\(config.lines)")
    }

    /// The backup is the only copy of the ignore list once `settings.json` is
    /// gone or no longer loads, so `config` names it and says whether it is
    /// there. A machine diff is where a missing backup is noticed.
    func testConfigNamesTheSettingsBackupAndWhetherItIsThere() throws {
        let url = try settingsFile(#"{"ignoredLeftoverPaths": ["/tmp/a"]}"#)
        let missing = EffectiveConfig(settings: .default, settingsURL: url, env: [:])
        XCTAssertEqual(missing.settingsBackupPath, settingsBackupURL(url).path)
        XCTAssertFalse(missing.settingsBackupExists)
        XCTAssertTrue(
            missing.lines.contains { $0.contains("\(settingsBackupURL(url).path) (missing)") },
            "\(missing.lines)"
        )
        try saveSettings(AppAtticSettings(ignoredLeftoverPaths: ["/tmp/a"]), to: url)
        try saveSettings(AppAtticSettings(ignoredLeftoverPaths: ["/tmp/b"]), to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: settingsBackupURL(url)) }
        let kept = EffectiveConfig(settings: .default, settingsURL: url, env: [:])
        XCTAssertTrue(kept.settingsBackupExists)
        XCTAssertTrue(kept.lines.contains { $0.contains(settingsBackupURL(url).path) }, "\(kept.lines)")
    }

    /// The file a restore replaced is the third piece of recovery material and
    /// the only one that tells a user which generation they are looking at. It
    /// is named with the backup and says `(missing)` in the same way, so a
    /// machine diff shows the restore history as plainly as the backup.
    func testConfigNamesTheFileARestoreReplacedAndWhetherItIsThere() throws {
        let url = try settingsFile(#"{"ignoredLeftoverPaths": ["/tmp/a"]}"#)
        let rejected = settingsRejectedURL(url)
        let missing = EffectiveConfig(settings: .default, settingsURL: url, env: [:])
        XCTAssertEqual(missing.settingsRejectedPath, rejected.path)
        XCTAssertFalse(missing.settingsRejectedExists)
        XCTAssertTrue(
            missing.lines.contains { $0.contains("\(rejected.path) (missing)") },
            "\(missing.lines)"
        )
        try Data("{ \"ignoredLeftoverPaths\": ".utf8).write(to: url)
        try Data(#"{"ignoredLeftoverPaths": ["/tmp/a"]}"#.utf8).write(to: rejected)
        addTeardownBlock { try? FileManager.default.removeItem(at: rejected) }
        let there = EffectiveConfig(settings: .default, settingsURL: url, env: [:])
        XCTAssertTrue(there.settingsRejectedExists)
        XCTAssertTrue(there.lines.contains { $0.contains(rejected.path) }, "\(there.lines)")
        XCTAssertFalse(
            there.lines.contains { $0.contains(rejected.path) && $0.hasSuffix("(missing)") },
            "a present file reported as missing: \(there.lines)"
        )
    }

    func testLinesReportWhereIncludeSystemCameFrom() {
        var settings = AppAtticSettings.default
        settings.includeSystem = true
        let fromFlag = EffectiveConfig(settings: settings, includeSystemFlag: true, env: [:])
        XCTAssertTrue(
            fromFlag.lines.contains { $0.contains("includeSystem: true [on (--include-system)]") },
            "\(fromFlag.lines)"
        )
    }

    /// A count cannot be wrong in a way a reader sees. The entries themselves
    /// are what a user checks against the paths a report prints.
    func testConfigLinesListEveryIgnoredPath() throws {
        let settings = AppAtticSettings(ignoredLeftoverPaths: ["/tmp/Whisky", "/tmp/Caches/Steam"])
        let config = EffectiveConfig(settings: settings, env: [:])
        XCTAssertEqual(
            config.lines.filter { $0.hasPrefix("  ") },
            ["  /tmp/Whisky", "  /tmp/Caches/Steam"]
        )
        let count = try XCTUnwrap(config.lines.first { $0.hasPrefix("ignoredLeftoverPaths:") })
        XCTAssertEqual(count, "ignoredLeftoverPaths: \(localeCount(2))")
        // Each entry follows the count it belongs to, so the list cannot be read
        // as a continuation of the line above it.
        let countIndex = try XCTUnwrap(config.lines.firstIndex(of: count))
        XCTAssertEqual(Array(config.lines[(countIndex + 1)...].prefix(2)), [
            "  /tmp/Whisky",
            "  /tmp/Caches/Steam",
        ])
        XCTAssertTrue(EffectiveConfig(settings: .default, env: [:]).lines.allSatisfy { !$0.hasPrefix("  ") })
    }

    /// The reported root list and the searched root list are one list. A reader
    /// who sees `XDG_DATA_DIRS` in the output has to be able to trust that the
    /// scan looked in exactly those roots.
    func testReportedDataDirsAreTheOnesTheScanSearches() {
        let env = ["XDG_DATA_DIRS": "relative/share:/opt/share:/srv/share"]
        let config = EffectiveConfig(settings: .default, env: env)
        XCTAssertEqual(
            config.lines.first { $0.hasPrefix("XDG_DATA_DIRS:") },
            "XDG_DATA_DIRS: /opt/share:/srv/share"
        )
        let reported = config.dataDirs.split(separator: ":").map(String.init)
        let searched = xdgSystemDirList(env: env).map { "\($0)/applications" }
        // The comparison below only runs over the reported roots, so an empty
        // report, or one holding nothing the search produces, would leave it
        // with nothing to check and the test would pass on a list that never
        // matched. Both are asserted first.
        let candidates = linuxDesktopDirs(home: "/home/x", env: env)
            .filter { dir in reported.contains { dir == "\($0)/applications" } }
        XCTAssertFalse(reported.isEmpty, "nothing was reported: \(config.dataDirs)")
        XCTAssertFalse(candidates.isEmpty, "no reported root is a searched desktop dir")
        for dir in candidates {
            XCTAssertTrue(searched.contains(dir), "\(dir) is reported but not searched")
        }
    }

    func testEffectiveConfigResolvesEnvironmentRoots() {
        let env = [
            "XDG_DATA_HOME": "/xdg/data",
            "XDG_CONFIG_HOME": "/xdg/config",
            "XDG_CACHE_HOME": "relative/cache",
            "XDG_STATE_HOME": "/xdg/state",
            "XDG_DATA_DIRS": "/usr/share",
        ]
        let config = EffectiveConfig(settings: .default, env: env)
        XCTAssertEqual(config.dataHome, "/xdg/data")
        XCTAssertEqual(config.configHome, "/xdg/config")
        // A relative XDG path is ignored, so the report shows what the scan uses:
        // the `.cache` fallback under the home directory. That home is the
        // account's, not an injected one, so the assertion is about the shape
        // of the result; pinning it to `homeDirectoryForCurrentUser` would be
        // an assertion about the machine running the suite, and would fail
        // wherever $HOME and the passwd entry disagree.
        XCTAssertEqual(
            config.cacheHome,
            (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".cache")
        )
        XCTAssertTrue(config.cacheHome.hasSuffix("/.cache"), config.cacheHome)
        XCTAssertFalse(config.cacheHome.hasPrefix("relative"))
        XCTAssertEqual(config.stateHome, "/xdg/state")
        XCTAssertEqual(config.dataDirs, "/usr/share")
    }

    /// The network-folder scan opens at this root, and `appattic config` is how
    /// two machines are told apart, so the root it prints has to be the one the
    /// window opens. `ui/linux-qt/diskpage.cpp` resolves the same variable the
    /// same way; these cases are its rules.
    func testGvfsRootFollowsTheWindowResolution() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = (home as NSString).appendingPathComponent(".gvfs")
        for unset in [[:], ["XDG_RUNTIME_DIR": ""], ["XDG_RUNTIME_DIR": "  "],
                      ["XDG_RUNTIME_DIR": "run/user/1000"]] {
            XCTAssertEqual(gvfsRoot(home: home, env: unset), fallback, "\(unset)")
        }
        // An absolute root the machine does not have falls back too, so a stale
        // XDG_RUNTIME_DIR does not send the chooser at a directory that is gone.
        let absent = NSTemporaryDirectory() + "appattic-no-such-runtime-\(UUID().uuidString)"
        XCTAssertEqual(
            gvfsRoot(home: home, env: ["XDG_RUNTIME_DIR": absent]),
            fallback
        )
        // A real gvfs directory under an absolute root is the root in force.
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-runtime-\(UUID().uuidString)")
        let gvfs = runtime.appendingPathComponent("gvfs")
        try FileManager.default.createDirectory(at: gvfs, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: runtime) }
        XCTAssertEqual(gvfsRoot(home: home, env: ["XDG_RUNTIME_DIR": runtime.path]), gvfs.path)
        // A trailing separator names the same directory, as it does for the
        // other XDG roots.
        XCTAssertEqual(
            gvfsRoot(home: home, env: ["XDG_RUNTIME_DIR": runtime.path + "/"]),
            gvfs.path
        )
    }

    /// The root is on the `config` output: a diff of two machines is the only
    /// way to tell which root a window would open at.
    func testConfigPrintsTheRuntimeRoot() {
        let lines = EffectiveConfig(settings: .default, env: [:]).lines
        XCTAssertTrue(
            lines.contains {
                $0.hasPrefix("XDG_RUNTIME_DIR: ")
                    && $0.hasSuffix("/.gvfs")
            },
            "\(lines)"
        )
    }

    /// `coreOutDir` ignores a value that is not an absolute path, so the
    /// report has to say so rather than name a directory the window skipped.
    func testCoreOutEffectMatchesWhatTheShellReads() throws {
        func effect(_ raw: String) throws -> String {
            let env = ["APPATTIC_CORE_OUT": raw]
            let entries = EffectiveConfig(settings: .default, env: env).environment
            return try XCTUnwrap(entries.first { $0.name == "APPATTIC_CORE_OUT" }).effect
        }
        XCTAssertEqual(try effect("/opt/appattic"), "WASM modules read from this directory")
        XCTAssertEqual(try effect(" /opt/appattic "), "WASM modules read from this directory")
        XCTAssertEqual(
            try effect(""),
            "set but empty, so it is searched next to the binary"
        )
        XCTAssertEqual(
            try effect("core/out"),
            "not an absolute path, so it is searched next to the binary"
        )
    }

    func testStartPageUnsetAndEmptyOpenOverview() {
        XCTAssertEqual(resolveStartPage(env: [:]).page, .overview)
        XCTAssertNil(resolveStartPage(env: [:]).warning)
        let empty = resolveStartPage(env: ["APPATTIC_PAGE": "  "])
        XCTAssertEqual(empty.page, .overview)
        XCTAssertNil(empty.warning)
    }

    func testStartPageAcceptsEveryDocumentedName() {
        for page in StartPage.allCases {
            let resolved = resolveStartPage(env: ["APPATTIC_PAGE": page.rawValue])
            XCTAssertEqual(resolved.page, page)
            XCTAssertNil(resolved.warning, page.rawValue)
        }
    }

    func testStartPageTrimsAndReportsAnUnknownName() throws {
        let padded = resolveStartPage(env: ["APPATTIC_PAGE": " leftovers \n"])
        XCTAssertEqual(padded.page, .leftovers)
        XCTAssertNil(padded.warning)

        let bad = resolveStartPage(env: ["APPATTIC_PAGE": "leftover"])
        XCTAssertEqual(bad.page, .overview)
        let warning = try XCTUnwrap(bad.warning)
        XCTAssertTrue(warning.contains("\"leftover\""), warning)
        for page in StartPage.allCases {
            XCTAssertTrue(warning.contains(page.rawValue), warning)
        }
    }

    /// The README documents the names, so a rename cannot land without the doc.
    func testReadmeDocumentsTheConfigSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("`APPATTIC_PAGE`"), "APPATTIC_PAGE is undocumented")
        let row = try XCTUnwrap(readme.split(separator: "\n").first { $0.contains("`APPATTIC_PAGE`") })
        for page in StartPage.allCases {
            XCTAssertTrue(row.contains(page.rawValue), "\(page.rawValue) is missing from: \(row)")
        }
        XCTAssertTrue(readme.contains("appattic config"), "the config command is undocumented")
        for entry in configEnvEntries(env: [:]) {
            XCTAssertTrue(
                readme.contains("`\(entry.name)`"),
                "\(entry.name) is read by the app but undocumented"
            )
        }
    }

    /// `man appattic` is where a user looks after a value is already exported
    /// and something is being read as off, so every switch `appattic config`
    /// reports has to be in its ENVIRONMENT section. The README test above
    /// covers the README and `scripts/lint.sh` covers both man pages; this is
    /// the same guarantee from the suite that owns the config surface, so a
    /// contributor running `swift test` alone sees it.
    ///
    /// The four Qt-and-core-host switches are excluded: `configEnvEntries`
    /// reports them because a Linux run's package results come from them, but
    /// they are not this binary's variables and `man appattic-qt` documents
    /// each one. `APPATTIC_PAGE` stays in the list, because its entry has to
    /// say that the window reads it rather than leave a reader looking for a
    /// sidebar this command does not have.
    func testCLIManPageDocumentsEverySwitchItReports() throws {
        let qtOnly: Set<String> = [
            "APPATTIC_CORE_OUT",
            "APPATTIC_HOST_EXEC_LIVE",
            "APPATTIC_HOST_EXEC_FIXTURE",
            "FLATPAK_ID",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let page = try String(
            contentsOf: root.appendingPathComponent("packaging/appattic.1"),
            encoding: .utf8
        )
        // Only the ENVIRONMENT section: FILES names the settings paths and
        // OPTIONS names flags, so a whole-file search would pass on a page
        // that documents a switch somewhere a reader would not look for it.
        let start = try XCTUnwrap(page.range(of: "\n.SH ENVIRONMENT\n"))
        let rest = page[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n.SH "))
        let environment = String(rest[rest.startIndex..<end.lowerBound])
        for entry in configEnvEntries(env: [:]) where !qtOnly.contains(entry.name) {
            XCTAssertTrue(
                environment.contains(entry.name),
                "\(entry.name) is printed by 'appattic config' but is not in the ENVIRONMENT section of packaging/appattic.1"
            )
        }
    }

    /// The README quotes a full `appattic config` run, and a quoted run whose
    /// order no longer matches the order the command prints is a second copy
    /// of the config surface, kept in step by hand. The env block is compared
    /// name by name against the array that produces it, so a switch added to
    /// the code and not to the example fails here rather than reading as a
    /// complete run that is missing a line.
    func testReadmeConfigExampleMatchesTheOrderConfigPrints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let all = readme.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = try XCTUnwrap(all.firstIndex { $0.hasPrefix("NO_COLOR: ") })
        let tail = Array(all[first...])
        // The block ends at the fence that closes the fenced example.
        let stop = try XCTUnwrap(tail.firstIndex { $0.hasPrefix("```") })
        // The XDG roots print above the switches as bare `NAME: path` lines;
        // the switches are the ones whose value carries an effect in brackets.
        let quoted = tail[0..<stop].compactMap { line -> String? in
            guard line.hasSuffix("]"), let colon = line.range(of: ": ") else { return nil }
            return String(line[..<colon.lowerBound])
        }
        XCTAssertEqual(quoted, configEnvEntries(env: [:]).map(\.name), "\(quoted)")
    }

    /// An unset switch is reported, not absent: the difference between no
    /// override and an override nobody remembered setting is the whole point
    /// of diffing two machines.
    func testUnsetSwitchesAreNamedWithTheirDefaultEffect() {
        let config = EffectiveConfig(settings: .default, env: [:])
        for entry in config.environment {
            XCTAssertFalse(entry.isSet, entry.name)
            XCTAssertEqual(entry.value, "", entry.name)
            XCTAssertFalse(entry.effect.isEmpty, entry.name)
        }
        let lines = config.lines
        XCTAssertTrue(lines.contains("FLATPAK_ID: unset [host run]"), "\(lines)")
        XCTAssertTrue(lines.contains("APPATTIC_PAGE: unset [overview]"), "\(lines)")
    }

    func testSetSwitchesReportTheirValueAndEffect() {
        let env = [
            "APPATTIC_PAGE": "stale",
            "NO_COLOR": "1",
            "COLORFGBG": "15;0",
            "FLATPAK_ID": "org.appattic.AppAttic",
            "APPATTIC_HOST_EXEC_FIXTURE": "yes",
            "APPATTIC_CORE_OUT": "/opt/appattic",
        ]
        let config = EffectiveConfig(settings: .default, env: env)
        let byName = Dictionary(
            uniqueKeysWithValues: config.environment.map { ($0.name, $0) }
        )
        XCTAssertEqual(byName["APPATTIC_PAGE"]?.effect, "stale")
        XCTAssertEqual(byName["NO_COLOR"]?.effect, "colors off")
        XCTAssertEqual(byName["COLORFGBG"]?.effect, "dark status colors")
        XCTAssertEqual(byName["FLATPAK_ID"]?.effect, "sandboxed: package queries go through /run/host")
        XCTAssertEqual(byName["APPATTIC_HOST_EXEC_FIXTURE"]?.effect, "on: built-in fixtures")
        XCTAssertEqual(byName["APPATTIC_CORE_OUT"]?.effect, "WASM modules read from this directory")
        XCTAssertTrue(config.lines.contains { $0.contains("APPATTIC_PAGE: \"stale\" [stale]") }, "\(config.lines)")
    }

    /// The two host-exec switches are read by the C core host, which accepts
    /// only these spellings. Reporting a value the core host then reads as off
    /// would make the report worse than silence.
    func testHostExecSwitchesUseTheCoreHostsSpellings() {
        for on in ["1", "true", "TRUE", "yes", "on", " 1 "] {
            XCTAssertTrue(configBoolSwitch(on), on)
        }
        for off in ["0", "false", "no", "off", "", "  ", "2", "yes please", "enabled"] {
            XCTAssertFalse(configBoolSwitch(off), off)
        }
        let env = ["APPATTIC_HOST_EXEC_LIVE": "0", "APPATTIC_HOST_EXEC_FIXTURE": "maybe"]
        let byName = Dictionary(
            uniqueKeysWithValues: EffectiveConfig(settings: .default, env: env)
                .environment.map { ($0.name, $0) }
        )
        XCTAssertEqual(byName["APPATTIC_HOST_EXEC_LIVE"]?.effect, "off: read as off")
        XCTAssertEqual(byName["APPATTIC_HOST_EXEC_FIXTURE"]?.effect, "off: live package queries")
    }

    /// `configBoolSwitch` exists to say what `core/host/hostexec.c` will do,
    /// so the two have to agree on what "surrounding blanks" means as well as
    /// on the spellings. `env_flag` trims a space and a tab and nothing else;
    /// `.whitespaces` also trims a newline, a carriage return, a form feed, a
    /// vertical tab, and every Unicode space, so `APPATTIC_HOST_EXEC_LIVE`
    /// holding `"\n1\n"` read as on here and as off there. The report then
    /// said a Linux run would exec the real package managers against a host
    /// that served it fixtures, which is the whole failure this function is
    /// written to prevent.
    func testBoolSwitchTrimsOnlyWhatTheCoreHostTrims() {
        // Both trees trim these, so the value is on in both.
        for on in [" 1 ", "\t1\t", " \t1\t "] {
            XCTAssertTrue(configBoolSwitch(on), on.debugDescription)
        }
        // `env_flag` leaves these in the value it compares, so the core host
        // reads them as off and prints "is not a boolean".
        for off in ["\n1\n", "\r1\r", "\u{0B}1\u{0B}", "\u{0C}1\u{0C}",
                    "\u{00A0}1\u{00A0}", "1\n", "\n1"] {
            XCTAssertFalse(configBoolSwitch(off), off.debugDescription)
        }
    }

    /// `NO_COLOR` disables on a non-empty value only, and `APPATTIC_PAGE` falls
    /// back to the overview on a name it does not know, the same as the windows.
    func testSwitchesWithASetButUnusableValueSaySo() {
        let emptyNoColor = EffectiveConfig(settings: .default, env: ["NO_COLOR": ""])
        XCTAssertTrue(
            emptyNoColor.lines.contains { $0.contains("NO_COLOR: \"\" [set but empty, which is not a disable]") },
            "\(emptyNoColor.lines)"
        )
        let badPage = EffectiveConfig(settings: .default, env: ["APPATTIC_PAGE": "leftover"])
        XCTAssertTrue(
            badPage.lines.contains { $0.contains("APPATTIC_PAGE: \"leftover\" [unknown, opening overview]") },
            "\(badPage.lines)"
        )
        let emptyCoreOut = EffectiveConfig(settings: .default, env: ["APPATTIC_CORE_OUT": ""])
        XCTAssertTrue(
            emptyCoreOut.lines.contains { $0.contains("set but empty, so it is searched next to the binary") },
            "\(emptyCoreOut.lines)"
        )
    }

    /// The Qt shell keeps its own table of page names and its own spelling of
    /// the valid-values list, so a rename in `StartPage` has to land in
    /// main.cpp too. It cannot link the Swift library, so this is the check.
    func testQtShellKnowsEveryPageName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/main.cpp"),
            encoding: .utf8
        )
        for page in StartPage.allCases {
            XCTAssertTrue(
                source.contains("QStringLiteral(\"\(page.rawValue)\"), Page::"),
                "\(page.rawValue) has no entry in the Qt page table"
            )
        }
        XCTAssertTrue(
            source.contains("Valid values: \(StartPage.nameList)."),
            "the Qt valid-values list differs from StartPage.nameList"
        )
    }

    /// The two Android SDK variables choose a root the scan walks, and they
    /// were the only such roots `appattic config` did not name: a user who
    /// exported one and still saw no `android` overlay had no way to tell a
    /// stale value from a value the report ignored. The root in force is the
    /// first of the two that holds a real SDK, and a value holding none is
    /// reported as ignored rather than as the root.
    func testConfigNamesTheAndroidSdkRootInForce() throws {
        func effect(_ env: [String: String], _ name: String) throws -> String {
            let entries = EffectiveConfig(settings: .default, env: env).environment
            return try XCTUnwrap(entries.first { $0.name == name }).effect
        }
        XCTAssertEqual(
            try effect(["ANDROID_HOME": "  "], "ANDROID_HOME"),
            "set, but no such SDK directory, so the default directories only"
        )
        XCTAssertEqual(
            try effect(["ANDROID_HOME": ""], "ANDROID_HOME"),
            "set but empty, so the default SDK directories only"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-config-sdk-\(UUID().uuidString)")
        let sdk = root.appendingPathComponent("Android")
        try FileManager.default.createDirectory(
            at: sdk.appendingPathComponent("emulator"),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            try effect(["ANDROID_HOME": sdk.path], "ANDROID_HOME"),
            "Android SDK read from \(sdk.path)"
        )
        // The second spelling is read after the first, so a first value that
        // holds no SDK does not hide the one that does.
        XCTAssertEqual(
            try effect(["ANDROID_HOME": root.path, "ANDROID_SDK_ROOT": sdk.path], "ANDROID_SDK_ROOT"),
            "Android SDK read from \(sdk.path)"
        )
        // A value naming no SDK directory is not the root in force, and saying
        // so is the whole point of the line.
        let empty = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(
            try effect(["ANDROID_HOME": empty.path], "ANDROID_HOME"),
            "set, but no such SDK directory, so the default directories only"
        )
    }

    /// `LANG` picks the `.lproj` the macOS app-name lookup reads, so two runs
    /// can name the same app differently with every other config line equal.
    /// The reported locale is the one `lprojCandidates` resolves it to: the
    /// part before the first `.`, with `-` folded to `_`. It is resolved
    /// untrimmed, the way the app resolves it, so the line cannot name a
    /// locale the app did not look for.
    func testConfigNamesTheLocaleTheAppNamesAreReadIn() throws {
        func effect(_ raw: String?) throws -> String {
            var env: [String: String] = [:]
            if let raw { env["LANG"] = raw }
            let entries = EffectiveConfig(settings: .default, env: env).environment
            return try XCTUnwrap(entries.first { $0.name == "LANG" }).effect
        }
        XCTAssertEqual(try effect(nil), "the base English app names")
        XCTAssertEqual(try effect(""), "set but empty, so the base English app names")
        XCTAssertEqual(
            try effect("pt_BR.UTF-8"),
            "app names read from the pt_BR .lproj when it exists"
        )
        XCTAssertEqual(
            try effect("pt-BR"),
            "app names read from the pt_BR .lproj when it exists"
        )
        // The part before the encoding is the locale; a value that is only an
        // encoding resolves to nothing, so it reads as the base names.
        XCTAssertEqual(try effect(".UTF-8"), "set but empty, so the base English app names")
    }
}
