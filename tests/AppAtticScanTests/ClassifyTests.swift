import XCTest
@testable import AppAtticScan

private func ident(_ apps: [AppRecord] = [], formulas: [Formula] = [], casks: [Cask] = [], tools: [String] = []) -> Identity {
    let brew = BrewSnapshot(available: !formulas.isEmpty || !casks.isEmpty, formulas: formulas, casks: casks)
    return Identity(apps: apps, brew: brew, toolNames: tools)
}

final class ClassifyTests: XCTestCase {
    func testStemMatchingIgnoresDecompositionForm() {
        // macOS reports the app directory in NFD ("e" + U+0301), Linux in NFC.
        // `stems` and `ownedByStem` compared raw code units, so a stem table
        // built from one form never answered for the other, and the `>= 5`
        // cluster gate admitted one spelling while dropping the other.
        let nfdApp = AppRecord(
            path: "/Applications/Cafe\u{301} Editor.app",
            displayName: "Cafe\u{301} Editor",
            bundleId: "com.example.cafeditor"
        )
        let id = ident([nfdApp])
        XCTAssertTrue(id.stems.contains("café editor"))
        XCTAssertTrue(id.ownedByStem("Cafe\u{301} Editor"))
        XCTAssertTrue(id.ownedByStem("Caf\u{00E9} Editor"))
        XCTAssertFalse(id.ownedByStem("Cafeteria"))
    }

    func testKagiAppOwnsOrionSupportFolder() {
        let kagi = AppRecord(path: "/Applications/Kagi.app", displayName: "Kagi", bundleId: "com.kagi.kagimacOS")
        XCTAssertEqual(ident([kagi]).classify("Orion", kind: "dir").0, "owned")
        XCTAssertEqual(ident([kagi]).classify("com.kagi.kagimacOS", kind: "bundleid").0, "owned")
        XCTAssertEqual(ident([kagi]).classify("com.kagi.kagimacOS.binarycookies", kind: "mixed").0, "owned")
        XCTAssertEqual(ident().classify("Orion", kind: "dir").0, "orphaned")
    }

    func testGenericComPrefixDoesNotOwnUnrelatedBundle() {
        let chrome = AppRecord(path: "/Applications/Google Chrome.app", displayName: "Google Chrome", bundleId: "com.google.Chrome")
        let (status, _) = ident([chrome]).classify("com.uninstalled.widget", kind: "bundleid")
        XCTAssertEqual(status, "orphaned")
    }

    func testAppleLabelInsideVendorBundleIsNotSystem() {
        XCTAssertEqual(ident().classify("com.vendor.apple.helper", kind: "bundleid").0, "orphaned")
        XCTAssertEqual(ident().classify("com.apple.Safari", kind: "bundleid").0, "system")
    }

    func testSafariDoesNotOwnUnrelatedBundleEndingInSafari() {
        let safari = AppRecord(path: "/System/Applications/Safari.app", displayName: "Safari", bundleId: "com.apple.Safari")
        let id = ident([safari])
        let (status, owner) = id.classify("com.sentinelone.sentinel-helper.safari", kind: "bundleid")
        XCTAssertEqual(status, "orphaned", owner ?? "")
        XCTAssertEqual(id.classify("com.apple.Safari", kind: "bundleid").0, "owned")
    }

    func testChromeDoesNotOwnUnrelatedBundleEndingInChrome() {
        let chrome = AppRecord(path: "/Applications/Google Chrome.app", displayName: "Google Chrome", bundleId: "com.google.Chrome")
        XCTAssertEqual(ident([chrome]).classify("com.uninstalled.helper.chrome", kind: "bundleid").0, "orphaned")
    }

    func testDesktopBundleLastTokenDoesNotOwnUnrelatedApp() {
        let drawio = AppRecord(
            path: "/Applications/draw.io.app",
            displayName: "draw.io",
            bundleId: "com.jgraph.drawio.desktop"
        )
        let id = ident([drawio])
        let (status, owner) = id.classify("ai.opencode.desktop", kind: "dir")
        XCTAssertEqual(status, "orphaned", owner ?? "")
        XCTAssertEqual(id.classify("com.jgraph.drawio.desktop", kind: "plist").0, "owned")
        XCTAssertEqual(id.classify("com.jgraph.drawio.desktop.PreviewExtension", kind: "bundleid").0, "owned")
    }

    func testOpencodeFormulaOwnsAiOpencodeDesktopNotDrawio() {
        let drawio = AppRecord(
            path: "/Applications/draw.io.app",
            displayName: "draw.io",
            bundleId: "com.jgraph.drawio.desktop"
        )
        let id = ident([drawio], formulas: [Formula(name: "opencode")])
        let (status, owner) = id.classify("ai.opencode.desktop", kind: "dir")
        XCTAssertEqual(status, "owned")
        XCTAssertNotEqual(owner, "draw.io", owner ?? "")
        XCTAssertEqual(id.classify("@opencode-ai", kind: "dir").0, "owned")
    }

    func testGitHubDesktopDoesNotOwnIoGithubProjects() {
        let gh = AppRecord(
            path: "/Applications/GitHub Desktop.app",
            displayName: "GitHub Desktop",
            bundleId: "com.github.GitHubClient"
        )
        let id = ident([gh])
        XCTAssertEqual(id.classify("io.github.skylot.jadx", kind: "dir").0, "orphaned")
        XCTAssertEqual(id.classify("com.github.GitHubClient", kind: "bundleid").0, "owned")
        XCTAssertEqual(id.classify("com.github.GitHubClient.ShipIt", kind: "dir").0, "owned")
    }

    func testGroupOrphanedLeftoversDoesNotMergeIoGithubProjects() {
        let jadx = DataItem(
            path: "/Users/x/Library/Application Support/io.github.skylot.jadx",
            name: "io.github.skylot.jadx",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 100
        )
        let other = DataItem(
            path: "/Users/x/Library/Caches/io.github.someone.else",
            name: "io.github.someone.else",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 50
        )
        let grouped = groupOrphanedLeftovers([jadx, other])
        XCTAssertEqual(grouped.count, 2)
    }

    func testVendorDirStillOwnedWhenAppInstalled() {
        let chrome = AppRecord(path: "/Applications/Google Chrome.app", displayName: "Google Chrome", bundleId: "com.google.Chrome")
        let (status, _) = ident([chrome]).classify("Google", kind: "dir")
        XCTAssertEqual(status, "owned")
    }

    func testShortSubstringDoesNotOwnUnrelatedFolder() {
        let gmail = AppRecord(path: "/Applications/Gmail.app", displayName: "Gmail", bundleId: "com.google.Gmail")
        let (status, _) = ident([gmail]).classify("Mail", kind: "dir")
        XCTAssertEqual(status, "orphaned")
    }

    func testVscodeOwnsCodeSupportDir() {
        let vscode = AppRecord(path: "/Applications/Visual Studio Code.app", displayName: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
        XCTAssertEqual(ident([vscode]).classify("code", kind: "dir").0, "owned")
        XCTAssertEqual(ident([vscode]).classify("Visual Studio Code", kind: "dir").0, "owned")
    }

    func testAccentedAppNameOwnsNFCAndNFDLeftovers() {
        let nfc = "Café"
        let nfd = "Cafe\u{0301}"
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        let app = AppRecord(path: "/Applications/Café.app", displayName: nfc, bundleId: "org.example.cafe")
        let id = ident([app])
        XCTAssertEqual(id.classify(nfc, kind: "dir").0, "owned")
        XCTAssertEqual(id.classify(nfd, kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("Cafe", kind: "dir").0, "owned")
    }

    func testAppleBundleIsSystem() {
        XCTAssertEqual(ident().classify("com.apple.Safari", kind: "bundleid").0, "system")
    }

    func testBrewFormulaPrefixCacheIsOwned() {
        XCTAssertEqual(ident([], formulas: [Formula(name: "go")]).classify("go-build", kind: "dir").0, "system")
    }

    func testTesseractFormulaDoesNotOwnTesseractRs() {
        XCTAssertEqual(
            ident([], formulas: [Formula(name: "tesseract")]).classify("tesseract-rs", kind: "dir").0,
            "orphaned"
        )
    }

    func testNodeFormulaDoesNotOwnNodeGypAsAppLeftover() {
        XCTAssertEqual(
            ident([], formulas: [Formula(name: "node")]).classify("node-gyp", kind: "dir").0,
            "system"
        )
    }

    func testHyphenatedCaskPrefixStillOwnsUpdaterCache() {
        XCTAssertEqual(
            ident([], casks: [Cask(name: "podman-desktop")]).classify("podman-desktop-updater", kind: "dir").0,
            "owned"
        )
    }

    func testUserToolConfigsAreNotOrphaned() {
        for name in ["fish", "zsh", "git", "nvim", "ssh", "fontconfig"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testHyphenatedAppDataIsNotSystem() {
        for name in ["git-cola", "docker-desktop", "npm-check-updates", "go-task"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "orphaned", name)
        }
    }

    func testAppleSupportDirsAreSystem() {
        for name in [
            "CrashReporter", "CloudDocs", "CallHistoryDB", "CallHistoryTransactions",
            "FileProvider", "AskPermission", "DifferentialPrivacy", "DiskImages",
            "Knowledge", "icdd", "networkserviceproxy", "Instruments",
        ] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testAppleDaemonPrefsAreSystem() {
        for name in [
            "familycircled.plist", "corespotlightd.plist", "loginwindow.plist",
            "org.cups.PrintingPrefs.plist", "sharedfilelistd.plist",
        ] {
            XCTAssertEqual(ident().classify(name, kind: "plist").0, "system", name)
        }
    }

    func testAppleLogDirsAreSystem() {
        for name in ["DiagnosticReports", "CoreSimulator", "Baseband", "SiriTTSService"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testShortcutsGroupContainerIsSystem() {
        XCTAssertEqual(ident().classify("group.is.workflow.shortcuts", kind: "group").0, "system")
    }

    func testWebkitDatabasesIsSystem() {
        XCTAssertEqual(ident().classify("Databases", kind: "dir").0, "system")
    }

    func testItermOwnsIterm2SupportDir() {
        let iterm = AppRecord(
            path: "/Applications/iTerm.app",
            displayName: "iTerm2",
            bundleId: "com.googlecode.iterm2",
            extra: ["executable": "iTerm2"]
        )
        let id = ident([iterm])
        XCTAssertEqual(id.classify("iTerm2", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("iTerm", kind: "dir").0, "owned")
    }

    func testInstalledAppHyphenPrefixOwnsCache() {
        let cursor = AppRecord(
            path: "/Applications/Cursor.app",
            displayName: "Cursor",
            bundleId: "com.todesktop.230313mzl4w4u92",
            extra: ["executable": "Cursor"]
        )
        XCTAssertEqual(ident([cursor]).classify("cursor-compile-cache", kind: "dir").0, "owned")
    }

    func testChromeUnderscoreHelperCacheIsOwned() {
        let chrome = AppRecord(
            path: "/Applications/Google Chrome.app",
            displayName: "Google Chrome",
            bundleId: "com.google.Chrome",
            extra: ["executable": "Google Chrome"]
        )
        let id = ident([chrome])
        XCTAssertEqual(id.classify("chrome_crashpad_handler", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("Google Meet", kind: "dir").0, "owned")
    }

    func testPlausiblelabsCrashreporterIsSystem() {
        XCTAssertEqual(ident().classify("com.plausiblelabs.crashreporter.data", kind: "dir").0, "system")
    }

    func testMoreApplePrefsAndToolsAreSystem() {
        for (name, kind) in [
            ("TokenBucketRateLimiter.plist", "plist"),
            ("AMSDataMigratorTool", "dir"),
            ("group.tvappservices.container", "group"),
            ("Python Entry Points", "dir"),
            ("com.qtproject.plist", "plist"),
        ] {
            XCTAssertEqual(ident().classify(name, kind: kind).0, "system", name)
        }
    }

    func testCliToolchainDirsAreNotOrphaned() {
        for name in ["uv", "bun", "go", "go-build", "virtualenv", "node-gyp", "configstore", "helm", "gh", "swift-build", "gcloud", "btop", "wasmtime", "zls"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testK8sAndNvidiaCachesAreSystem() {
        for name in ["kube", "kubebuilder-envtest", "JetPackCache"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testSharedSdkDirsAreSystem() {
        for name in ["CEF", "io.sentry", "io.branch", "BytecodeAlliance.wasmtime", "dev.biomejs.biome"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testBraveOwnsBravesoftwareDir() {
        let brave = AppRecord(path: "/Applications/Brave Browser.app", displayName: "Brave Browser", bundleId: "com.brave.Browser")
        XCTAssertEqual(ident([brave]).classify("BraveSoftware", kind: "dir").0, "owned")
    }

    func testZoomOwnsTeamidGroupAndLogs() {
        let zoom = AppRecord(path: "/Applications/zoom.us.app", displayName: "zoom.us", bundleId: "us.zoom.xos")
        let id = ident([zoom])
        XCTAssertEqual(id.classify("BJ4HAAB9B3.ZoomClient3rd", kind: "group").0, "owned")
        XCTAssertEqual(id.classify("ZoomChat.plist", kind: "plist").0, "owned")
        XCTAssertEqual(id.classify("ZoomPhone", kind: "dir").0, "owned")
    }

    func testDisplayNameOwnsReverseDnsWithoutBundleId() {
        let proton = AppRecord(path: "/Applications/Proton Authenticator.app", displayName: "Proton Authenticator", bundleId: nil)
        let id = ident([proton])
        XCTAssertEqual(id.classify("group.me.proton.authenticator", kind: "group").0, "owned")
        XCTAssertEqual(id.classify("Mail", kind: "dir").0, "orphaned")
    }

    func testFirefoxOwnsMozillaData() {
        let firefox = AppRecord(path: "/usr/bin/firefox", displayName: "Firefox Web Browser", bundleId: "firefox")
        XCTAssertEqual(ident([firefox]).classify("mozilla", kind: "dir").0, "owned")
        XCTAssertEqual(ident([firefox]).classify("org.mozilla.firefox", kind: "dir").0, "owned")
    }

    func testDesktopIdVendorOwnsMozilla() {
        let firefox = AppRecord(
            path: "/usr/bin/firefox",
            displayName: "Firefox Web Browser",
            bundleId: "firefox",
            extra: ["desktop": "/usr/share/applications/org.mozilla.firefox.desktop"]
        )
        XCTAssertEqual(ident([firefox]).classify("mozilla", kind: "dir").0, "owned")
    }

    func testDesktopIdOwnsFlatpakVarAppDir() {
        let firefox = AppRecord(
            path: "/usr/bin/firefox",
            displayName: "Firefox Web Browser",
            bundleId: "firefox",
            extra: [
                "desktop": "/usr/share/applications/org.mozilla.firefox.desktop",
                "desktop_id": "org.mozilla.firefox",
            ]
        )
        XCTAssertEqual(ident([firefox]).classify("org.mozilla.firefox", kind: "dir").0, "owned")
    }

    func testSnapUnderscoreDesktopOwnsUnprefixedDir() {
        let chromium = AppRecord(
            path: "/snap/bin/chromium",
            displayName: "Snap App",
            bundleId: "other",
            extra: [
                "desktop": "/var/lib/snapd/desktop/applications/chromium_chromium.desktop",
                "desktop_id": "chromium_chromium",
            ]
        )
        XCTAssertEqual(ident([chromium]).classify("chromium", kind: "dir").0, "owned")
    }

    func testWmclassOwnsHyphenatedConfigDir() {
        let app = AppRecord(
            path: "/usr/bin/code",
            displayName: "Code Editor",
            bundleId: "code-oss",
            extra: ["desktop_id": "code-oss", "wmclass": "Code", "executable": "code"]
        )
        XCTAssertEqual(ident([app]).classify("Code", kind: "dir").0, "owned")
    }

    func testPythonExecDoesNotOwnInterpreterCache() {
        let script = AppRecord(
            path: "/usr/bin/python3",
            displayName: "Some Script",
            bundleId: "some-script",
            extra: ["desktop_id": "some-script", "executable": "python3"]
        )
        XCTAssertEqual(ident([script]).classify("python3", kind: "dir").0, "orphaned")
    }

    func testOsAndToolchainCachesAreSystem() {
        for name in ["softwareupdate", "Homebrew", "org.swift.swiftpm"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "system", name)
        }
    }

    func testUuidContainerIsSystem() {
        XCTAssertEqual(ident().classify("327CBE65-0A3B-4C21-9F8A-1D2E3F4A5B6C", kind: "bundleid").0, "system")
        XCTAssertEqual(ident().classify("327CBE65-0A3B-4C21-9F8A-1D2E3F4A5B6C", kind: "group").0, "system")
        XCTAssertEqual(ident().classify("327cbe65-2c70-46c0-9a01-4312af0dd165", kind: "dir").0, "system")
        XCTAssertEqual(ident().classify("BBEdit", kind: "dir").0, "orphaned")
    }

    func testSimilarAppleRateLimiterPrefIsSystem() {
        XCTAssertEqual(ident().classify("FooBarRateLimiter.plist", kind: "plist").0, "system")
    }

    func testBrewFormulaOwnsVendorPrefixedLeftover() {
        XCTAssertEqual(
            ident([], formulas: [Formula(name: "pake")]).classify("com.pake.a3da67b.plist", kind: "plist").0,
            "owned"
        )
    }

    func testBrewFormulaOwnsScopedPackageDir() {
        XCTAssertEqual(
            ident([], formulas: [Formula(name: "opencode")]).classify("@opencode-ai", kind: "dir").0,
            "owned"
        )
    }

    func testBrewCaskOwnsLeftoverBundleLastToken() {
        XCTAssertEqual(
            ident([], casks: [Cask(name: "bbedit")]).classify("com.barebones.bbedit", kind: "bundleid").0,
            "owned"
        )
        XCTAssertEqual(
            ident([], casks: [Cask(name: "bbedit")]).classify("com.barebones.UpdateKit", kind: "dir").0,
            "orphaned"
        )
    }

    func testShortBrewNameDoesNotOwnUnrelatedVendor() {
        XCTAssertEqual(
            ident([], formulas: [Formula(name: "go")]).classify("com.google.Chrome", kind: "bundleid").0,
            "orphaned"
        )
    }

    func testInstalledUserToolOwnsConfigDir() {
        let id = ident([], tools: ["herdr", "huginn", "playwright", "wine"])
        XCTAssertEqual(id.classify("herdr", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("huginn", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("org.webkit.Playwright", kind: "bundleid").0, "owned")
        XCTAssertEqual(id.classify("wine", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("BetterDisplay", kind: "dir").0, "orphaned")
    }

    func testGenericOrShortUserToolDoesNotOwnUnrelatedLeftover() {
        XCTAssertEqual(
            ident([], tools: ["python3", "go"]).classify("com.google.Chrome", kind: "bundleid").0,
            "orphaned"
        )
        XCTAssertEqual(
            ident([], tools: ["python3"]).classify("python3", kind: "dir").0,
            "orphaned"
        )
        XCTAssertEqual(
            ident([], tools: ["agent"]).classify("com.minimax.agent", kind: "bundleid").0,
            "orphaned"
        )
        XCTAssertEqual(
            ident([], formulas: [Formula(name: "agent")]).classify("com.minimax.agent", kind: "dir").0,
            "orphaned"
        )
    }

    func testPathBinaryInsideSupportAppOwnsBundleLeftover() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("dialog-path-\(UUID().uuidString)")
        let app = td.appendingPathComponent("Library/Application Support/Dialog/Dialog.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleDisplayName": "Dialog",
            "CFBundleIdentifier": "au.csiro.dialog",
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = macOS.appendingPathComponent("dialogcli")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let bin = td.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("dialog").path,
            withDestinationPath: exe.path
        )
        XCTAssertFalse(isRealAppPath(app.path))
        let found = appsFromPathBinaries(dirs: [bin.path])
        XCTAssertEqual(found.map(\.bundleId), ["au.csiro.dialog"])
        XCTAssertEqual(ident(found).classify("au.csiro.dialog.plist", kind: "plist").0, "owned")
        XCTAssertEqual(ident(found).classify("au.csiro.dialog", kind: "bundleid").0, "owned")
        XCTAssertEqual(ident().classify("au.csiro.dialog.plist", kind: "plist").0, "orphaned")
    }

    func testListUserToolNamesReadsExecutables() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let herdr = dir.appendingPathComponent("herdr")
        try Data("#!/bin/sh\n".utf8).write(to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        try Data("nope\n".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        let names = Set(listUserToolNames(dirs: [dir.path]))
        XCTAssertTrue(names.contains("herdr"), "\(names)")
        XCTAssertFalse(names.contains("readme.txt"), "\(names)")
    }

    func testListUserToolNamesIncludesWineFromWhich() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tools-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = Set(listUserToolNames(dirs: [dir.path], which: { $0 == "wine" ? "/usr/bin/wine" : nil }))
        XCTAssertTrue(names.contains("wine"), "\(names)")
    }

    func testListUserToolNamesIncludesDockerFromWhich() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tools-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = Set(listUserToolNames(
            dirs: [dir.path],
            which: { $0 == "docker" ? "/usr/bin/docker" : nil }
        ))
        XCTAssertTrue(names.contains("docker"), "\(names)")
        XCTAssertEqual(
            ident([], tools: ["docker"]).classify("docker", kind: "dir").0,
            "owned"
        )
        XCTAssertEqual(
            ident([], tools: ["docker"]).classify("com.docker.docker", kind: "bundleid").0,
            "owned"
        )
    }

    func testWineToolOwnsWineprefixesDir() {
        let id = ident([], tools: ["wine"])
        XCTAssertEqual(id.classify("wineprefixes", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("winebottler", kind: "dir").0, "orphaned")
        XCTAssertEqual(ident().classify("wineprefixes", kind: "dir").0, "orphaned")
    }

    func testPlaywrightOwnsWebkitMiniBrowser() {
        XCTAssertEqual(
            ident([], tools: ["playwright"]).classify("org.webkit.MiniBrowser", kind: "bundleid").0,
            "owned"
        )
        XCTAssertEqual(
            ident([], tools: ["playwright"]).classify("org.webkit.Safari", kind: "bundleid").0,
            "orphaned"
        )
    }

    func testHyphenatedUserToolOwnsMatchingDir() {
        XCTAssertEqual(
            ident([], tools: ["mini-swe-agent"]).classify("mini-swe-agent", kind: "dir").0,
            "owned"
        )
        XCTAssertEqual(ident().classify("mini-swe-agent", kind: "dir").0, "orphaned")
    }

    func testPlaywrightOwnsMsPlaywrightMcpCache() {
        let id = ident([], tools: ["playwright"])
        XCTAssertEqual(id.classify("ms-playwright-mcp", kind: "dir").0, "owned")
        XCTAssertEqual(id.classify("ms-playwrights-mcp", kind: "dir").0, "orphaned")
        XCTAssertEqual(ident().classify("ms-playwright-mcp", kind: "dir").0, "orphaned")
    }

    func testDialogToolDoesNotOwnUnrelatedCsiroPlist() {
        XCTAssertEqual(
            ident([], tools: ["dialog"]).classify("au.csiro.dialog.plist", kind: "plist").0,
            "orphaned"
        )
        XCTAssertEqual(
            ident([], tools: ["dialog"]).classify("dialog", kind: "dir").0,
            "orphaned"
        )
    }

    func testAndroidSdkOwnsEmulatorLeftover() {
        XCTAssertEqual(
            ident([], tools: ["android"]).classify("com.android.Emulator", kind: "plist").0,
            "owned"
        )
        XCTAssertEqual(
            ident().classify("com.android.Emulator", kind: "plist").0,
            "orphaned"
        )
    }

    func testListUserToolNamesIncludesAndroidWhenSdkPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let sdk = root.appendingPathComponent("Android")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("emulator"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = Set(listUserToolNames(dirs: [bin.path], which: { _ in nil }, sdkDirs: [sdk.path]))
        XCTAssertTrue(names.contains("android"), "\(names)")
        let empty = root.appendingPathComponent("EmptyAndroid")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let skip = Set(listUserToolNames(dirs: [bin.path], which: { _ in nil }, sdkDirs: [empty.path]))
        XCTAssertFalse(skip.contains("android"), "\(skip)")
    }

    func testUninstalledGuiAppsStayOrphaned() {
        for (name, kind) in [
            ("BBEdit", "dir"),
            ("LibreOffice", "dir"),
            ("BraveSoftware", "dir"),
            ("BetterDisplay", "dir"),
            ("com.barebones.bbedit", "bundleid"),
            ("pro.betterdisplay.BetterDisplay", "dir"),
        ] {
            XCTAssertEqual(ident().classify(name, kind: kind).0, "orphaned", name)
        }
    }

    func testTeamIdGroupStaysOrphanedWhenAppGone() {
        for name in ["G69SCX94XU.duck", "UBF8T346G9.ms", "BJ4HAAB9B3.ZoomClient3rd"] {
            XCTAssertEqual(ident().classify(name, kind: "group").0, "orphaned", name)
        }
    }

    func testMicrosoftGroupOwnedWhenTeamsInstalled() {
        let teams = AppRecord(path: "/Applications/Microsoft Teams.app", displayName: "Microsoft Teams", bundleId: "com.microsoft.teams2")
        let id = ident([teams])
        XCTAssertEqual(id.classify("UBF8T346G9.ms", kind: "group").0, "owned")
        XCTAssertEqual(id.classify("UBF8T346G9.Office", kind: "group").0, "owned")
    }

    func testDuckduckgoGroupOwnedWhenAppInstalled() {
        let ddg = AppRecord(path: "/Applications/DuckDuckGo.app", displayName: "DuckDuckGo", bundleId: "com.duckduckgo.macos.browser")
        XCTAssertEqual(ident([ddg]).classify("G69SCX94XU.duck", kind: "group").0, "owned")
    }

    func testGmailStillDoesNotOwnMailWithCliSystemDirs() {
        let gmail = AppRecord(path: "/Applications/Gmail.app", displayName: "Gmail", bundleId: "com.google.Gmail")
        let id = ident([gmail])
        XCTAssertEqual(id.classify("Mail", kind: "dir").0, "orphaned")
        XCTAssertEqual(id.classify("uv", kind: "dir").0, "system")
    }

    func testAppatticIdsAreSystem() {
        for (name, kind) in [
            ("com.appattic.app.plist", "plist"),
            ("com.appattic.app", "bundleid"),
            ("com.appattic.helper", "dir"),
            ("group.com.appattic.shared", "group"),
        ] {
            XCTAssertEqual(ident().classify(name, kind: kind).0, "system", name)
        }
    }

    func testPersonalToolConfigsStayOrphaned() {
        for name in ["quarto", "opencode", "crewai", "herald", "mcp", "huginn", "hf", "backend"] {
            XCTAssertEqual(ident().classify(name, kind: "dir").0, "orphaned", name)
        }
    }

    func testDirKindSkipsLooseFiles() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: td) }
        try FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        let f = td.appendingPathComponent("default.store")
        try Data().write(to: f)
        let d = td.appendingPathComponent("RealApp")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        XCTAssertFalse(includeScanEntry(f.path, kind: "dir"))
        XCTAssertTrue(includeScanEntry(d.path, kind: "dir"))
        XCTAssertTrue(includeScanEntry(f.path, kind: "mixed"))
        XCTAssertTrue(includeScanEntry(d.path, kind: "mixed"))
    }

    func testThresholdsMatchRecommend() {
        XCTAssertEqual(activeDays, 30)
        XCTAssertEqual(staleDays, 180)
        // Both "significant data" tests feed this constant in as their input,
        // so without a pin a change to it leaves them green.
        XCTAssertEqual(dataKeepThreshold, 50 * 1024 * 1024)
    }

    func testScanLeftoversMeasuresOrphanedDirectoryBytes() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("left-size-\(UUID().uuidString)")
        let support = td.appendingPathComponent("Application Support")
        let orphan = support.appendingPathComponent("CamoufoxGone")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try Data(repeating: 0x62, count: 8000).write(to: orphan.appendingPathComponent("cache.bin"))
        let old = Date().addingTimeInterval(-90 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: orphan.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: orphan.appendingPathComponent("cache.bin").path)
        let brew = BrewSnapshot(available: false)
        let (items, _) = scanLeftovers(
            apps: [],
            brew: brew,
            roots: [("Application Support", support.path, "dir")],
            measureSizes: true
        )
        let hit = items.first { $0.name == "CamoufoxGone" }
        XCTAssertEqual(hit?.status, "orphaned")
        XCTAssertEqual(hit?.sizeMeasured, true, "orphaned leftover dir must have a measured size")
        XCTAssertGreaterThanOrEqual(hit?.sizeBytes ?? 0, 8000)
    }

    func testScanLeftoversGroupsSameOrphanNameAcrossRoots() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("left-group-\(UUID().uuidString)")
        let support = td.appendingPathComponent("Application Support")
        let caches = td.appendingPathComponent("Caches")
        let prefs = td.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("crewai"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("crewai"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try Data(repeating: 0x61, count: 8000).write(to: support.appendingPathComponent("crewai").appendingPathComponent("a.bin"))
        try Data(repeating: 0x62, count: 2000).write(to: caches.appendingPathComponent("crewai").appendingPathComponent("b.bin"))
        try Data(repeating: 0x63, count: 100).write(to: prefs.appendingPathComponent("crewai.plist"))
        let old = Date().addingTimeInterval(-90 * 86400)
        let stamp = [
            support.appendingPathComponent("crewai").path,
            support.appendingPathComponent("crewai").appendingPathComponent("a.bin").path,
            caches.appendingPathComponent("crewai").path,
            caches.appendingPathComponent("crewai").appendingPathComponent("b.bin").path,
            prefs.appendingPathComponent("crewai.plist").path,
        ]
        for p in stamp {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: p)
        }
        let (items, _) = scanLeftovers(
            apps: [],
            brew: BrewSnapshot(available: false),
            roots: [
                ("Application Support", support.path, "dir"),
                ("Caches", caches.path, "dir"),
                ("Preferences", prefs.path, "plist"),
            ],
            measureSizes: true
        )
        let hits = items.filter { $0.status == "orphaned" && norm(entryLabel($0.name)) == "crewai" }
        XCTAssertEqual(hits.count, 1, hits.map { "\($0.name) \($0.rootLabel) \($0.path)" }.joined(separator: " | "))
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.rootLabel, "Application Support")
        XCTAssertGreaterThanOrEqual(hit.sizeBytes, 10_100)
        XCTAssertEqual(Set(hit.extraPaths.map { URL(fileURLWithPath: $0).lastPathComponent }), ["crewai", "crewai.plist"])
        XCTAssertFalse(hit.reason?.localizedCaseInsensitiveContains("broken command") == true, hit.reason ?? "")
        // The two extra names are ordinary data, not PATH entries, so the
        // reason counts the places and never claims a broken command. Spelled
        // out so a nil reason cannot pass the negative check above.
        XCTAssertEqual(hit.reason, "Leftover data in 3 places.")
        XCTAssertTrue(hit.summary?.contains("2 more") == true, hit.summary ?? "")
        let cmd = leftoverRemoveCommand(path: hit.path, rootLabel: hit.rootLabel, extraPaths: hit.extraPaths)
        XCTAssertTrue(cmd.contains("crewai.plist"), cmd)
        XCTAssertTrue(cmd.contains("Caches"), cmd)
    }

    func testGroupOrphanedLeftoversKeepsLaunchAgentsSeparate() {
        let agent = DataItem(
            path: "/Users/x/Library/LaunchAgents/crc.daemon.plist",
            name: "crc.daemon",
            rootLabel: "LaunchAgents",
            kind: "plist",
            status: "orphaned",
            sizeBytes: 200
        )
        let support = DataItem(
            path: "/Users/x/Library/Application Support/crc.daemon",
            name: "crc.daemon",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 50_000
        )
        let other = DataItem(
            path: "/Users/x/Library/Caches/OtherApp",
            name: "OtherApp",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 10
        )
        let grouped = groupOrphanedLeftovers([agent, support, other])
        XCTAssertEqual(grouped.count, 3)
        XCTAssertEqual(Set(grouped.map(\.rootLabel)), ["LaunchAgents", "Application Support", "Caches"])
    }

    func testGroupOrphanedLeftoversPrefersDirectoryOverSymlinkPrimary() {
        let folder = DataItem(
            path: "/Users/x/Library/Application Support/mini-swe-agent",
            name: "mini-swe-agent",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 0,
            sizeMeasured: true
        )
        let link = DataItem(
            path: "/Users/x/.local/bin/mini-swe-agent",
            name: "mini-swe-agent",
            rootLabel: ".local/bin",
            kind: "symlink",
            status: "orphaned",
            sizeBytes: 71,
            extraPaths: ["/Users/x/.local/bin/mini-swe-agent.bat"]
        )
        let grouped = groupOrphanedLeftovers([link, folder])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].rootLabel, "Application Support")
        XCTAssertEqual(Set(grouped[0].extraPaths), [
            "/Users/x/.local/bin/mini-swe-agent",
            "/Users/x/.local/bin/mini-swe-agent.bat",
        ])
        applyOrphanReasons(grouped)
        XCTAssertFalse(grouped[0].reason?.localizedCaseInsensitiveContains("broken command") == true, grouped[0].reason ?? "")
        // The directory row won, so the reason is the leftover text for the
        // directory, with the two PATH names counted onto it. A symlink primary
        // would print "Broken PATH command." instead.
        XCTAssertEqual(grouped[0].reason, "Application Support leftover. Also 2 leftover names on PATH.")
    }

    func testGroupOrphanedLeftoversMergesBundleIdChildren() throws {
        let parent = DataItem(
            path: "/Users/x/Library/Caches/com.kagi.kagimacOS",
            name: "com.kagi.kagimacOS",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 1000
        )
        let child = DataItem(
            path: "/Users/x/Library/Containers/com.kagi.kagimacOS.ShareExtension",
            name: "com.kagi.kagimacOS.ShareExtension",
            rootLabel: "Containers",
            kind: "bundleid",
            status: "orphaned",
            sizeBytes: 0,
            sizeMeasured: false
        )
        let whisky = DataItem(
            path: "/Users/x/Library/Application Support/com.isaacmarovitz.Whisky",
            name: "com.isaacmarovitz.Whisky",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 8000
        )
        let thumb = DataItem(
            path: "/Users/x/Library/Containers/com.isaacmarovitz.Whisky.WhiskyThumbnail",
            name: "com.isaacmarovitz.Whisky.WhiskyThumbnail",
            rootLabel: "Containers",
            kind: "bundleid",
            status: "orphaned",
            sizeBytes: 0,
            sizeMeasured: false
        )
        let grouped = Dictionary(uniqueKeysWithValues: groupOrphanedLeftovers([parent, child, whisky, thumb]).map { ($0.name, $0) })
        XCTAssertEqual(Set(grouped.keys), ["com.kagi.kagimacOS", "com.isaacmarovitz.Whisky"])
        XCTAssertEqual(grouped["com.kagi.kagimacOS"]?.extraPaths, [child.path])
        XCTAssertEqual(grouped["com.isaacmarovitz.Whisky"]?.extraPaths, [thumb.path])
    }

    func testGroupOrphanedLeftoversDoesNotMergeUnrelatedPrefix() {
        let support = DataItem(
            path: "/Users/x/Library/Application Support/Duck",
            name: "Duck",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 100
        )
        let group = DataItem(
            path: "/Users/x/Library/Group Containers/G69SCX94XU.duck",
            name: "G69SCX94XU.duck",
            rootLabel: "Group Containers",
            kind: "group",
            status: "orphaned",
            sizeMeasured: false
        )
        let grouped = groupOrphanedLeftovers([support, group])
        XCTAssertEqual(grouped.count, 2)
    }

    func testGroupOrphanedLeftoversMergesBetterDisplay() {
        let support = DataItem(
            path: "/Users/x/Library/Application Support/BetterDisplay",
            name: "BetterDisplay",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 100
        )
        let cache = DataItem(
            path: "/Users/x/Library/Caches/pro.betterdisplay.BetterDisplay",
            name: "pro.betterdisplay.BetterDisplay",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 200
        )
        let grouped = groupOrphanedLeftovers([support, cache])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].name, "pro.betterdisplay.BetterDisplay")
        XCTAssertEqual(grouped[0].extraPaths, [support.path])
        XCTAssertEqual(grouped[0].sizeBytes, 300)
    }

    func testGroupOrphanedLeftoversMergesKagiOrion() throws {
        let orion = DataItem(
            path: "/Users/x/Library/Application Support/Orion",
            name: "Orion",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 60_000_000
        )
        let kagi = DataItem(
            path: "/Users/x/Library/Caches/com.kagi.kagimacOS",
            name: "com.kagi.kagimacOS",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 30_000_000
        )
        let share = DataItem(
            path: "/Users/x/Library/Containers/com.kagi.kagimacOS.ShareExtension",
            name: "com.kagi.kagimacOS.ShareExtension",
            rootLabel: "Containers",
            kind: "bundleid",
            status: "orphaned",
            sizeMeasured: false
        )
        let other = DataItem(
            path: "/Users/x/Library/Application Support/BetterDisplay",
            name: "BetterDisplay",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 100
        )
        let grouped = groupOrphanedLeftovers([orion, kagi, share, other])
        XCTAssertEqual(grouped.count, 2)
        // Unwrapped, not `?.extraPaths ?? []`: a missing row compares equal to
        // the empty expectation, so the merge would read as "nothing absorbed
        // BetterDisplay" whether or not the row survived grouping.
        let browser = try XCTUnwrap(grouped.first { leftoverGroupKey($0.name) == "kagi" })
        XCTAssertEqual(browser.name, "Orion")
        XCTAssertEqual(Set(browser.extraPaths), [kagi.path, share.path])
        let standalone = try XCTUnwrap(grouped.first { $0.name == "BetterDisplay" })
        XCTAssertTrue(standalone.extraPaths.isEmpty, standalone.extraPaths.joined(separator: " | "))
    }

    func testGroupOrphanedLeftoversMergesMinimaxUpdaterCache() throws {
        let updater = DataItem(
            path: "/Users/x/Library/Caches/@mmx-agentelectron-updater",
            name: "@mmx-agentelectron-updater",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 400_000_000
        )
        let agent = DataItem(
            path: "/Users/x/Library/Caches/com.minimax.agent",
            name: "com.minimax.agent",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 100_000
        )
        let ship = DataItem(
            path: "/Users/x/Library/Caches/com.minimax.agent.ShipIt",
            name: "com.minimax.agent.ShipIt",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 1_000
        )
        let http = DataItem(
            path: "/Users/x/Library/HTTPStorages/com.minimax.agent",
            name: "com.minimax.agent",
            rootLabel: "HTTPStorages",
            kind: "mixed",
            status: "orphaned",
            sizeBytes: 50_000
        )
        let other = DataItem(
            path: "/Users/x/Library/Application Support/camoufox",
            name: "camoufox",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 10
        )
        let grouped = groupOrphanedLeftovers([updater, agent, ship, http, other])
        XCTAssertEqual(grouped.count, 2)
        let mmx = try XCTUnwrap(grouped.first { leftoverGroupKey($0.name) == "minimax" })
        XCTAssertEqual(mmx.name, "@mmx-agentelectron-updater")
        XCTAssertEqual(Set(mmx.extraPaths), [agent.path, ship.path, http.path])
        let standalone = try XCTUnwrap(grouped.first { $0.name == "camoufox" })
        XCTAssertTrue(standalone.extraPaths.isEmpty, standalone.extraPaths.joined(separator: " | "))
    }

    func testGroupOrphanedLeftoversMergesHTTPStorageCookies() throws {
        let orion = DataItem(
            path: "/Users/x/Library/Application Support/Orion",
            name: "Orion",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 60_000_000
        )
        let store = DataItem(
            path: "/Users/x/Library/HTTPStorages/com.kagi.kagimacOS",
            name: "com.kagi.kagimacOS",
            rootLabel: "HTTPStorages",
            kind: "mixed",
            status: "orphaned",
            sizeBytes: 90_000
        )
        let cookies = DataItem(
            path: "/Users/x/Library/HTTPStorages/com.kagi.kagimacOS.binarycookies",
            name: "com.kagi.kagimacOS.binarycookies",
            rootLabel: "HTTPStorages",
            kind: "mixed",
            status: "orphaned",
            sizeBytes: 1_000
        )
        let grouped = groupOrphanedLeftovers([orion, store, cookies])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].name, "Orion")
        XCTAssertEqual(Set(grouped[0].extraPaths), [store.path, cookies.path])
    }

    func testGroupOrphanedLeftoversMergesSameDnsVendorPrefix() throws {
        let plist = DataItem(
            path: "/Users/x/Library/Preferences/com.sentinelone.SentinelAgent.plist",
            name: "com.sentinelone.SentinelAgent.plist",
            rootLabel: "Preferences",
            kind: "plist",
            status: "orphaned",
            sizeBytes: 42
        )
        let helper = DataItem(
            path: "/Users/x/Library/Containers/com.sentinelone.sentinel-helper.on-demand-scan",
            name: "com.sentinelone.sentinel-helper.on-demand-scan",
            rootLabel: "Containers",
            kind: "bundleid",
            status: "orphaned",
            sizeMeasured: false
        )
        let safari = DataItem(
            path: "/Users/x/Library/Containers/com.sentinelone.sentinel-helper.safari",
            name: "com.sentinelone.sentinel-helper.safari",
            rootLabel: "Containers",
            kind: "bundleid",
            status: "orphaned",
            sizeMeasured: false
        )
        let other = DataItem(
            path: "/Users/x/Library/Preferences/au.csiro.dialog.plist",
            name: "au.csiro.dialog.plist",
            rootLabel: "Preferences",
            kind: "plist",
            status: "orphaned",
            sizeBytes: 100
        )
        let agent = DataItem(
            path: "/Users/x/Library/LaunchAgents/com.sentinelone.sentinel-helper.plist",
            name: "com.sentinelone.sentinel-helper.plist",
            rootLabel: "LaunchAgents",
            kind: "plist",
            status: "orphaned",
            sizeBytes: 1
        )
        let grouped = groupOrphanedLeftovers([plist, helper, safari, other, agent])
        XCTAssertEqual(grouped.count, 3)
        // Unwrapped so a row that vanished from the grouping fails here instead
        // of comparing nil's empty path list against the empty expectation.
        let sent = try XCTUnwrap(grouped.first { $0.rootLabel != "LaunchAgents" && entryLabel($0.name).lowercased().hasPrefix("com.sentinelone.") })
        XCTAssertEqual(sent.extraPaths.count, 2, sent.name)
        let csiro = try XCTUnwrap(grouped.first { $0.name.contains("csiro") })
        XCTAssertTrue(csiro.extraPaths.isEmpty, csiro.extraPaths.joined(separator: " | "))
        let launchAgent = try XCTUnwrap(grouped.first { $0.rootLabel == "LaunchAgents" })
        XCTAssertTrue(launchAgent.extraPaths.isEmpty, launchAgent.extraPaths.joined(separator: " | "))
    }

    func testLeftoverMatchesCategoryMatchesANFDNameAgainstAnNFCQuery() {
        // The name off the disk is NFD, the argument on the command line is
        // whatever the shell and keyboard produced, which is NFC.
        let item = DataItem(
            path: "/Users/x/Library/Caches/com.example.Cafe\u{0301}",
            name: "com.example.Cafe\u{0301}",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned"
        )
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["café"]))
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["CAFÉ"]))
        XCTAssertFalse(leftoverMatchesCategory(item, categories: ["whisky"]))
    }

    func testLeftoverLocationLabelNotesExtraPaths() {
        XCTAssertEqual(leftoverLocationLabel(rootLabel: "Caches", extraCount: 0), "Caches")
        XCTAssertEqual(leftoverLocationLabel(rootLabel: "Application Support", extraCount: 3), "Application Support +3")
    }

    func testLeftoverMatchesCategoryIncludesExtraPaths() {
        let item = DataItem(
            path: "/Users/x/Library/Preferences/com.sentinelone.SentinelAgent.plist",
            name: "com.sentinelone.SentinelAgent.plist",
            rootLabel: "Preferences",
            kind: "plist",
            status: "orphaned",
            extraPaths: ["/Users/x/Library/Containers/com.sentinelone.sentinel-helper.safari"]
        )
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["containers"]))
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["pref"]))
        XCTAssertFalse(leftoverMatchesCategory(item, categories: ["caches"]))
        XCTAssertTrue(leftoverMatchesCategory(item, categories: []))
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["sentinelagent"]))
        let orion = DataItem(
            path: "/Users/x/Library/Application Support/Orion",
            name: "Orion",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            extraPaths: ["/Users/x/Library/Caches/com.kagi.kagimacOS"]
        )
        XCTAssertTrue(leftoverMatchesCategory(orion, categories: ["orion"]))
        XCTAssertTrue(leftoverMatchesCategory(orion, categories: ["kagi"]))
        XCTAssertFalse(leftoverMatchesCategory(orion, categories: ["whisky"]))
    }

    func testApplyOrphanReasonsDirGroupWithPathExtrasMentionsCommands() {
        let item = DataItem(
            path: "/Users/x/Library/Application Support/mini-swe-agent",
            name: "mini-swe-agent",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            extraPaths: [
                "/Users/x/.local/bin/mini",
                "/Users/x/.local/bin/mini-swe-agent",
            ]
        )
        applyOrphanReasons([item])
        XCTAssertTrue(item.reason?.contains("PATH") == true, item.reason ?? "")
        XCTAssertTrue(item.summary?.contains("2 more") == true, item.summary ?? "")
    }

    func testLeftoverDisplayNamePrefersFolderOverDns() {
        XCTAssertEqual(
            leftoverDisplayName(
                name: "pro.betterdisplay.BetterDisplay",
                extraPaths: ["/Users/x/Library/Application Support/BetterDisplay"]
            ),
            "BetterDisplay"
        )
        XCTAssertEqual(leftoverDisplayName(name: "com.isaacmarovitz.Whisky"), "Whisky")
        XCTAssertEqual(leftoverDisplayName(name: "com.sentinelone.SentinelAgent.plist"), "SentinelAgent")
        XCTAssertEqual(leftoverDisplayName(name: "com.obsidian.Obsidian.PLIST"), "Obsidian")
        XCTAssertEqual(leftoverDisplayName(name: "md.obsidian.plist"), "Obsidian")
        XCTAssertEqual(leftoverDisplayName(name: "@mmx-agentelectron-updater"), "Minimax")
        XCTAssertEqual(leftoverDisplayName(name: "G69SCX94XU.duck"), "Duck")
        XCTAssertEqual(leftoverDisplayName(name: "group.com.facebook.family"), "Facebook")
        XCTAssertEqual(leftoverDisplayName(name: "Orion"), "Orion")
        XCTAssertEqual(leftoverDisplayName(name: "python3.11"), "python3.11")
        XCTAssertEqual(leftoverDisplayName(name: "backend"), "backend")
        XCTAssertEqual(
            leftoverDisplayName(
                name: "Orion",
                extraPaths: ["/Users/x/Library/Caches/com.kagi.kagimacOS"]
            ),
            "Orion"
        )
    }

    func testLeftoverSummaryUsesDisplayName() {
        let what = leftoverSummary(
            rootLabel: "Caches",
            kind: "dir",
            name: "pro.betterdisplay.BetterDisplay",
            extraPaths: ["/Users/x/Library/Application Support/BetterDisplay"]
        )
        XCTAssertTrue(what.contains("BetterDisplay"), what)
        XCTAssertFalse(what.contains("pro.betterdisplay"), what)
        XCTAssertTrue(what.contains("1 more"), what)
        XCTAssertTrue(what.contains("Display manager"), what)
        XCTAssertTrue(what.contains("no longer installed") || what.contains("Display manager"), what)
    }

    func testLeftoverSummaryDescribesUninstalledApp() {
        let what = leftoverSummary(rootLabel: "Caches", kind: "dir", name: "UnknownApp")
        XCTAssertTrue(what.contains("UnknownApp"), what)
        XCTAssertTrue(what.contains("no longer installed"), what)
        XCTAssertTrue(what.contains("Cache"), what)
        XCTAssertFalse(what.contains("named UnknownApp"), what)
        let withBlurb = leftoverSummary(
            rootLabel: "Application Support",
            kind: "dir",
            name: "Whisky",
            appBlurb: "Wine wrapper for Windows games"
        )
        XCTAssertTrue(withBlurb.contains("Wine wrapper"), withBlurb)
        XCTAssertTrue(withBlurb.contains("Whisky"), withBlurb)
    }

    func testLeftoverAppBlurbFromCatalogAndAliases() {
        XCTAssertEqual(leftoverAppBlurb(name: "Orion"), "Web browser from Kagi")
        XCTAssertEqual(leftoverAppBlurb(name: "com.kagi.kagimacOS"), "Web browser from Kagi")
        XCTAssertNil(leftoverAppBlurb(name: "TotallyUnknownZzyzx"))
        XCTAssertEqual(
            leftoverAppBlurb(name: "Foo", catalog: ["foo": "A made-up tool"]),
            "A made-up tool"
        )
    }

    func testLeftoverAppBlurbDoesNotAnswerForNamesThatFoldToNothing() {
        // A cask titled 微信 has no `norm` key, so indexing it under "" would
        // make every other non-Latin leftover read as WeChat.
        let catalog = leftoverBlurbsFromSnapshot(
            BrewSnapshot(available: false, casks: [Cask(name: "wechat", desc: "Messaging app", titles: ["微信"])])
        )
        XCTAssertNil(catalog[""])
        XCTAssertEqual(leftoverAppBlurb(name: "微信", catalog: catalog), "Messaging app")
        XCTAssertNil(leftoverAppBlurb(name: "日本語データ", catalog: catalog))
    }

    func testLeftoverWhatTextRefreshesOldNamedCopy() {
        let refreshed = leftoverWhatText(
            rootLabel: "Application Support",
            kind: "dir",
            name: "BetterDisplay",
            storedSummary: "Application Support folder named BetterDisplay"
        )
        XCTAssertTrue(refreshed.contains("Display manager"), refreshed)
        XCTAssertFalse(refreshed.contains("named BetterDisplay"), refreshed)
        let kept = leftoverWhatText(
            rootLabel: "Application Support",
            kind: "dir",
            name: "iTerm2",
            storedSummary: "iTerm2: Terminal emulator. Leftover Application Support folder."
        )
        XCTAssertEqual(kept, "iTerm2: Terminal emulator. Leftover Application Support folder.")
        XCTAssertFalse(leftoverWhatLooksCurrent("Caches folder named Foo"))
        XCTAssertTrue(leftoverWhatLooksCurrent("Foo is no longer installed. Leftover Cache folder."))
    }

    func testApplyLeftoverAppBlurbsUsesSnapshotWithoutBrew() {
        let item = DataItem(
            path: "/tmp/iTerm2",
            name: "iTerm2",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned"
        )
        var brewCalled = false
        applyLeftoverAppBlurbs(
            [item],
            brew: BrewSnapshot(
                available: false,
                casks: [Cask(name: "iterm2", desc: "Terminal emulator", titles: ["iTerm2"], appNames: ["iTerm2.app"])]
            ),
            which: { _ in
                brewCalled = true
                return "/opt/homebrew/bin/brew"
            },
            run: { _, _ in
                brewCalled = true
                return (1, "", "")
            }
        )
        XCTAssertFalse(brewCalled)
        XCTAssertTrue(item.summary?.contains("Terminal emulator") == true, item.summary ?? "")
        XCTAssertTrue(item.summary?.contains("iTerm2") == true, item.summary ?? "")
    }

    func testLeftoverBlurbsFromBrewUsesCaskDesc() {
        let catalog = leftoverBlurbsFromBrew(
            tokens: ["iterm2"],
            which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil },
            run: { _, _ in
                (0, #"{"formulae":[],"casks":[{"token":"iterm2","desc":"Terminal emulator","name":["iTerm2"]}]}"#, "")
            }
        )
        XCTAssertEqual(catalog["iterm2"], "Terminal emulator")
        let item = DataItem(
            path: "/tmp/iTerm2",
            name: "iTerm2",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned"
        )
        applyOrphanReasons([item], catalog: catalog)
        XCTAssertTrue(item.summary?.contains("Terminal emulator") == true, item.summary ?? "")
    }

    func testLeftoverMatchesCategoryUsesDisplayName() {
        let item = DataItem(
            path: "/Users/x/Library/Caches/@mmx-agentelectron-updater",
            name: "@mmx-agentelectron-updater",
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned"
        )
        XCTAssertTrue(leftoverMatchesCategory(item, categories: ["minimax"]))
        XCTAssertFalse(leftoverMatchesCategory(item, categories: ["whisky"]))
    }

    func testGroupedLeftoverWhyDescribesMultiplePlaces() {
        let item = DataItem(
            path: "/Users/x/Library/Preferences/com.sentinelone.SentinelAgent.plist",
            name: "com.sentinelone.SentinelAgent.plist",
            rootLabel: "Preferences",
            kind: "plist",
            status: "orphaned",
            extraPaths: [
                "/Users/x/Library/Containers/com.sentinelone.sentinel-helper.on-demand-scan",
                "/Users/x/Library/Containers/com.sentinelone.sentinel-helper.safari",
            ]
        )
        applyOrphanReasons([item])
        XCTAssertEqual(item.reason, "Leftover data in 3 places.")
        XCTAssertFalse(item.reason?.contains("whose bundle id") == true, item.reason ?? "")
        XCTAssertTrue(item.summary?.contains("SentinelAgent") == true, item.summary ?? "")
        XCTAssertFalse(item.summary?.contains("com.sentinelone") == true, item.summary ?? "")
    }

    func testApplyOrphanReasonsGroupedSymlinksKeepPathCopy() {
        let item = DataItem(
            path: "/Users/x/.local/bin/mlx_lm",
            name: "mlx_lm",
            rootLabel: ".local/bin",
            kind: "symlink",
            status: "orphaned",
            extraPaths: [
                "/Users/x/.local/bin/mlx_lm.chat",
                "/Users/x/.local/bin/mlx_lm.convert",
            ]
        )
        applyOrphanReasons([item])
        XCTAssertEqual(item.reason, "Broken PATH command. \(localeCount(3)) leftover names. The tool is gone.")
        XCTAssertTrue(item.summary?.contains("2 more") == true, item.summary ?? "")
    }

    func testBrokenUserBinSymlinkIsOrphanedLeftover() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("broken-bin-\(UUID().uuidString)")
        let bin = td.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let missing = td.appendingPathComponent("gone-tool")
        let ghost = bin.appendingPathComponent("mini-swe-agent")
        try FileManager.default.createSymbolicLink(atPath: ghost.path, withDestinationPath: missing.path)
        let live = bin.appendingPathComponent("herdr")
        try Data("#!/bin/sh\n".utf8).write(to: live)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: live.path)
        let okLink = bin.appendingPathComponent("herdr-link")
        try FileManager.default.createSymbolicLink(atPath: okLink.path, withDestinationPath: live.path)
        let hits = listBrokenUserBinLinks(dirs: [bin.path])
        XCTAssertEqual(hits.map(\.name), ["mini-swe-agent"])
        XCTAssertEqual(hits[0].status, "orphaned")
        XCTAssertEqual(hits[0].kind, "symlink")
        XCTAssertEqual(hits[0].rootLabel, "bin")
        XCTAssertEqual(hits[0].path, ghost.path)
        XCTAssertTrue(hits[0].extraPaths.isEmpty)
    }

    func testBrokenUsrLocalBinLinkUsesUsrLocalRootLabel() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("usr-local-\(UUID().uuidString)")
        let bin = td.appendingPathComponent("usr").appendingPathComponent("local").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("quarto").path,
            withDestinationPath: "/Applications/quarto/bin/quarto"
        )
        let hits = listBrokenUserBinLinks(dirs: [bin.path])
        XCTAssertEqual(hits.map(\.name), ["quarto"])
        XCTAssertEqual(hits[0].rootLabel, "/usr/local/bin")
    }

    func testLinuxLeftoverSummaryUsesXdgCopyNotDarwin() {
        let config = leftoverSummary(rootLabel: ".config", kind: "dir", name: "herald")
        XCTAssertTrue(config.contains("herald"), config)
        XCTAssertTrue(config.contains(".config"), config)
        XCTAssertTrue(config.contains("no longer installed"), config)
        XCTAssertFalse(config.contains("Application Support"), config)
        XCTAssertEqual(
            leftoverSummary(rootLabel: ".cache", kind: "dir", name: "herald"),
            "herald is no longer installed. Leftover Cache folder."
        )
        let flatpak = leftoverSummary(rootLabel: ".var/app", kind: "dir", name: "org.mozilla.firefox")
        // The exact sentence, not "contains Firefox or firefox": the
        // disjunction is satisfied by the input name, so it can never fail.
        XCTAssertEqual(flatpak, "Firefox is no longer installed. Leftover Flatpak data folder.")
        XCTAssertTrue(flatpak.contains("Flatpak"), flatpak)
        XCTAssertFalse(flatpak.contains("Application Support"), flatpak)
        XCTAssertTrue(orphanReason(rootLabel: ".cache", kind: "dir").contains("Cache"), orphanReason(rootLabel: ".cache", kind: "dir"))
        XCTAssertTrue(orphanReason(rootLabel: "snap", kind: "dir").lowercased().contains("snap"))
        XCTAssertTrue(orphanReason(rootLabel: ".local/state", kind: "dir").lowercased().contains("state"))
    }

    // `Character.isNumber` is true for Arabic-Indic digits too, so a bare
    // `allSatisfy(\.isNumber)` hid a real leftover as if it were `core42`.
    func testClassifyLinuxSystemNameUsesASCIIDigitsOnly() {
        XCTAssertEqual(classifyLinuxSystemName("core42").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("core").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("gnome-shell-42").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("core\u{0669}").0, "orphaned", "core٩")
        XCTAssertEqual(classifyLinuxSystemName("gnome-shell-\u{0669}").0, "orphaned", "gnome-shell-٩")
    }

    func testUserBinRootLabelCoversLinuxbrewAndHomebrew() {
        XCTAssertEqual(userBinRootLabel("/home/linuxbrew/.linuxbrew/bin"), "linuxbrew/bin")
        XCTAssertEqual(userBinRootLabel("/opt/homebrew/bin"), "homebrew/bin")
        XCTAssertEqual(userBinRootLabel("/Users/x/.local/bin"), ".local/bin")
        XCTAssertEqual(userBinRootLabel("/home/u/bin"), "bin")
        XCTAssertEqual(userBinRootLabel("/Users/x/bin"), "bin")
        XCTAssertTrue(isUserBinLeftoverPath("/home/linuxbrew/.linuxbrew/bin/jq"))
        XCTAssertTrue(isUserBinLeftoverPath("/opt/homebrew/bin/wget"))
        XCTAssertTrue(isUserBinLeftoverPath("/home/u/bin/jq"))
        XCTAssertFalse(isUserBinLeftoverPath("/usr/bin/jq"))
        XCTAssertFalse(isUserBinLeftoverPath("/tmp/not-a-bin/jq"))
    }

    func testMatchDataItemsAttachesLinuxConfigLeftover() {
        let item = DataItem(
            path: "/home/x/.config/herald",
            name: "herald",
            rootLabel: ".config",
            kind: "dir",
            status: "owned",
            sizeBytes: 4_000
        )
        let items = [item]
        let hits = OwnedDataIndex(items).match(softwareName: "herald", bundleId: "herald").map { items[$0] }
        XCTAssertEqual(hits.map(\.path), [item.path])
        XCTAssertEqual(hits[0].sizeBytes, 4_000)
    }

    func testDefaultUserBinDirsSkipsHomebrewPrefix() {
        XCTAssertTrue(
            shouldScanUserBinDir(
                "/usr/local/bin",
                brewPrefixBin: "/opt/homebrew/bin",
                fileExists: { $0 == "/usr/local/bin" }
            )
        )
        XCTAssertFalse(
            shouldScanUserBinDir(
                "/usr/local/bin",
                brewPrefixBin: "/usr/local/bin",
                fileExists: { $0 == "/usr/local/bin" }
            )
        )
        XCTAssertFalse(shouldScanUserBinDir("/usr/local/bin", fileExists: { _ in false }))
        let dirs = defaultUserBinDirs(
            home: "/Users/x",
            usrLocalBin: "/usr/local/bin",
            fileExists: { $0 == "/usr/local/bin" },
            which: { _ in "/opt/homebrew/bin/brew" }
        )
        XCTAssertEqual(dirs, ["/Users/x/.local/bin", "/Users/x/bin", "/usr/local/bin"])
        let intel = defaultUserBinDirs(
            home: "/Users/x",
            usrLocalBin: "/usr/local/bin",
            fileExists: { $0 == "/usr/local/bin" },
            which: { _ in "/usr/local/bin/brew" }
        )
        XCTAssertEqual(intel, ["/Users/x/.local/bin", "/Users/x/bin"])
    }

    func testBrokenUserBinLinksWithSameDestDirCollapse() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("broken-group-\(UUID().uuidString)")
        let bin = td.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let destBin = td.appendingPathComponent("tools").appendingPathComponent("mlx-lm").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: destBin, withIntermediateDirectories: true)
        for name in ["mlx_lm", "mlx_lm.chat", "mlx_lm.convert"] {
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent(name).path,
                withDestinationPath: destBin.appendingPathComponent(name).path
            )
        }
        let other = bin.appendingPathComponent("adk")
        try FileManager.default.createSymbolicLink(
            atPath: other.path,
            withDestinationPath: td.appendingPathComponent("tools").appendingPathComponent("google-adk").appendingPathComponent("bin").appendingPathComponent("adk").path
        )
        let hits = Dictionary(uniqueKeysWithValues: listBrokenUserBinLinks(dirs: [bin.path]).map { ($0.name, $0) })
        XCTAssertEqual(Set(hits.keys), ["mlx_lm", "adk"])
        let mlx = try XCTUnwrap(hits["mlx_lm"])
        XCTAssertEqual(Set(mlx.extraPaths.map { URL(fileURLWithPath: $0).lastPathComponent }), ["mlx_lm.chat", "mlx_lm.convert"])
        let cmd = leftoverRemoveCommand(path: mlx.path, rootLabel: mlx.rootLabel, extraPaths: mlx.extraPaths)
        XCTAssertTrue(cmd.contains("mlx_lm.chat"), cmd)
        XCTAssertTrue(cmd.contains("mlx_lm.convert"), cmd)
        XCTAssertFalse(cmd.contains("adk"), cmd)
    }

    func testBrokenUserBinStaysOrphanedWhenRecentlyTouched() {
        let item = DataItem(
            path: "/tmp/mini-swe-agent",
            name: "mini-swe-agent",
            rootLabel: ".local/bin",
            kind: "symlink",
            status: "orphaned",
            mtime: Date()
        )
        applyRecentActivity([item])
        XCTAssertEqual(item.status, "orphaned")
    }

    func testSandboxRootsSkipNestedAndSizeProbe() {
        let container = DataItem(path: "/Users/x/Library/Containers/com.example.app", name: "com.example.app", rootLabel: "Containers", kind: "bundleid", status: "orphaned")
        let group = DataItem(path: "/Users/x/Library/Group Containers/TEAM.example", name: "TEAM.example", rootLabel: "Group Containers", kind: "group", status: "orphaned")
        let webkit = DataItem(path: "/Users/x/Library/WebKit/com.example.app", name: "com.example.app", rootLabel: "WebKit", kind: "bundleid", status: "orphaned")
        let support = DataItem(path: "/Users/x/Library/Application Support/BBEdit", name: "BBEdit", rootLabel: "Application Support", kind: "dir", status: "orphaned")
        let system = DataItem(path: "/Users/x/Library/Caches/com.apple.Safari", name: "com.apple.Safari", rootLabel: "Caches", kind: "dir", status: "system")
        XCTAssertTrue(skipNestedProbe(container))
        XCTAssertTrue(skipNestedProbe(group))
        XCTAssertTrue(skipNestedProbe(webkit))
        XCTAssertTrue(skipNestedProbe(system))
        XCTAssertFalse(skipNestedProbe(support))
    }

    func testRecentOrphanedDirIsNotReclaimable() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let recent = DataItem(path: "/tmp/HotApp", name: "HotApp", rootLabel: "Application Support", kind: "dir", status: "orphaned", activityMtime: now.addingTimeInterval(-5 * 86400))
        let stale = DataItem(path: "/tmp/ColdApp", name: "ColdApp", rootLabel: "Application Support", kind: "dir", status: "orphaned", activityMtime: now.addingTimeInterval(-Double(activeDays + 10) * 86400))
        applyRecentActivity([recent, stale], now: now)
        XCTAssertEqual(recent.status, "active")
        XCTAssertEqual(stale.status, "orphaned")
    }

    func testScanLeftoversRecentDirFollowsInjectedNow() throws {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("left-now-\(UUID().uuidString)")
        let orphan = td.appendingPathComponent("HotApp")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        try "x".write(to: orphan.appendingPathComponent("cache.dat"), atomically: true, encoding: .utf8)
        let recent = now.addingTimeInterval(-5 * 86400)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: orphan.path)
        try FileManager.default.setAttributes(
            [.modificationDate: recent],
            ofItemAtPath: orphan.appendingPathComponent("cache.dat").path
        )
        let (hot, _) = scanLeftovers(
            apps: [],
            brew: BrewSnapshot(available: false),
            roots: [("Application Support", td.path, "dir")],
            now: now
        )
        XCTAssertEqual(hot.first { $0.name == "HotApp" }?.status, "active")
        let later = now.addingTimeInterval(Double(activeDays + 10) * 86400)
        let (cold, _) = scanLeftovers(
            apps: [],
            brew: BrewSnapshot(available: false),
            roots: [("Application Support", td.path, "dir")],
            now: later
        )
        XCTAssertEqual(cold.first { $0.name == "HotApp" }?.status, "orphaned")
    }

    func testOrphanReasonAndSummary() {
        let why = orphanReason(rootLabel: "Application Support", kind: "dir")
        XCTAssertTrue(why.contains("Application Support"))
        XCTAssertTrue(why.lowercased().contains("leftover"))
        XCTAssertFalse(why.contains("Typical leftover"))
        XCTAssertFalse(why.lowercased().contains("no installed app"))
        let what = leftoverSummary(rootLabel: "Application Support", kind: "dir", name: "BetterDisplay")
        XCTAssertTrue(what.contains("BetterDisplay"), what)
        XCTAssertTrue(what.contains("Application Support"), what)
        XCTAssertTrue(what.contains("Display manager"), what)
        XCTAssertFalse(what.contains("named BetterDisplay"), what)
        XCTAssertFalse(why.contains("BetterDisplay:"))
        let plist = orphanReason(rootLabel: "Preferences", kind: "plist")
        XCTAssertTrue(plist.contains("Preference"))
        let container = orphanReason(rootLabel: "Containers", kind: "bundleid")
        XCTAssertTrue(container.lowercased().contains("sandbox"))
    }

    func testApplyOrphanReasonsOnlyFillsOrphaned() {
        let orphan = DataItem(path: "/tmp/Foo", name: "Foo", rootLabel: "Application Support", kind: "dir", status: "orphaned")
        let system = DataItem(path: "/tmp/Apple", name: "Apple", rootLabel: "Caches", kind: "dir", status: "system")
        applyOrphanReasons([orphan, system])
        // Exact text, not just non-nil: a reason that filled every field with
        // the same placeholder string would pass a nil check. Spelled out here
        // rather than built from the same two helpers, which would move both
        // sides of the comparison together.
        XCTAssertEqual(orphan.reason, "Application Support leftover.")
        XCTAssertEqual(orphan.summary, "Foo is no longer installed. Leftover Application Support folder.")
        XCTAssertNil(system.reason)
        XCTAssertNil(system.summary)
    }

    func testScanJsonIncludesLeftoverReason() throws {
        let item = DataItem(path: "/tmp/Slack", name: "Slack", rootLabel: "Application Support", kind: "dir", status: "orphaned")
        applyOrphanReasons([item])
        let result = ScanResult()
        result.dataItems = [item]
        let leftovers = try XCTUnwrap(result.toScanData().leftovers.first)
        XCTAssertEqual(leftovers.path, "/tmp/Slack")
        let reason = try XCTUnwrap(leftovers.reason)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(reason.contains("Application Support"), reason)
        let summary = try XCTUnwrap(leftovers.summary)
        XCTAssertTrue(summary.contains("Slack"), summary)
    }

    func testLinuxRootsAndSystemNames() {
        PlatformOverride.linux = true
        defer { PlatformOverride.linux = nil }
        let labels = Set(scanRootsForPlatform().map { $0.0 })
        XCTAssertTrue(labels.contains(".config"))
        XCTAssertTrue(labels.contains(".cache"))
        XCTAssertTrue(labels.contains(".local/share"))
        XCTAssertTrue(labels.contains(".local/state"))
        XCTAssertTrue(labels.contains(".local/lib"))
        XCTAssertTrue(labels.contains(".var/app"))
        XCTAssertFalse(labels.contains("Application Support"))
        XCTAssertFalse(labels.contains("HTTPStorages"))
        XCTAssertEqual(classifyLinuxSystemName("core22").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("bare").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("fontconfig").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("man").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("kdeconnect").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("kwinrc").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("plasma-workspace").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("dolphinrc").0, "system")
        XCTAssertEqual(classifyLinuxSystemName("baloofilerc").0, "system")
        for name in ["uv", "bun", "go-build", "helm", "gcloud", "btop"] {
            XCTAssertEqual(classifyLinuxSystemName(name).0, "system", name)
        }
        for name in ["pacman", "yay", "paru", "dnf", "dnf5", "yum", "zypper", "rpm"] {
            XCTAssertEqual(classifyLinuxSystemName(name).0, "system", name)
        }
        for name in ["kube", "kubebuilder-envtest"] {
            XCTAssertEqual(classifyLinuxSystemName(name).0, "system", name)
        }
        for name in [".aws", ".docker", ".ssh", ".gnupg", "aws", "docker"] {
            XCTAssertEqual(classifyLinuxSystemName(name).0, "system", name)
        }
        for name in ["quarto", "opencode", "crewai", "herald", "mcp", "huginn", "hf", "backend"] {
            XCTAssertEqual(classifyLinuxSystemName(name).0, "orphaned", name)
        }
        let names = Set(homeDataLeaves().map { URL(fileURLWithPath: $0.0).lastPathComponent })
        XCTAssertTrue(names.contains(".mozilla"))
    }

    func testMacScanRootsIncludeHTTPStorages() {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let roots = scanRootsForPlatform()
        let labels = Set(roots.map { $0.0 })
        XCTAssertTrue(labels.contains("HTTPStorages"))
        XCTAssertTrue(labels.contains("Application Support"))
        XCTAssertEqual(roots.first { $0.0 == "HTTPStorages" }?.2, "mixed")
        XCTAssertTrue(labels.contains(".cache"))
        XCTAssertTrue(labels.contains(".local/state"))
        XCTAssertTrue(labels.contains(".local/lib"))
        XCTAssertTrue(labels.contains(".config"))
        XCTAssertTrue(labels.contains(".local/share"))
        XCTAssertFalse(labels.contains(".var/app"))
        XCTAssertFalse(labels.contains("snap"))
    }

    func testXdgScanRootsHonorEnvAndDefaultLocalDirs() {
        let roots = xdgScanRoots(
            home: "/home/x",
            env: [
                "XDG_CACHE_HOME": "/tmp/mycache",
                "XDG_CONFIG_HOME": "/tmp/myconfig",
                "XDG_DATA_HOME": "/tmp/myshare",
                "XDG_STATE_HOME": "/tmp/mystate",
            ]
        )
        let byLabel = Dictionary(uniqueKeysWithValues: roots.map { ($0.0, $0.1) })
        XCTAssertEqual(byLabel[".cache"], "/tmp/mycache")
        XCTAssertEqual(byLabel[".config"], "/tmp/myconfig")
        XCTAssertEqual(byLabel[".local/share"], "/tmp/myshare")
        XCTAssertEqual(byLabel[".local/state"], "/tmp/mystate")
        XCTAssertEqual(byLabel[".local/lib"], "/home/x/.local/lib")
        let defaults = Dictionary(uniqueKeysWithValues: xdgScanRoots(home: "/home/x", env: [:]).map { ($0.0, $0.1) })
        XCTAssertEqual(defaults[".cache"], "/home/x/.cache")
        XCTAssertEqual(defaults[".config"], "/home/x/.config")
        XCTAssertEqual(defaults[".local/share"], "/home/x/.local/share")
        XCTAssertEqual(defaults[".local/state"], "/home/x/.local/state")
        let empty = Dictionary(uniqueKeysWithValues: xdgScanRoots(
            home: "/home/x",
            env: ["XDG_DATA_HOME": "", "XDG_CONFIG_HOME": "   "]
        ).map { ($0.0, $0.1) })
        XCTAssertEqual(empty[".local/share"], "/home/x/.local/share")
        XCTAssertEqual(empty[".config"], "/home/x/.config")
        XCTAssertEqual(
            leftoverSummary(rootLabel: ".local/lib", kind: "dir", name: "herald"),
            "herald is no longer installed. Leftover .local/lib data."
        )
        XCTAssertTrue(orphanReason(rootLabel: ".local/lib", kind: "dir").contains(".local/lib"))
    }

    func testNestedFileMtimeBeatsStaleParent() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: td) }
        let parent = td.appendingPathComponent("OrphanApp")
        let sub = parent.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("recent.txt"), atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-90 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: parent.path)
        let dt = probeActivityMtime(parent.path)
        XCTAssertNotNil(dt)
        XCTAssertLessThan(daysSince(dt) ?? 99, 2)
    }

    func testDoesNotDescendIntoNodeModules() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: td) }
        let parent = td.appendingPathComponent("MaybeApp")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let nm = parent.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try "x".write(to: nm.appendingPathComponent("recent.txt"), atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-90 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: parent.appendingPathComponent("node_modules").path)
        let dt = probeActivityMtime(parent.path)
        XCTAssertNotNil(dt)
        XCTAssertGreaterThan(daysSince(dt) ?? 0, Double(activeDays))
    }

    func testLaunchAgentOwnedWhenProgramBasenameStillInstalled() {
        let agent = OrphanAgent(
            path: "/Users/x/Library/LaunchAgents/com.redhat.crc.daemon.plist",
            label: "com.redhat.crc.daemon",
            program: "/Users/x/.crc/bin/crc"
        )
        let owned = dataItem(from: agent, ident: ident([], tools: ["crc"]))
        XCTAssertEqual(owned.status, "owned")
        let gone = dataItem(from: agent, ident: ident())
        XCTAssertEqual(gone.status, "orphaned")
        XCTAssertEqual(gone.rootLabel, "LaunchAgents")
    }

    func testRedHatAppDoesNotOwnCrcLaunchAgent() {
        let macinfo = AppRecord(
            path: "/Applications/Red Hat Mac Info.app",
            displayName: "Red Hat Mac Info",
            bundleId: "com.redhat.RedHatMacInfo"
        )
        let agent = OrphanAgent(
            path: "/Users/x/Library/LaunchAgents/com.redhat.crc.daemon.plist",
            label: "com.redhat.crc.daemon",
            program: "/Users/x/.crc/bin/crc"
        )
        let item = dataItem(from: agent, ident: ident([macinfo]))
        XCTAssertEqual(item.status, "orphaned")
    }

    func testOrphanLaunchAgentBecomesLeftoverItem() {
        let agent = OrphanAgent(
            path: "/Users/x/Library/LaunchAgents/com.dead.app.plist",
            label: "com.dead.app",
            program: "/Applications/Dead.app/Contents/MacOS/Dead"
        )
        let item = dataItem(from: agent)
        XCTAssertEqual(item.status, "orphaned")
        XCTAssertEqual(item.name, "com.dead.app")
        XCTAssertEqual(item.path, agent.path)
        XCTAssertEqual(item.rootLabel, "LaunchAgents")
        XCTAssertEqual(item.kind, "plist")
        applyOrphanReasons([item])
        XCTAssertTrue(item.reason?.lowercased().contains("launchagent") == true, item.reason ?? "")
        let now = Date()
        item.mtime = now
        applyRecentActivity([item], now: now)
        XCTAssertEqual(item.status, "orphaned")
        let result = ScanResult()
        result.dataItems = [item]
        let script = cleanupScript(result)
        XCTAssertTrue(script.contains("launchctl bootout"), script)
        XCTAssertTrue(script.contains("com.dead.app.plist"), script)
        XCTAssertTrue(script.contains("rm -rf"), script)
    }

    func testLeftoverRemoveCommandUnloadsLaunchAgents() {
        let agent = leftoverRemoveCommand(
            path: "/Users/x/Library/LaunchAgents/com.dead.app.plist",
            rootLabel: "LaunchAgents"
        )
        XCTAssertTrue(agent.contains("launchctl bootout"), agent)
        XCTAssertTrue(agent.contains("rm -rf"), agent)
        XCTAssertTrue(agent.contains("|| true"), agent)
        let normal = leftoverRemoveCommand(path: "/tmp/Foo", rootLabel: "Application Support")
        XCTAssertEqual(normal, "rm -rf \(shellQuote("/tmp/Foo"))")
        XCTAssertFalse(normal.contains("launchctl"))
    }

    func testLeftoverRemoveCommandSkipsPackagedPaths() {
        XCTAssertTrue(isProtectedPackagedPath("/usr/bin/python3"))
        XCTAssertTrue(isProtectedPackagedPath("/usr"))
        XCTAssertTrue(isProtectedPackagedPath("/bin/ls"))
        XCTAssertTrue(isProtectedPackagedPath("/etc/passwd"))
        XCTAssertTrue(isProtectedPackagedPath("/System/Library/CoreServices"))
        XCTAssertTrue(isProtectedPackagedPath("/Library/LaunchAgents/com.apple.foo.plist"))
        XCTAssertFalse(isProtectedPackagedPath("/home/u/.local/bin/python3"))
        XCTAssertFalse(isProtectedPackagedPath("/tmp/Foo"))
        XCTAssertFalse(isProtectedPackagedPath("/Users/x/Library/LaunchAgents/com.dead.app.plist"))
        // `rm` resolves `..`, so a path that walks out of the tree the prefix
        // test approved deletes a packaged root.
        XCTAssertTrue(isProtectedPackagedPath("/home/u/gone/../../../etc"))
        XCTAssertTrue(isProtectedPackagedPath("/tmp/gone/../.."))
        let cmd = leftoverRemoveCommand(path: "/usr/bin/python3", rootLabel: ".local/bin")
        XCTAssertFalse(cmd.contains("rm -rf"), cmd)
        XCTAssertTrue(cmd.contains("skipped"), cmd)
        let mixed = leftoverRemoveCommand(
            path: "/home/u/.local/bin/python3",
            rootLabel: ".local/bin",
            extraPaths: ["/usr/bin/python3"]
        )
        XCTAssertTrue(mixed.contains("/home/u/.local/bin/python3"), mixed)
        XCTAssertFalse(mixed.contains("/usr/bin/python3"), mixed)
        let agent = leftoverRemoveCommand(
            path: "/Library/LaunchAgents/com.apple.foo.plist",
            rootLabel: "LaunchAgents"
        )
        XCTAssertFalse(agent.contains("rm -rf"), agent)
        XCTAssertFalse(agent.contains("launchctl"), agent)
    }

    func testUninstallCommandRefusesAPathRemovalsMayNotName() {
        // `leftoverRemoveCommand` required both the packaged-root deny and
        // `isRemovableLeftoverPath`. `uninstallCommand` checked only the first,
        // so its two `rm -rf` branches emitted whatever the packaged-root test
        // let through. The path is the `Exec=` token of a `.desktop` record, and
        // `shellQuote` leaves a leading `-` unquoted, so `rm` read it as an
        // option instead of as a path.
        for path in ["-rf", "--no-preserve-root", "-v", "Foo.AppImage", "./Foo.AppImage"] {
            for source in ["appimage", "pkg/other"] {
                let cmd = uninstallCommand(
                    source: source,
                    name: "Foo",
                    path: path,
                    caskName: nil,
                    steamAppId: nil
                )
                XCTAssertFalse(cmd.contains("rm -rf"), "\(source) \(path): \(cmd)")
                XCTAssertTrue(cmd.hasPrefix("#"), "\(source) \(path): \(cmd)")
            }
        }
        // The absolute spelling still removes, so the new guard is not a
        // blanket refusal.
        XCTAssertEqual(
            uninstallCommand(
                source: "appimage",
                name: "Foo",
                path: "/home/u/Apps/Foo.AppImage",
                caskName: nil,
                steamAppId: nil
            ),
            "rm -rf /home/u/Apps/Foo.AppImage"
        )
        XCTAssertEqual(
            uninstallCommand(
                source: "pkg/other",
                name: "Firefox",
                path: "/home/u/Apps/Firefox",
                caskName: nil,
                steamAppId: nil
            ),
            "rm -rf /home/u/Apps/Firefox"
        )
    }

    func testScriptCommentsCannotInjectASecondLine() {
        // A newline ends a `#` comment, so an app or folder carrying one used to
        // append a command to the script the UI runs after a single preview.
        XCTAssertEqual(shellComment("Plain Name"), "Plain Name")
        XCTAssertEqual(shellComment("Game\nrm -rf ~"), "Game rm -rf ~")
        XCTAssertEqual(shellComment("Game\r\nrm -rf ~"), "Game rm -rf ~")
        XCTAssertEqual(shellComment("Game\rrm -rf ~"), "Game rm -rf ~")
        XCTAssertEqual(shellComment("A\u{2028}rm -rf ~"), "A rm -rf ~")
        XCTAssertEqual(shellComment("\nrm -rf ~"), "rm -rf ~")
        // `--dry-run` prints the script, and the terminal executes what it
        // reads, so an escape sequence in a name retitles the window or
        // clears the rows being approved.
        XCTAssertEqual(shellComment("x\u{1B}]0;pwned\u{07}"), "x\u{FFFD}]0;pwned\u{FFFD}")
        XCTAssertEqual(shellComment("x\u{1B}[2J"), "x\u{FFFD}[2J")
        XCTAssertEqual(shellComment("x\u{9B}0"), "x\u{FFFD}0")

        let steam = uninstallCommand(
            source: "steam",
            name: "Game\nrm -rf ~",
            path: "/home/u/.steam/steam/steamapps/common/Game",
            caskName: nil,
            steamAppId: nil
        )
        for line in steam.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("#"), "injected line: \(line)")
        }

        // A quoted name is already safe: the newline stays inside the single
        // quotes, so the command stays one shell word sequence. The name is
        // quoted whole, so that word is `'ok<newline>rm -rf ~'` and not two
        // quoted lines: two words would ask brew for a formula named `rm -rf ~`,
        // and a name whose quote closed before the newline is the injection
        // this test exists for.
        let brew = uninstallCommand(
            source: "brew-formula",
            name: "ok\nrm -rf ~",
            path: "/opt/homebrew/Cellar/ok",
            caskName: nil,
            steamAppId: nil
        )
        XCTAssertTrue(brew.hasPrefix("if brew list --formula '"), brew)
        XCTAssertTrue(brew.contains("'ok\nrm -rf ~'"), brew)

        let ppa = packageRemoveCommand(PackageEntry(
            name: "vendor",
            manager: "apt\nrm -rf ~",
            kind: "ppa"
        ))
        for line in ppa.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("#"), "injected line: \(line)")
        }
    }

    /// The names `leftoverAppBlurb` tries against the blurb tables, in the
    /// order it tries them. A duplicate or a skipped label is wasted work and
    /// a wrong first entry is the wrong blurb on the row, so both are pinned
    /// here rather than only through the three blurb cases above.
    func testLeftoverLookupTokensAreFoldedDedupedAndSkipped() {
        let tokens = leftoverLookupTokens(name: "com.example.Foo")
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(tokens.first, "foo", "the display name is looked up first")
        XCTAssertEqual(Set(tokens).count, tokens.count, "duplicates in \(tokens)")
        for token in tokens {
            XCTAssertEqual(token, token.lowercased(), token)
            XCTAssertGreaterThanOrEqual(token.count, 2, token)
            XCTAssertFalse(leftoverLookupSkip.contains(token), token)
        }
        // "com" is in the skip set; a generic DNS label must never reach a
        // lookup table where it would match the first entry indexed under it.
        XCTAssertFalse(tokens.contains("com"), "\(tokens)")
    }

    /// A display name with a space also goes out in its dashed spelling, the
    /// form Homebrew uses for taps and casks.
    func testLeftoverLookupTokensAddTheDashedSpelling() {
        let tokens = leftoverLookupTokens(name: "Better Display")
        XCTAssertTrue(tokens.contains("better display"), "\(tokens)")
        XCTAssertTrue(tokens.contains("better-display"), "\(tokens)")
    }

    /// The same list, whatever the input folds to, so the report and the
    /// lookup agree on a row's identity.
    func testLeftoverLookupTokensAreStableAcrossCaseAndSuffix() {
        let plain = leftoverLookupTokens(name: "Foo")
        let suffixed = leftoverLookupTokens(name: "Foo.savedstate")
        XCTAssertEqual(plain, suffixed)
        XCTAssertEqual(plain, leftoverLookupTokens(name: "FOO"))
    }

    func testPpaSourcesPathRejectsParentTraversal() {
        XCTAssertTrue(isPpaSourcesPath("/etc/apt/sources.list.d/vendor.list"))
        XCTAssertFalse(isPpaSourcesPath("/etc/apt/sources.list.d/../../root"))
        XCTAssertFalse(isPpaSourcesPath("/etc/apt/sources.list.d"))
        XCTAssertFalse(isPpaSourcesPath("/tmp/vendor.list"))
        // Standardizing resolves the `..`, so the old check tested the cleaned
        // spelling and this one came back permitted.
        XCTAssertFalse(isPpaSourcesPath("/etc/apt/sources.list.d/../sources.list.d/vendor.list"))
        XCTAssertFalse(isPpaSourcesPath("/etc/apt/sources.list.d/x/../../sources.list.d/vendor.list"))
        let cmd = leftoverRemoveCommand(
            path: "/home/u/.local/bin/thing",
            rootLabel: ".local/bin",
            extraPaths: ["/etc/apt/sources.list.d/../../root"]
        )
        XCTAssertTrue(cmd.contains("/home/u/.local/bin/thing"), cmd)
        XCTAssertFalse(cmd.contains("sources.list.d"), cmd)
    }

    func testScanLaunchAgentsFindsMissingProgram() throws {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.dead.app</string>
            <key>Program</key>
            <string>/Applications/DeadMissing.app/Contents/MacOS/Dead</string>
        </dict>
        </plist>
        """
        try plist.write(to: td.appendingPathComponent("com.dead.app.plist"), atomically: true, encoding: .utf8)
        let keep = td.appendingPathComponent("com.alive.sh.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.alive.sh</string>
            <key>Program</key>
            <string>/bin/sh</string>
        </dict>
        </plist>
        """.write(to: keep, atomically: true, encoding: .utf8)
        let found = scanLaunchAgents(roots: [td.path])
        XCTAssertEqual(found.map(\.label), ["com.dead.app"])
        XCTAssertTrue(found[0].path.hasSuffix("com.dead.app.plist"))
    }

    func testScanLaunchAgentsSkippedOnLinux() throws {
        PlatformOverride.linux = true
        defer { PlatformOverride.linux = nil }
        // A root holding a plist the sibling test finds on Darwin. Passing a
        // real directory such as `/tmp` made the assertion a statement about
        // whatever that machine had in it: with the short-circuit moved, the
        // walk still found nothing and the test stayed green.
        let td = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-linux-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: td) }
        try FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.dead.app</string>
            <key>Program</key>
            <string>/Applications/DeadMissing.app/Contents/MacOS/Dead</string>
        </dict>
        </plist>
        """.write(to: td.appendingPathComponent("com.dead.app.plist"), atomically: true, encoding: .utf8)
        XCTAssertTrue(scanLaunchAgents(roots: [td.path]).isEmpty)
    }
}
