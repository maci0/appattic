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
        let url = settingsFile(#"{"includeSystem": true, "confirmDelete": false}"#)
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
    }
}
