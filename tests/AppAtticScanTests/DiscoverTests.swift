import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import AppAtticScan

final class DiscoverTests: XCTestCase {
    func testParseDesktopFile() throws {
        let body = """
        [Desktop Entry]
        Type=Application
        Name=Firefox Web Browser
        Comment=Browse the Web
        Exec=/usr/bin/firefox %u
        StartupWMClass=firefox
        Icon=firefox
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("firefox.desktop").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        let app = parseDesktopFile(path, sourceDir: "/usr/share/applications")
        XCTAssertNotNil(app)
        XCTAssertEqual(app?.displayName, "Firefox Web Browser")
        XCTAssertEqual(app?.bundleId, "firefox")
        XCTAssertEqual(app?.extra["comment"], "Browse the Web")
        XCTAssertEqual(app?.isSystem, true)
    }

    func testHiddenDesktopIsSkipped() throws {
        let body = """
        [Desktop Entry]
        Type=Application
        Name=Hidden Helper
        Exec=/usr/bin/helper
        NoDisplay=true
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hidden.desktop").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(parseDesktopFile(path, sourceDir: "/usr/share/applications"))
    }

    func testIosWrapperReadsInnerBundleId() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outer = td.appendingPathComponent("Proton Authenticator.app")
        let inner = outer.appendingPathComponent("Wrapper/Authenticator.app")
        let contents = inner.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleDisplayName": "Proton Authenticator",
            "CFBundleIdentifier": "ch.proton.authenticator",
            "CFBundleExecutable": "Authenticator",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            atPath: outer.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Authenticator.app"
        )
        let app = makeApp(from: outer.path)
        XCTAssertEqual(app?.bundleId, "ch.proton.authenticator")
        XCTAssertEqual(app?.extra["executable"], "Authenticator")
        try? FileManager.default.removeItem(at: td)
    }

    func testIosWrapperReadsRootInfoPlist() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outer = td.appendingPathComponent("Proton Authenticator.app")
        let inner = outer.appendingPathComponent("Wrapper/Authenticator.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleDisplayName": "Proton Authenticator",
            "CFBundleIdentifier": "ch.protonmail.ios.authenticator",
            "CFBundleExecutable": "Authenticator",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: inner.appendingPathComponent("Info.plist"))
        try "".write(to: inner.appendingPathComponent("Authenticator"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: outer.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Authenticator.app"
        )
        let app = makeApp(from: outer.path)
        XCTAssertEqual(app?.bundleId, "ch.protonmail.ios.authenticator")
        try? FileManager.default.removeItem(at: td)
    }

    func testGetInfoStringBecomesComment() throws {
        let app = try makePlistApp("Deskflow.app", info: [
            "CFBundleDisplayName": "Deskflow",
            "CFBundleIdentifier": "org.deskflow.deskflow",
            "CFBundleGetInfoString": "Keyboard and mouse sharing utility",
            "LSApplicationCategoryType": "public.app-category.utilities",
        ])
        XCTAssertEqual(app.extra["comment"], "Keyboard and mouse sharing utility")
    }

    func testVersionGetInfoStringIsNotADescription() throws {
        let app = try makePlistApp("iTerm.app", info: [
            "CFBundleDisplayName": "iTerm2",
            "CFBundleIdentifier": "com.googlecode.iterm2",
            "CFBundleGetInfoString": "3.6.11",
            "LSApplicationCategoryType": "public.app-category.productivity",
        ])
        XCTAssertNil(app.extra["comment"])
        XCTAssertEqual(app.extra["category"], "Productivity app")
    }

    func testCopyrightGetInfoStringIsNotADescription() throws {
        let app = try makePlistApp("LimeChat.app", info: [
            "CFBundleDisplayName": "LimeChat",
            "CFBundleIdentifier": "net.limechat.LimeChat",
            "CFBundleGetInfoString": "LimeChat for Mac, Copyright 2007-2020 Satoshi Nakagawa",
        ])
        XCTAssertNil(app.extra["comment"])
    }

    func testUnityPlayerGetInfoStringIsNotADescription() {
        XCTAssertNil(plistDescription(
            ["NSHumanReadableDescription": "Unity Player version 6000.0.43f1 (97272b72f107). (c) 2005-2025 Unity Technologies. All rights reserved."],
            appName: "The Farmer Was Replaced"
        ))
        XCTAssertNil(plistDescription(
            ["CFBundleGetInfoString": "SomeApp 1.0 (c) 2020 Acme. All rights reserved."],
            appName: "SomeApp"
        ))
    }

    func testInfoPlistStringsGetInfoBecomesComment() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appPath = td.appendingPathComponent("Deskflow.app")
        let contents = appPath.appendingPathComponent("Contents")
        let lproj = contents.appendingPathComponent("Resources/en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleDisplayName": "Deskflow",
            "CFBundleIdentifier": "org.deskflow.deskflow",
            "LSApplicationCategoryType": "public.app-category.utilities",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleGetInfoString": "Keyboard and mouse sharing utility",
        ], format: .xml, options: 0).write(to: lproj.appendingPathComponent("InfoPlist.strings"))
        let app = makeApp(from: appPath.path)
        XCTAssertEqual(app?.extra["comment"], "Keyboard and mouse sharing utility")
        try? FileManager.default.removeItem(at: td)
    }

    func testSigningTeamGetInfoStringIsNotADescription() {
        XCTAssertNil(plistDescription(["CFBundleGetInfoString": "syncthing project Group"], appName: "Syncthing"))
    }

    func testNamePlusVersionGetInfoStringIsNotADescription() {
        XCTAssertNil(plistDescription(["CFBundleGetInfoString": "Adobe Acrobat X 26.001.21789"], appName: "Acrobat"))
    }

    func testDisplayNameStripsBidiMarks() throws {
        let app = try makePlistApp("WhatsApp.app", info: [
            "CFBundleDisplayName": "\u{200E}WhatsApp",
            "CFBundleIdentifier": "net.whatsapp.WhatsApp",
        ])
        XCTAssertEqual(app.displayName, "WhatsApp")
    }

    func testMasReceiptAndVersionOnBundle() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appPath = td.appendingPathComponent("iMovie.app")
        let contents = appPath.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleDisplayName": "iMovie",
            "CFBundleIdentifier": "com.apple.iMovieApp",
            "CFBundleShortVersionString": "10.4.3",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("_MASReceipt/receipt"))
        let app = makeApp(from: appPath.path)
        XCTAssertEqual(app?.extra["mas_receipt"], "1")
        XCTAssertEqual(app?.extra["version"], "10.4.3")
        XCTAssertTrue(hasMasReceipt(appPath.path))
        try? FileManager.default.removeItem(at: td)
    }

    func testWebkitDotAppIsNotAnInstalledApp() {
        XCTAssertFalse(isRealAppPath("/Users/x/Library/WebKit/com.mdhero.app"))
        XCTAssertFalse(isRealAppPath("/Library/Caches/Foo.app"))
        XCTAssertTrue(isRealAppPath("/Applications/Firefox.app"))
    }

    func testBuildProductsAreNotInstalledApps() {
        XCTAssertFalse(isRealAppPath("/Users/x/Code/webmeet/WebKit/WebKitBuild/Release/TestWebKitAPI.app"))
        XCTAssertFalse(isRealAppPath("/Users/x/Library/Developer/Xcode/DerivedData/Foo/Build/Products/Debug/Foo.app"))
        XCTAssertFalse(isRealAppPath("/Users/x/proj/.build/debug/MyTool.app"))
    }

    func testUtilitiesFolderIsNotSoftware() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: td.appendingPathComponent("Utilities"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: td.appendingPathComponent("SomePkg"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: td.appendingPathComponent("Foo.app"), withIntermediateDirectories: true)
        let names = Set(nonAppEntriesIn(td.path).map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertFalse(names.contains("Utilities"))
        XCTAssertFalse(names.contains("Foo.app"))
        XCTAssertTrue(names.contains("SomePkg"))
        try? FileManager.default.removeItem(at: td)
    }

    func testWrapperFolderContainingAppIsNotSoftware() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: td.appendingPathComponent("Adobe Acrobat DC/Adobe Acrobat.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: td.appendingPathComponent("SomePkg"), withIntermediateDirectories: true)
        let names = Set(nonAppEntriesIn(td.path).map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertFalse(names.contains("Adobe Acrobat DC"))
        XCTAssertTrue(names.contains("SomePkg"))
        try? FileManager.default.removeItem(at: td)
    }

    func testXdgDataDirsAreSearchedForDesktops() {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let extra = (td as NSString).appendingPathComponent("share")
        let oldDirs = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
        let oldHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        setenv("XDG_DATA_DIRS", extra, 1)
        setenv("XDG_DATA_HOME", (td as NSString).appendingPathComponent("user"), 1)
        defer {
            if let oldDirs { setenv("XDG_DATA_DIRS", oldDirs, 1) } else { unsetenv("XDG_DATA_DIRS") }
            if let oldHome { setenv("XDG_DATA_HOME", oldHome, 1) } else { unsetenv("XDG_DATA_HOME") }
        }
        let dirs = linuxDesktopDirs()
        XCTAssertTrue(dirs.contains((extra as NSString).appendingPathComponent("applications")))
        XCTAssertTrue(dirs.contains("/var/lib/snapd/desktop/applications"))
    }

    func testFindAppsLinuxOverrideUsesDesktopFiles() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appsDir = td.appendingPathComponent("applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let body = """
        [Desktop Entry]
        Type=Application
        Name=TempScanApp
        Exec=/usr/bin/true
        """
        try body.write(to: appsDir.appendingPathComponent("tempscanapp.desktop"), atomically: true, encoding: .utf8)
        let oldDirs = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
        let oldHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        setenv("XDG_DATA_DIRS", td.path, 1)
        setenv("XDG_DATA_HOME", td.appendingPathComponent("user").path, 1)
        PlatformOverride.linux = true
        defer {
            PlatformOverride.linux = nil
            if let oldDirs { setenv("XDG_DATA_DIRS", oldDirs, 1) } else { unsetenv("XDG_DATA_DIRS") }
            if let oldHome { setenv("XDG_DATA_HOME", oldHome, 1) } else { unsetenv("XDG_DATA_HOME") }
            try? FileManager.default.removeItem(at: td)
        }
        let found = findApps()
        XCTAssertTrue(found.contains { $0.displayName == "TempScanApp" })
        XCTAssertFalse(found.contains { $0.path.hasPrefix("/Applications/") })
    }

    func testFlatpakDesktopDoesNotUseWrapperBinaryAsPath() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = td.appendingPathComponent("bin")
        let apps = td.appendingPathComponent("flatpak/exports/share/applications")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let wrapper = bin.appendingPathComponent("flatpak").path
        FileManager.default.createFile(atPath: wrapper, contents: Data(), attributes: nil)
        let desktop = apps.appendingPathComponent("org.mozilla.Firefox.desktop").path
        let body = """
        [Desktop Entry]
        Type=Application
        Name=Firefox
        Exec=\(wrapper) run --branch=stable --arch=x86_64 org.mozilla.Firefox
        """
        try body.write(toFile: desktop, atomically: true, encoding: .utf8)
        let app = try XCTUnwrap(parseDesktopFile(desktop, sourceDir: apps.path))
        XCTAssertNotEqual(app.path, wrapper, app.path)
        XCTAssertTrue(app.path.hasSuffix(".desktop"), app.path)
        XCTAssertEqual(app.extra["linux_source"], "flatpak")
        XCTAssertEqual(app.extra["pkg_id"], "org.mozilla.Firefox")
        XCTAssertFalse(app.isSystem)
    }

    func testSnapDesktopUsesSnapNameNotSnapBinary() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = td.appendingPathComponent("bin")
        let apps = td.appendingPathComponent("snapd/desktop/applications")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let wrapper = bin.appendingPathComponent("snap").path
        FileManager.default.createFile(atPath: wrapper, contents: Data(), attributes: nil)
        let desktop = apps.appendingPathComponent("firefox_firefox.desktop").path
        let body = """
        [Desktop Entry]
        Type=Application
        Name=Firefox
        Exec=\(wrapper) run firefox
        """
        try body.write(toFile: desktop, atomically: true, encoding: .utf8)
        let app = try XCTUnwrap(parseDesktopFile(desktop, sourceDir: apps.path))
        XCTAssertNotEqual(app.path, wrapper, app.path)
        XCTAssertEqual(app.extra["linux_source"], "snap")
        XCTAssertEqual(app.extra["pkg_id"], "firefox")
    }

    func testAppImageDesktopKeepsImagePath() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let apps = td.appendingPathComponent("applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let image = td.appendingPathComponent("Foo-x86_64.AppImage").path
        FileManager.default.createFile(atPath: image, contents: Data(), attributes: nil)
        let desktop = apps.appendingPathComponent("foo.desktop").path
        let body = """
        [Desktop Entry]
        Type=Application
        Name=Foo
        Exec=\(image) %u
        """
        try body.write(toFile: desktop, atomically: true, encoding: .utf8)
        let app = try XCTUnwrap(parseDesktopFile(desktop, sourceDir: apps.path))
        XCTAssertEqual(app.path, image)
        XCTAssertEqual(app.extra["linux_source"], "appimage")
    }

    private func makePlistApp(_ name: String, info: [String: Any]) throws -> AppRecord {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appPath = td.appendingPathComponent(name)
        let contents = appPath.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: td) }
        return try XCTUnwrap(makeApp(from: appPath.path))
    }
}
