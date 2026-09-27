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
        XCTAssertEqual(count, "ignoredLeftoverPaths: 2")
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
        for dir in linuxDesktopDirs(home: "/home/x", env: env) {
            if reported.contains(where: { dir == "\($0)/applications" }) {
                XCTAssertTrue(searched.contains(dir), "\(dir) is reported but not searched")
            }
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
        // the `.cache` fallback under the real home, spelled out rather than
        // re-derived through `xdgCacheHome`.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(config.cacheHome, (home as NSString).appendingPathComponent(".cache"))
        XCTAssertFalse(config.cacheHome.hasPrefix("relative"))
        XCTAssertEqual(config.stateHome, "/xdg/state")
        XCTAssertEqual(config.dataDirs, "/usr/share")
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
}
