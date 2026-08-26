import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import AppAtticScan

final class UsageTests: XCTestCase {
    func testLastUsedEqualToDateAddedIsIgnored() {
        let added = date(2026, 1, 1, 12, 0)
        XCTAssertNil(effectiveLastUsed(added.addingTimeInterval(30), added))
    }

    func testLastUsedDaysLaterIsKept() {
        let added = date(2026, 1, 1, 12, 0)
        let used = added.addingTimeInterval(10 * 86400)
        XCTAssertEqual(effectiveLastUsed(used, added), used)
    }

    func testMissingLastUsedStaysNone() {
        XCTAssertNil(effectiveLastUsed(nil, date(2026, 1, 1, 12, 0)))
    }

    func testLastUsedBeforeDateAddedIsKeptWhenFar() {
        let added = date(2026, 8, 16, 1, 45, 56)
        let used = date(2026, 6, 2, 20, 16, 6)
        XCTAssertEqual(effectiveLastUsed(used, added), used)
    }

    func testLastUsedSlightlyBeforeDateAddedIsDropped() {
        let added = date(2026, 8, 16, 1, 45, 56)
        XCTAssertNil(effectiveLastUsed(added.addingTimeInterval(-30), added))
    }

    func testParsesApplicationBookmarks() throws {
        let xml = """
        <?xml version="1.0"?>
        <xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop/bookmark">
          <bookmark href="file:///tmp/doc.pdf" visited="2026-04-01T15:00:00Z">
            <info>
              <metadata>
                <bookmark:applications>
                  <bookmark:application name="Firefox" exec="firefox %u" modified="2026-04-01T15:00:00Z" count="3"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        </xbel>
        """
        let path = try writeTemp(xml, suffix: ".xbel")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hits = parseRecentlyUsedXbel(path)
        XCTAssertNotNil(hits["firefox"])
        XCTAssertEqual(Calendar.current.component(.year, from: hits["firefox"]!), 2026)
    }

    func testUsesBookmarkVisitedWhenApplicationHasNoDate() throws {
        let xml = """
        <?xml version="1.0"?>
        <xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop/bookmark">
          <bookmark href="file:///tmp/doc.pdf" visited="2026-05-02T18:00:00Z">
            <info>
              <metadata>
                <bookmark:applications>
                  <bookmark:application name="Firefox" exec="firefox %u" count="1"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        </xbel>
        """
        let path = try writeTemp(xml, suffix: ".xbel")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hits = parseRecentlyUsedXbel(path)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.month, from: hits["firefox"]!), 5)
    }

    func testMatchesBundleExecutable() {
        let app = AppRecord(
            path: "/Applications/Visual Studio Code.app",
            displayName: "Visual Studio Code",
            bundleId: "com.microsoft.VSCode",
            extra: ["executable": "Code"]
        )
        let comms = processBasenames("/Applications/Visual Studio Code.app/Contents/MacOS/Code\n")
        XCTAssertTrue(appMatchesRunning(app, comms: comms))
    }

    func testElectronDoesNotMarkUnrelatedApp() {
        let slack = AppRecord(
            path: "/Applications/Slack.app",
            displayName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            extra: ["executable": "Slack"]
        )
        XCTAssertFalse(appMatchesRunning(slack, comms: processBasenames("Electron\n/usr/bin/python3\nhelper\n")))
    }

    func testGenericHelperBundleIdDoesNotMatch() {
        let app = AppRecord(path: "/Applications/Foo.app", displayName: "Foo Helper", bundleId: "com.example.Helper")
        XCTAssertFalse(appMatchesRunning(app, comms: ["helper", "agent", "python3"]))
    }

    func testCursorMatchesOwnExecutableNotElectron() {
        let app = AppRecord(
            path: "/Applications/Cursor.app",
            displayName: "Cursor",
            bundleId: "com.todesktop.230313mzl4w4u92",
            extra: ["executable": "Cursor"]
        )
        XCTAssertTrue(appMatchesRunning(app, comms: processBasenames("/Applications/Cursor.app/Contents/MacOS/Cursor\n")))
        XCTAssertFalse(appMatchesRunning(app, comms: processBasenames("Electron\npython3\n")))
    }

    func testInnerExecutablePath() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = td.appendingPathComponent("iTerm.app")
        let mac = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let exe = mac.appendingPathComponent("iTerm2")
        try Data().write(to: exe)
        XCTAssertEqual(innerExecutablePath(app.path, executable: "iTerm2"), exe.path)
        XCTAssertNil(innerExecutablePath(app.path, executable: "Missing"))
        try? FileManager.default.removeItem(at: td)
    }

    func testInnerMdlsDropsLastUsedEqualToCreation() {
        let out = """
        kMDItemLastUsedDate   = 2026-07-20 23:04:17 +0000
        kMDItemDateAdded      = (null)
        kMDItemFSCreationDate = 2026-07-20 23:04:17 +0000
        """
        let (used, _) = mdlsDates("/fake/Windows App") { _, _ in (0, out, "") }
        XCTAssertNil(used)
    }

    func testInnerMdlsKeepsLastUsedWhenFarFromCreation() {
        let out = """
        kMDItemLastUsedDate   = 2026-06-15 20:16:06 +0000
        kMDItemDateAdded      = (null)
        kMDItemFSCreationDate = 2026-06-02 20:16:06 +0000
        """
        let (used, _) = mdlsDates("/fake/iTerm2") { _, _ in (0, out, "") }
        XCTAssertNotNil(used)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.month, from: used!), 6)
    }

    func testFillAppUsageCopiesSpotlightDescriptionArray() {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        var apps = [AppRecord(path: "/Applications/Deskflow.app", displayName: "Deskflow", bundleId: "org.deskflow.deskflow")]
        fillAppUsage(&apps, progress: { _ in }, run: { cmd, _ in
            if cmd.first == "mdls" {
                return (0, """
                kMDItemLastUsedDate   = (null)
                kMDItemDateAdded      = (null)
                kMDItemFSCreationDate = (null)
                kMDItemDescription    = "Keyboard and mouse sharing utility"
                """, "")
            }
            return (0, "", "")
        }, runningComms: [])
        XCTAssertEqual(apps[0].extra["comment"], "Keyboard and mouse sharing utility")
    }

    func testFillAppUsageIgnoresInnerLastUsedEqualToCreation() throws {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appPath = td.appendingPathComponent("Windows App.app")
        let mac = appPath.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try Data().write(to: mac.appendingPathComponent("Windows App"))
        defer { try? FileManager.default.removeItem(at: td) }
        var apps = [AppRecord(path: appPath.path, displayName: "Windows App", extra: ["executable": "Windows App"])]
        fillAppUsage(&apps, progress: { _ in }, run: { cmd, _ in
            let path = cmd.last ?? ""
            if path.hasSuffix(".app") {
                return (0, """
                kMDItemLastUsedDate   = (null)
                kMDItemDateAdded      = 2026-08-16 01:45:56 +0000
                kMDItemFSCreationDate = 2026-07-20 23:04:17 +0000
                """, "")
            }
            return (0, """
            kMDItemLastUsedDate   = 2026-07-20 23:04:17 +0000
            kMDItemDateAdded      = (null)
            kMDItemFSCreationDate = 2026-07-20 23:04:17 +0000
            """, "")
        }, runningComms: [])
        XCTAssertNil(apps[0].lastUsed)
        XCTAssertEqual(apps[0].lastUsedSource, nil)
    }

    func testFillAppUsageInnerFallbackKeepsLastUsedFarFromCreation() throws {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let bundleAdded = "2026-08-16 01:45:56 +0000"
        let innerUsed = "2026-06-15 20:16:06 +0000"
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appPath = td.appendingPathComponent("iTerm.app")
        let mac = appPath.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try Data().write(to: mac.appendingPathComponent("iTerm2"))
        defer { try? FileManager.default.removeItem(at: td) }
        var apps = [AppRecord(path: appPath.path, displayName: "iTerm2", bundleId: "com.googlecode.iterm2", extra: ["executable": "iTerm2"])]
        fillAppUsage(&apps, progress: { _ in }, run: { cmd, _ in
            let path = cmd.last ?? ""
            if path.hasSuffix(".app") {
                return (0, """
                kMDItemLastUsedDate   = (null)
                kMDItemDateAdded      = \(bundleAdded)
                kMDItemFSCreationDate = 2026-06-02 20:16:06 +0000
                """, "")
            }
            return (0, """
            kMDItemLastUsedDate   = \(innerUsed)
            kMDItemDateAdded      = (null)
            kMDItemFSCreationDate = 2026-06-02 20:16:06 +0000
            """, "")
        }, runningComms: [])
        XCTAssertEqual(apps[0].lastUsedSource, "spotlight")
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.month, from: apps[0].lastUsed!), 6)
    }

    func testLinuxUsageDoesNotCallMdls() {
        PlatformOverride.linux = true
        defer { PlatformOverride.linux = nil }
        var apps = [AppRecord(path: "/usr/bin/firefox", displayName: "Firefox Web Browser", bundleId: "firefox", extra: ["executable": "firefox"])]
        fillAppUsage(&apps, progress: { _ in }, run: { cmd, _ in
            XCTAssertFalse(cmd.contains("mdls"))
            return (0, "", "")
        }, runningComms: [], xbelPath: "/nope", gnomeStatePath: "/nope", flatpakVarApp: "/nope")
    }

    func testXbelPathFollowsXdgDataHome() {
        setenv("XDG_DATA_HOME", "/tmp/xdg-data", 1)
        defer { unsetenv("XDG_DATA_HOME") }
        XCTAssertEqual(recentlyUsedXbelPath(), "/tmp/xdg-data/recently-used.xbel")
    }

    func testLinuxXbelMatchesMozillaAlias() throws {
        PlatformOverride.linux = true
        defer { PlatformOverride.linux = nil }
        let xml = """
        <?xml version="1.0"?>
        <xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop/bookmark">
          <bookmark href="file:///tmp/doc.pdf" visited="2026-04-01T15:00:00Z">
            <info>
              <metadata>
                <bookmark:applications>
                  <bookmark:application name="Mozilla" exec="" modified="2026-04-01T15:00:00Z" count="3"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        </xbel>
        """
        let path = try writeTemp(xml, suffix: ".xbel")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var apps = [AppRecord(path: "/usr/bin/firefox", displayName: "Firefox Web Browser", bundleId: "firefox", extra: ["executable": "firefox"])]
        fillAppUsage(&apps, progress: { _ in }, runningComms: [], xbelPath: path, gnomeStatePath: "/nope", flatpakVarApp: "/nope")
        XCTAssertNotNil(apps[0].lastUsed)
        XCTAssertEqual(apps[0].lastUsedSource, "recently-used")
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.month, from: apps[0].lastUsed!), 4)
    }

    func testLinuxXbelNearInstallTimeIsNotLastUsed() throws {
        PlatformOverride.linux = true
        defer { PlatformOverride.linux = nil }
        let appDir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-linux-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appDir) }
        let iso = ISO8601DateFormatter().string(from: Date())
        let xml = """
        <?xml version="1.0"?>
        <xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop/bookmark">
          <bookmark href="file:///tmp/doc.pdf" visited="\(iso)">
            <info>
              <metadata>
                <bookmark:applications>
                  <bookmark:application name="TempApp" exec="" modified="\(iso)" count="1"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        </xbel>
        """
        let path = try writeTemp(xml, suffix: ".xbel")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var apps = [AppRecord(path: appDir.path, displayName: "TempApp", bundleId: "tempapp")]
        fillAppUsage(&apps, progress: { _ in }, runningComms: [], xbelPath: path, gnomeStatePath: "/nope", flatpakVarApp: "/nope")
        XCTAssertNil(apps[0].lastUsed)
        XCTAssertNotNil(apps[0].installedAt)
    }

    func testGnomeApplicationStateLastSeen() throws {
        let xml = """
        <?xml version="1.0"?>
        <application-state>
          <application id="org.mozilla.firefox.desktop" score="12.0" last-seen="1717200000"/>
        </application-state>
        """
        let path = try writeTemp(xml, suffix: ".xml")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hits = parseGnomeApplicationState(path)
        XCTAssertNotNil(hits["org.mozilla.firefox.desktop"])
        XCTAssertNotNil(hits["org.mozilla.firefox"])
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: hits["org.mozilla.firefox"]!), 2024)
    }

    func testFlatpakVarAppMtime() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let varApp = td.appendingPathComponent(".var/app/org.mozilla.Firefox")
        try FileManager.default.createDirectory(at: varApp, withIntermediateDirectories: true)
        let hits = parseFlatpakVarAppMtimes(td.appendingPathComponent(".var/app").path)
        XCTAssertNotNil(hits["org.mozilla.firefox"])
        XCTAssertNotNil(hits["firefox"])
        try? FileManager.default.removeItem(at: td)
    }

    func testFirefoxKeysIncludeMozillaAndFirstWord() {
        let app = AppRecord(path: "/usr/bin/firefox", displayName: "Firefox Web Browser", bundleId: "firefox", extra: ["executable": "firefox"])
        let keys = appUsageKeys(app)
        XCTAssertTrue(keys.contains("firefox"))
        XCTAssertTrue(keys.contains("mozilla"))
    }

    func testUsageKeysIncludeDesktopId() {
        let app = AppRecord(
            path: "/usr/bin/firefox",
            displayName: "Firefox Web Browser",
            bundleId: "firefox",
            extra: [
                "executable": "firefox",
                "desktop_id": "org.mozilla.firefox",
                "desktop": "/usr/share/applications/org.mozilla.firefox.desktop",
            ]
        )
        let keys = appUsageKeys(app)
        XCTAssertTrue(keys.contains("org.mozilla.firefox"))
        XCTAssertTrue(keys.contains("org.mozilla.firefox.desktop"))
    }

    func testSpotlightDoesNotReplaceSteamLastPlayed() {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let played = date(2025, 6, 1, 12, 0)
        var apps = [AppRecord(
            path: "/tmp/steamapps/common/EmuDevz/EmuDevz.app",
            displayName: "EmuDevz",
            bundleId: "com.emudevz.app",
            lastUsed: played,
            lastUsedSource: "steam",
            extra: ["steam_appid": "3491810", "executable": "EmuDevz"]
        )]
        fillAppUsage(&apps, progress: { _ in }, run: { cmd, _ in
            if cmd.first == "mdls" {
                return (0, """
                kMDItemLastUsedDate   = 2026-08-18 05:59:15 +0000
                kMDItemDateAdded      = 2024-01-01 00:00:00 +0000
                kMDItemFSCreationDate = 2024-01-01 00:00:00 +0000
                kMDItemDescription    = (null)
                """, "")
            }
            return (0, "", "")
        }, runningComms: [])
        XCTAssertEqual(apps[0].lastUsed, played)
        XCTAssertEqual(apps[0].lastUsedSource, "steam")
    }

    func testLinuxXbelDoesNotReplaceSteamLastPlayed() throws {
        PlatformOverride.linux = true
        defer { PlatformOverride.linux = nil }
        let played = date(2025, 6, 1, 12, 0)
        let xml = """
        <?xml version="1.0"?>
        <xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop/bookmark">
          <bookmark href="file:///tmp/save.dat" visited="2026-08-18T05:59:15Z">
            <info>
              <metadata>
                <bookmark:applications>
                  <bookmark:application name="EmuDevz" exec="emudevz %u" modified="2026-08-18T05:59:15Z" count="3"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        </xbel>
        """
        let path = try writeTemp(xml, suffix: ".xbel")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var apps = [AppRecord(
            path: "/home/me/.steam/steam/steamapps/common/EmuDevz",
            displayName: "EmuDevz",
            bundleId: "emudevz",
            lastUsed: played,
            lastUsedSource: "steam",
            extra: ["steam_appid": "3491810", "executable": "emudevz"]
        )]
        fillAppUsage(&apps, progress: { _ in }, runningComms: [], xbelPath: path, gnomeStatePath: "/nope", flatpakVarApp: "/nope")
        XCTAssertEqual(apps[0].lastUsed, played)
        XCTAssertEqual(apps[0].lastUsedSource, "steam")
    }

    func testSteamWithoutLastPlayedTakesSpotlight() {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        var apps = [AppRecord(
            path: "/tmp/steamapps/common/EmuDevz/EmuDevz.app",
            displayName: "EmuDevz",
            extra: ["steam_appid": "3491810"]
        )]
        fillAppUsage(&apps, progress: { _ in }, run: { cmd, _ in
            if cmd.first == "mdls" {
                return (0, """
                kMDItemLastUsedDate   = 2026-04-01 15:00:00 +0000
                kMDItemDateAdded      = 2024-01-01 00:00:00 +0000
                kMDItemFSCreationDate = 2024-01-01 00:00:00 +0000
                kMDItemDescription    = (null)
                """, "")
            }
            return (0, "", "")
        }, runningComms: [])
        XCTAssertEqual(apps[0].lastUsedSource, "spotlight")
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.month, from: apps[0].lastUsed!), 4)
    }

    func testPrefsMtimeNearInstallIsIgnored() {
        let installed = date(2026, 1, 1, 12, 0)
        var apps = [AppRecord(
            path: "/Applications/Sketch.app",
            displayName: "Sketch",
            bundleId: "com.bohemiancoding.sketch3",
            installedAt: installed
        )]
        let item = DataItem(
            path: "/tmp/com.bohemiancoding.sketch3.plist",
            name: "com.bohemiancoding.sketch3.plist",
            rootLabel: "Preferences",
            kind: "plist",
            mtime: installed.addingTimeInterval(20)
        )
        applyPrefsFallback(&apps, items: [item])
        XCTAssertNil(apps[0].lastUsed)
    }

    func testPrefsMtimeDaysLaterCounts() {
        let installed = date(2026, 1, 1, 12, 0)
        var apps = [AppRecord(
            path: "/Applications/Sketch.app",
            displayName: "Sketch",
            bundleId: "com.bohemiancoding.sketch3",
            installedAt: installed
        )]
        let item = DataItem(
            path: "/tmp/com.bohemiancoding.sketch3.plist",
            name: "com.bohemiancoding.sketch3.plist",
            rootLabel: "Preferences",
            kind: "plist",
            mtime: installed.addingTimeInterval(40 * 86400)
        )
        applyPrefsFallback(&apps, items: [item])
        XCTAssertNotNil(apps[0].lastUsed)
        XCTAssertEqual(apps[0].lastUsedSource, "prefs-mtime")
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
        c.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func writeTemp(_ text: String, suffix: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
