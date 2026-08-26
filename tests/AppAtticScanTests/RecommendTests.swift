import XCTest
@testable import AppAtticScan

final class RecommendTests: XCTestCase {
    func testUnknownUsageShortHistoryIsKeep() {
        let sw = Software(name: "jq", kind: "formula", path: "/opt/homebrew/bin/jq", source: "brew-formula", isLeaf: true, bins: ["jq"], historySpanDays: 3)
        let v = evaluate(sw)
        XCTAssertEqual(v.tier, "keep")
        XCTAssertTrue(v.reason.contains("not enough history"), v.reason)
    }

    func testLibraryFormulaUnknownUsageIsKeep() {
        let sw = Software(name: "sdl3_ttf", kind: "formula", path: "/opt/homebrew/opt/sdl3_ttf", source: "brew-formula", isLeaf: true, bins: [], historySpanDays: 400)
        XCTAssertEqual(evaluate(sw).tier, "keep")
    }

    func testStaleVerdictsDropsKeep() {
        let jq = Software(name: "jq", kind: "formula", path: "/opt/homebrew/bin/jq", source: "brew-formula")
        let sketch = Software(name: "Sketch", kind: "app", path: "/Applications/Sketch.app", source: "pkg/other")
        let unarchiver = Software(name: "The Unarchiver", kind: "app", path: "/Applications/The Unarchiver.app", source: "brew-cask")
        let safari = Software(name: "Safari", kind: "app", path: "/System/Applications/Safari.app", source: "system")
        let verdicts = [
            Verdict(software: jq, tier: "keep", reason: "in use"),
            Verdict(software: sketch, tier: "review", reason: "idle"),
            Verdict(software: unarchiver, tier: "remove", reason: "stale"),
            Verdict(software: safari, tier: "system", reason: "OS"),
        ]
        XCTAssertEqual(staleVerdicts(verdicts).map(\.tier), ["review", "remove"])
        XCTAssertEqual(staleVerdicts(verdicts, includeSystem: true).map(\.tier), ["review", "remove", "system"])
    }

    func testNeverSeenInLongHistoryIsRemove() {
        let sw = Software(name: "jq", kind: "formula", path: "/opt/homebrew/bin/jq", source: "brew-formula", isLeaf: true, bins: ["jq"], historySpanDays: 400)
        XCTAssertEqual(evaluate(sw).tier, "remove")
    }

    func testCopiedAppWithNoUsageIsTooNewToJudge() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "Windows App",
            kind: "app",
            path: "/Applications/Windows App.app",
            source: "pkg/other",
            installedAt: now.addingTimeInterval(-4 * 86400)
        )
        let v = evaluate(sw, now: now)
        XCTAssertEqual(v.tier, "keep")
        XCTAssertTrue(v.reason.contains("too new"), v.reason)
    }

    func testGuiAppUnknownUsageIsReviewNotRemove() {
        let sw = Software(name: "Sketch", kind: "app", path: "/Applications/Sketch.app", source: "pkg/other")
        XCTAssertEqual(evaluate(sw).tier, "review")
    }

    func testRecentDataMtimeKeepsAppWithNoSpotlight() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(name: "iTerm", kind: "app", path: "/Applications/iTerm.app", source: "pkg/other", dataMtime: now.addingTimeInterval(-5 * 86400))
        XCTAssertEqual(evaluate(sw, now: now).tier, "keep")
    }

    func testRecentDataMtimeOverridesStaleSpotlight() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "Safari",
            kind: "app",
            path: "/Applications/Safari.app",
            source: "pkg/other",
            lastUsed: now.addingTimeInterval(-200 * 86400),
            dataMtime: now.addingTimeInterval(-3 * 86400)
        )
        XCTAssertEqual(evaluate(sw, now: now).tier, "keep")
        XCTAssertLessThanOrEqual(3, activeDays)
    }

    func testOldDataMtimeIsReviewNotRemove() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "Sketch",
            kind: "app",
            path: "/Applications/Sketch.app",
            source: "brew-cask",
            dataMtime: now.addingTimeInterval(-200 * 86400),
            caskName: "sketch"
        )
        let v = evaluate(sw, now: now)
        XCTAssertEqual(v.tier, "review")
        XCTAssertTrue(v.reason.contains("Data directory written"), v.reason)
    }

    func testDataMtimeWithinStaleWindowIsReviewNotRemove() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "Sketch",
            kind: "app",
            path: "/Applications/Sketch.app",
            source: "brew-cask",
            lastUsed: now.addingTimeInterval(-400 * 86400),
            dataMtime: now.addingTimeInterval(-90 * 86400),
            caskName: "sketch"
        )
        XCTAssertEqual(evaluate(sw, now: now).tier, "review")
        XCTAssertLessThan(90, staleDays)
    }

    func testBrewCaskUnknownUsageIsReviewNotRemove() {
        let sw = Software(name: "Sketch", kind: "app", path: "/Applications/Sketch.app", source: "brew-cask", caskName: "sketch", historySpanDays: 400)
        XCTAssertEqual(evaluate(sw).tier, "review")
    }

    func testBrewCaskPkgDirIsTaggedCask() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = td.appendingPathComponent("quarto")
        try FileManager.default.createDirectory(at: path.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let brew = BrewSnapshot(available: true, casks: [Cask(name: "quarto")])
        let software = buildSoftware(
            apps: [],
            brew: brew,
            dataItems: [],
            history: HistoryIndex(),
            includeDarwinNonApp: true,
            nonAppPaths: [path.path],
            du: { _ in (12, true) }
        )
        let hits = software.filter { $0.name == "quarto" }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].source, "brew-cask")
        XCTAssertEqual(hits[0].caskName, "quarto")
        try? FileManager.default.removeItem(at: td)
    }

    func testFormulaDirInApplicationsIsNotDuplicated() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = td.appendingPathComponent("wget")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let brew = BrewSnapshot(available: true, formulas: [Formula(name: "wget")])
        let software = buildSoftware(
            apps: [],
            brew: brew,
            dataItems: [],
            history: HistoryIndex(),
            includeDarwinNonApp: true,
            nonAppPaths: [path.path],
            du: { _ in (12, true) }
        )
        XCTAssertTrue(software.filter { $0.source == "pkg/other" }.isEmpty)
        XCTAssertEqual(software.filter { $0.kind == "formula" }.map(\.name), ["wget"])
        try? FileManager.default.removeItem(at: td)
    }

    func testFormulaCopiesBrewDesc() {
        let brew = BrewSnapshot(
            available: true,
            prefix: "/opt/homebrew",
            formulas: [Formula(name: "wget", isLeaf: true, desc: "Internet file retriever")]
        )
        let software = buildSoftware(apps: [], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        XCTAssertEqual(software.first { $0.name == "wget" }?.summary, "Internet file retriever")
    }

    func testCaskAppCopiesBrewDesc() {
        let app = AppRecord(path: "/Applications/Sketch.app", displayName: "Sketch", bundleId: "com.bohemiancoding.sketch3")
        let brew = BrewSnapshot(available: true, casks: [Cask(name: "sketch", appPaths: ["/Applications/Sketch.app"], desc: "Digital design app")])
        let software = buildSoftware(apps: [app], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        XCTAssertEqual(software.first { $0.name == "Sketch" }?.summary, "Digital design app")
    }

    func testBrewCaskWithoutAppStillListed() {
        let brew = BrewSnapshot(
            available: true,
            prefix: "/tmp/appattic-brew-prefix",
            casks: [Cask(name: "bbedit", desc: "Text editor", titles: ["BBEdit"], appNames: ["BBEdit.app"])]
        )
        let software = buildSoftware(apps: [], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        let hits = software.filter { $0.source == "brew-cask" }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].caskName, "bbedit")
        XCTAssertEqual(hits[0].name, "BBEdit")
        XCTAssertEqual(hits[0].kind, "app")
        XCTAssertEqual(hits[0].summary, "Text editor")
        XCTAssertTrue(hits[0].path.contains("Caskroom/bbedit"), hits[0].path)
        XCTAssertEqual(evaluate(hits[0]).tier, "review")
    }

    func testNonAppCaskUnknownUsageIsKeep() {
        let brew = BrewSnapshot(
            available: true,
            prefix: "/tmp/appattic-brew-prefix",
            casks: [Cask(name: "font-inter", desc: "Inter font family", titles: ["Inter"])]
        )
        let software = buildSoftware(apps: [], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        let hits = software.filter { $0.caskName == "font-inter" }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].kind, "other")
        XCTAssertEqual(evaluate(hits[0]).tier, "keep")
    }

    func testMatchedCaskIsNotListedTwice() {
        let app = AppRecord(path: "/Applications/BBEdit.app", displayName: "BBEdit", bundleId: "com.barebones.bbedit")
        let brew = BrewSnapshot(
            available: true,
            prefix: "/tmp/appattic-brew-prefix",
            casks: [Cask(name: "bbedit", appPaths: ["/Applications/BBEdit.app"], titles: ["BBEdit"])]
        )
        let software = buildSoftware(apps: [app], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        XCTAssertEqual(software.filter { $0.caskName == "bbedit" }.count, 1)
        XCTAssertEqual(software.first { $0.caskName == "bbedit" }?.path, "/Applications/BBEdit.app")
    }

    func testPkgCaskDescJoinsByPrettyName() {
        let app = AppRecord(path: "/Applications/ZeroTier.app", displayName: "ZeroTier", bundleId: "com.zerotier.ZeroTier-One")
        let brew = BrewSnapshot(available: true, casks: [Cask(name: "zerotier-one", desc: "Mesh VPN client", titles: ["ZeroTier One"])])
        let software = buildSoftware(apps: [app], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        let zt = software.first { $0.name == "ZeroTier" }!
        XCTAssertEqual(zt.summary, "Mesh VPN client")
        XCTAssertEqual(zt.caskName, "zerotier-one")
        XCTAssertEqual(zt.source, "brew-cask")
    }

    func testCaskDescJoinsByArtifactBasename() {
        let app = AppRecord(path: "/Applications/Notepadnext.app", displayName: "Notepad Next", bundleId: "com.notepadnext.app")
        let brew = BrewSnapshot(available: true, casks: [Cask(name: "notepadnext", desc: "Notepad++-style editor", appNames: ["Notepadnext.app"])])
        let software = buildSoftware(apps: [app], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        let row = software.first { $0.name == "Notepad Next" }!
        XCTAssertEqual(row.summary, "Notepad++-style editor")
        XCTAssertEqual(row.caskName, "notepadnext")
    }

    func testBrewDescWinsOverJunkPlistComment() {
        let app = AppRecord(
            path: "/Applications/Syncthing.app",
            displayName: "Syncthing",
            bundleId: "com.github.xor-gate.syncthing-macosx",
            extra: ["comment": "syncthing project Group", "category": "Utilities"]
        )
        let brew = BrewSnapshot(available: true, casks: [Cask(name: "syncthing-app", appPaths: ["/Applications/Syncthing.app"], desc: "Real time file synchronisation software")])
        let software = buildSoftware(apps: [app], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        XCTAssertEqual(software[0].summary, "Real time file synchronisation software")
    }

    func testLinuxPackageSourcesFromDesktopExtras() {
        let flatpak = AppRecord(
            path: "/home/u/.local/share/flatpak/exports/share/applications/org.mozilla.Firefox.desktop",
            displayName: "Firefox",
            bundleId: "org.mozilla.firefox",
            sourceDir: "/home/u/.local/share/flatpak/exports/share/applications",
            extra: ["linux_source": "flatpak", "pkg_id": "org.mozilla.Firefox", "desktop_id": "org.mozilla.Firefox", "comment": "Browse the Web"]
        )
        let snap = AppRecord(
            path: "/var/lib/snapd/desktop/applications/code_code.desktop",
            displayName: "Code",
            bundleId: "code",
            sourceDir: "/var/lib/snapd/desktop/applications",
            extra: ["linux_source": "snap", "pkg_id": "code", "desktop_id": "code_code"]
        )
        let image = AppRecord(
            path: "/home/u/Apps/Foo.AppImage",
            displayName: "Foo",
            sourceDir: "/home/u/.local/share/applications",
            extra: ["linux_source": "appimage", "pkg_id": "foo"]
        )
        let brew = BrewSnapshot(available: false)
        XCTAssertEqual(
            buildSoftware(apps: [flatpak], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)[0].source,
            "flatpak"
        )
        XCTAssertEqual(
            buildSoftware(apps: [snap], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)[0].source,
            "snap"
        )
        XCTAssertEqual(
            buildSoftware(apps: [image], brew: brew, dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)[0].source,
            "appimage"
        )
    }

    func testLongIdleFlatpakIsRemove() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "Firefox",
            kind: "app",
            path: "/home/u/.local/share/flatpak/exports/share/applications/org.mozilla.Firefox.desktop",
            source: "flatpak",
            lastUsed: now.addingTimeInterval(-200 * 86400),
            pkgId: "org.mozilla.Firefox"
        )
        let v = evaluate(sw, now: now)
        XCTAssertEqual(v.tier, "remove")
        XCTAssertEqual(v.reason, "Not used for 6mo. Easy to reinstall with Flatpak.")
    }

    func testDesktopCommentBecomesSummary() {
        let app = AppRecord(path: "/usr/bin/firefox", displayName: "Firefox Web Browser", bundleId: "firefox", extra: ["comment": "Browse the Web"])
        let software = buildSoftware(apps: [app], brew: BrewSnapshot(available: false), dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        XCTAssertEqual(software[0].summary, "Browse the Web")
    }

    func testAppCategoryBecomesSummaryWhenNoComment() {
        let app = AppRecord(path: "/Applications/iTerm.app", displayName: "iTerm2", bundleId: "com.googlecode.iterm2", extra: ["category": "Productivity app"])
        let software = buildSoftware(apps: [app], brew: BrewSnapshot(available: false), dataItems: [], history: HistoryIndex(), includeDarwinNonApp: false)
        XCTAssertEqual(software[0].summary, "Productivity app")
    }

    func testScanJSONIncludesSoftwareSummary() {
        let sw = Software(name: "wget", kind: "formula", path: "/opt/homebrew/bin/wget", source: "brew-formula", summary: "Internet file retriever")
        let result = ScanResult()
        result.software = [sw]
        XCTAssertEqual(result.toScanData().software[0].summary, "Internet file retriever")
    }

    func testScanJSONFillsSoftwareSummaryFallback() {
        let sw = Software(name: "Sketch", kind: "app", path: "/Applications/Sketch.app", source: "pkg/other")
        let result = ScanResult()
        result.software = [sw]
        XCTAssertEqual(result.toScanData().software[0].summary, "Installed application")
    }

    func testDisplayStaleReasonShortensBrewAndManualCopy() {
        XCTAssertEqual(
            displayStaleReason("Not used for 6mo; brew package is trivial to reinstall if needed"),
            "Not used for 6mo. Easy to reinstall with brew."
        )
        XCTAssertEqual(
            displayStaleReason("Not used for 6mo; manual reinstall would be required: keep if it has value"),
            "Not used for 6mo. Manual reinstall if you still want it."
        )
        XCTAssertEqual(displayStaleReason("Data directory written 6mo ago"), "Data directory written 6mo ago")
        XCTAssertEqual(
            displayStaleReason("Not used for 6mo. Easy to reinstall with brew."),
            "Not used for 6mo. Easy to reinstall with brew."
        )
    }

    func testLongIdleBrewCaskWhyIsShort() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "The Unarchiver",
            kind: "app",
            path: "/Applications/The Unarchiver.app",
            source: "brew-cask",
            lastUsed: now.addingTimeInterval(-200 * 86400),
            caskName: "the-unarchiver"
        )
        let v = evaluate(sw, now: now)
        XCTAssertEqual(v.tier, "remove")
        XCTAssertEqual(v.reason, "Not used for 6mo. Easy to reinstall with brew.")
    }

    func testLongIdleManualAppWhyIsShort() {
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        let sw = Software(
            name: "LimeChat",
            kind: "app",
            path: "/Applications/LimeChat.app",
            source: "pkg/other",
            lastUsed: now.addingTimeInterval(-200 * 86400)
        )
        let v = evaluate(sw, now: now)
        XCTAssertEqual(v.tier, "review")
        XCTAssertEqual(v.reason, "Not used for 6mo. Manual reinstall if you still want it.")
    }

    func testMatchDataItemsAttachesOwnedLeftoverByDisplayName() {
        let support = DataItem(
            path: "/tmp/Library/Application Support/Sketch",
            name: "Sketch",
            rootLabel: "Application Support",
            kind: "dir",
            status: "owned",
            sizeBytes: 40_000_000
        )
        let cache = DataItem(
            path: "/tmp/Library/Caches/com.bohemiancoding.sketch3",
            name: "com.bohemiancoding.sketch3",
            rootLabel: "Caches",
            kind: "dir",
            status: "owned",
            sizeBytes: 5_000_000
        )
        let orphan = DataItem(
            path: "/tmp/Library/Application Support/GoneApp",
            name: "GoneApp",
            rootLabel: "Application Support",
            kind: "dir",
            status: "orphaned",
            sizeBytes: 9_000_000
        )
        let other = DataItem(
            path: "/tmp/Library/Application Support/Slack",
            name: "Slack",
            rootLabel: "Application Support",
            kind: "dir",
            status: "owned",
            sizeBytes: 80_000_000
        )
        let hits = matchDataItems(
            softwareName: "Sketch",
            bundleId: "com.bohemiancoding.sketch3",
            items: [support, cache, orphan, other]
        )
        XCTAssertEqual(Set(hits.map(\.path)), Set([support.path, cache.path]))
        XCTAssertEqual(hits.reduce(0) { $0 + $1.sizeBytes }, 45_000_000)
    }

    func testBuildSoftwareAttachesOwnedDataWithoutOwnerField() {
        let app = AppRecord(
            path: "/Applications/Sketch.app",
            displayName: "Sketch",
            bundleId: "com.bohemiancoding.sketch3"
        )
        let support = DataItem(
            path: "/tmp/Library/Application Support/Sketch",
            name: "Sketch",
            rootLabel: "Application Support",
            kind: "dir",
            status: "owned",
            sizeBytes: 12_000_000
        )
        let software = buildSoftware(
            apps: [app],
            brew: BrewSnapshot(available: false),
            dataItems: [support],
            history: HistoryIndex(),
            includeDarwinNonApp: false
        )
        let sketch = software.first { $0.name == "Sketch" }!
        XCTAssertEqual(sketch.dataBytes, 12_000_000)
        XCTAssertEqual(sketch.dataPaths, [support.path])
    }

    func testStaleSizeTextAlwaysIncludesData() {
        XCTAssertEqual(staleSizeText(sizeBytes: 10_000_000, sizeMeasured: true, dataBytes: 0), humanSize(10_000_000))
        XCTAssertEqual(
            staleSizeText(sizeBytes: 10_000_000, sizeMeasured: true, dataBytes: 50_000),
            "\(humanSize(10_000_000)) + \(humanSize(50_000))"
        )
        XCTAssertEqual(
            staleSizeText(sizeBytes: 0, sizeMeasured: false, dataBytes: 4_000_000),
            "n/a + \(humanSize(4_000_000))"
        )
    }

    func testStaleReclaimableBytesSumsAppAndOwnedData() {
        let items = [
            SoftwareItem(name: "A", kind: "app", path: "/A.app", source: "pkg/other", size_bytes: 100, data_bytes: 20, tier: "remove"),
            SoftwareItem(name: "B", kind: "app", path: "/B.app", source: "pkg/other", size_bytes: 50, data_bytes: 5, tier: "review"),
            SoftwareItem(name: "C", kind: "app", path: "/C.app", source: "pkg/other", size_bytes: 999, data_bytes: 999, tier: "keep"),
            SoftwareItem(name: "D", kind: "app", path: "/D.app", source: "system", size_bytes: 80, data_bytes: 10, tier: "system"),
        ]
        XCTAssertEqual(staleReclaimableBytes(items), 175)
        XCTAssertEqual(overviewStaleTotalLabel(count: 2, bytes: 175), "2 · \(humanSize(175))")
        XCTAssertEqual(overviewStaleTotalLabel(count: 2, bytes: 0), "2")
    }

    func testScanJSONKeepsSoftwareDataPaths() {
        let sw = Software(
            name: "Sketch",
            kind: "app",
            path: "/Applications/Sketch.app",
            source: "pkg/other",
            dataBytes: 12,
            dataPaths: ["/tmp/Library/Application Support/Sketch"]
        )
        let result = ScanResult()
        result.software = [sw]
        let row = result.toScanData().software[0]
        XCTAssertEqual(row.data_bytes, 12)
        XCTAssertEqual(row.data_paths, ["/tmp/Library/Application Support/Sketch"])
    }
}
