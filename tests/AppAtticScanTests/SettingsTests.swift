import XCTest
@testable import AppAtticScan

final class SettingsTests: XCTestCase {
    func testMissingSettingsFileReturnsDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-missing-\(UUID().uuidString).json")
        let settings = try loadSettings(from: url)
        XCTAssertFalse(settings.includeSystem)
        XCTAssertTrue(settings.confirmDelete)
        XCTAssertEqual(settings.ignoredLeftoverPaths, [])
    }

    func testSettingsURLSitsBesideScanCache() {
        // The directory is spelled out rather than read back from
        // defaultScanCacheURL() or xdgDataHome(), which would agree with any
        // value they return: the XDG rule is restated here, so a base that
        // moved away from `$XDG_DATA_HOME` or `~/.local/share` fails.
        let expectedDirectory: String
        if PlatformOverride.isLinux {
            let env = ProcessInfo.processInfo.environment
            let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = (xdg?.hasPrefix("/") ?? false)
                ? xdg!
                : (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                    .appendingPathComponent(".local/share")
            expectedDirectory = (base as NSString).appendingPathComponent("appattic")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support")
            expectedDirectory = support.appendingPathComponent("AppAttic", isDirectory: true).path
        }
        XCTAssertEqual(defaultSettingsURL().lastPathComponent, "settings.json")
        XCTAssertEqual(defaultScanCacheURL().lastPathComponent, "last-scan.json")
        XCTAssertEqual(defaultSettingsURL().deletingLastPathComponent().path, expectedDirectory)
        XCTAssertEqual(defaultScanCacheURL().deletingLastPathComponent().path, expectedDirectory)
    }

    func testSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = AppAtticSettings.default
        settings.includeSystem = true
        settings.confirmDelete = false
        settings.ignoredLeftoverPaths = ["/tmp/Foo", "/tmp/Bar"]
        try saveSettings(settings, to: url)
        let loaded = try loadSettings(from: url)
        XCTAssertTrue(loaded.includeSystem)
        XCTAssertFalse(loaded.confirmDelete)
        XCTAssertEqual(loaded.ignoredLeftoverPaths, ["/tmp/Foo", "/tmp/Bar"])
        let text = try String(contentsOf: url, encoding: .utf8)
        // Structured, not a substring probe: the on-disk JSON carries the same
        // values, its keys are sorted, and paths are not escaped, so the file
        // stays readable and hand-editable.
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["includeSystem"] as? Bool, true, text)
        XCTAssertEqual(object["confirmDelete"] as? Bool, false, text)
        XCTAssertEqual(object["ignoredLeftoverPaths"] as? [String], ["/tmp/Foo", "/tmp/Bar"], text)
        // `.sortedKeys` means the top-level keys come out in order. Their
        // indent is derived rather than assumed, so the check does not depend
        // on the encoder's indent width; array items carry no " : " and are
        // left out, and top-level keys are the least-indented ones that have one.
        let keyLines = text.split(separator: "\n").filter { $0.contains(" : ") }
        let indent = keyLines.map { $0.prefix(while: { $0 == " " }).count }.min() ?? -1
        let keyOrder = keyLines.compactMap { line -> String? in
            guard line.prefix(while: { $0 == " " }).count == indent else { return nil }
            let trimmed = line.dropFirst(indent)
            guard let end = trimmed.firstIndex(of: "\"") else { return nil }
            return String(trimmed[..<end])
        }
        XCTAssertFalse(keyOrder.isEmpty, "no top-level key found, so the order check is vacuous")
        XCTAssertEqual(keyOrder, keyOrder.sorted(), text)
        XCTAssertFalse(text.contains("\\/"), text)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertNotEqual(mode, -1)
        XCTAssertEqual(mode & 0o077, 0)
    }

    func testPartialSettingsJSONUsesDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-partial-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"includeSystem\":true}".utf8).write(to: url)
        let loaded = try loadSettings(from: url)
        XCTAssertTrue(loaded.includeSystem)
        XCTAssertTrue(loaded.confirmDelete)
        XCTAssertEqual(loaded.ignoredLeftoverPaths, [])
    }

    func testSettingsErrorUserMessageIsWrittenForPeople() {
        let path = "/tmp/appattic-settings.json"
        let unread = settingsErrorUserMessage(SettingsError.unreadable(path: path, reason: "permission denied"))
        XCTAssertTrue(unread.contains("Could not read settings"), unread)
        XCTAssertTrue(unread.contains(path), unread)
        XCTAssertFalse(unread.hasPrefix("cannot read settings"), unread)
        let invalid = settingsErrorUserMessage(SettingsError.invalid(path: path, reason: "not valid JSON"))
        XCTAssertTrue(invalid.contains("not valid JSON"), invalid)
        XCTAssertTrue(invalid.contains("will not overwrite"), invalid)
        XCTAssertFalse(invalid.hasPrefix("invalid settings"), invalid)
        let unwritable = settingsErrorUserMessage(SettingsError.unwritable(path: path, reason: "disk full"))
        XCTAssertTrue(unwritable.contains("Could not save settings"), unwritable)
        XCTAssertFalse(unwritable.hasPrefix("cannot write settings"), unwritable)
        XCTAssertEqual(SettingsError.invalid(path: path, reason: "not valid JSON").description, "invalid settings \(path): not valid JSON")
    }

    func testMalformedSettingsJSONThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try loadSettings(from: url)) { error in
            guard case SettingsError.invalid(let path, let reason) = error else {
                return XCTFail("expected invalid, got \(error)")
            }
            XCTAssertEqual(path, url.path)
            XCTAssertEqual(reason, "not valid JSON")
        }
    }

    func testEmptySettingsFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        XCTAssertThrowsError(try loadSettings(from: url)) { error in
            guard case SettingsError.invalid(_, let reason) = error else {
                return XCTFail("expected invalid, got \(error)")
            }
            XCTAssertEqual(reason, "file is empty")
        }
    }

    func testUnknownSettingsKeyThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-unknown-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"include_system\":true}".utf8).write(to: url)
        XCTAssertThrowsError(try loadSettings(from: url)) { error in
            guard case SettingsError.invalid(_, let reason) = error else {
                return XCTFail("expected invalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("include_system"), reason)
        }
    }

    func testSettingsWrongTypeThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-type-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"confirmDelete\":\"yes\"}".utf8).write(to: url)
        XCTAssertThrowsError(try loadSettings(from: url)) { error in
            guard case SettingsError.invalid(_, let reason) = error else {
                return XCTFail("expected invalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("wrong type"), reason)
        }
        try Data("{\"includeSystem\":1}".utf8).write(to: url)
        XCTAssertThrowsError(try loadSettings(from: url)) { error in
            guard case SettingsError.invalid = error else {
                return XCTFail("expected invalid for numeric bool, got \(error)")
            }
        }
    }

    func testSettingsNormalizesEmptyAndDuplicateIgnoredPaths() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-norm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"ignoredLeftoverPaths\":[\"/tmp/A\",\"\",\"/tmp/A\",\"/tmp/B\"]}".utf8).write(to: url)
        let loaded = try loadSettings(from: url)
        XCTAssertEqual(loaded.ignoredLeftoverPaths, ["/tmp/A", "/tmp/B"])
    }

    func testRelativeIgnoredPathThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-rel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // A relative or `~` entry matches no reported path, so the leftover it
        // names stays in every report while the file reads as if it were hidden.
        for entry in ["~/.cache/Whisky", "Whisky", "./Whisky", "../Whisky"] {
            try Data("{\"ignoredLeftoverPaths\":\(String(reflecting: entry))]}".utf8).write(to: url)
            XCTAssertThrowsError(try loadSettings(from: url)) { error in
                guard case SettingsError.invalid(_, let reason) = error else {
                    return XCTFail("expected invalid for \(entry), got \(error)")
                }
                XCTAssertTrue(reason.contains("not an absolute path"), reason)
                XCTAssertTrue(reason.contains(entry), reason)
            }
        }
        try Data(#"{"ignoredLeftoverPaths":["/tmp/A","/tmp/Whisky"]}"#.utf8).write(to: url)
        XCTAssertEqual(try loadSettings(from: url).ignoredLeftoverPaths, ["/tmp/A", "/tmp/Whisky"])
    }

    func testIgnoredPathWithTrailingSlashThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-slash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // Matching is exact, so a trailing slash never matches the path a
        // report prints and the leftover it names stays in every report.
        try Data(#"{"ignoredLeftoverPaths":["/tmp/Foo/"]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try loadSettings(from: url)) { error in
            guard case SettingsError.invalid(_, let reason) = error else {
                return XCTFail("expected invalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("trailing slash"), reason)
            XCTAssertTrue(reason.contains("/tmp/Foo/"), reason)
        }
    }

    func testEffectiveIncludeSystemPrefersCLIFlag() {
        XCTAssertFalse(effectiveIncludeSystem(cliFlag: false, settings: .default))
        XCTAssertTrue(effectiveIncludeSystem(cliFlag: true, settings: .default))
        var on = AppAtticSettings.default
        on.includeSystem = true
        XCTAssertTrue(effectiveIncludeSystem(cliFlag: false, settings: on))
        XCTAssertTrue(effectiveIncludeSystem(cliFlag: true, settings: on))
    }

    func testSaveSettingsThrowsWhenParentIsAFile() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-notdir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("settings.json")
        XCTAssertThrowsError(try saveSettings(.default, to: url)) { error in
            guard case SettingsError.unwritable = error else {
                return XCTFail("expected unwritable, got \(error)")
            }
        }
    }

    func testVisibleOrphanedLeftoversHidesIgnoredPaths() {
        let leftovers = [
            LeftoverItem(name: "Foo", path: "/tmp/Foo", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
            LeftoverItem(name: "Bar", path: "/tmp/Bar", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 20),
            LeftoverItem(name: "Sys", path: "/tmp/Sys", root: "Caches", kind: "dir", status: "system", size_bytes: 30),
        ]
        let visible = visibleOrphanedLeftovers(leftovers, ignoring: ["/tmp/Foo"])
        XCTAssertEqual(visible.map(\.path), ["/tmp/Bar"])
    }

    func testIgnoredLeftoverPathsMatchAcrossNFCAndNFD() {
        let nfc = "/tmp/Café"
        let nfd = "/tmp/Cafe\u{0301}"
        let leftovers = [
            LeftoverItem(name: "Café", path: nfd, root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
        ]
        XCTAssertTrue(visibleOrphanedLeftovers(leftovers, ignoring: [nfc]).isEmpty)
        let settings = AppAtticSettings(ignoredLeftoverPaths: [nfd]).normalized()
        XCTAssertEqual(settings.ignoredLeftoverPaths, [nfc.precomposedStringWithCanonicalMapping])
        let loaded = AppAtticSettings(ignoredLeftoverPaths: [nfc, nfd, nfc]).normalized()
        XCTAssertEqual(loaded.ignoredLeftoverPaths, [nfc.precomposedStringWithCanonicalMapping])
    }

    func testLeftoverIgnorePathsIncludesEveryPathInGroup() {
        let item = LeftoverItem(
            name: "Whisky",
            path: "/tmp/Whisky",
            root: "Application Support",
            kind: "dir",
            status: "orphaned",
            extra_paths: ["/tmp/Whisky.plist", "/tmp/Containers/Whisky"]
        )
        XCTAssertEqual(
            Set(leftoverIgnorePaths(item)),
            ["/tmp/Whisky", "/tmp/Whisky.plist", "/tmp/Containers/Whisky"]
        )
    }

    func testVisibleOrphanedLeftoversHidesGroupWhenExtraPathIgnored() {
        let leftovers = [
            LeftoverItem(
                name: "Whisky",
                path: "/tmp/Whisky",
                root: "Application Support",
                kind: "dir",
                status: "orphaned",
                size_bytes: 100,
                extra_paths: ["/tmp/Whisky.plist"]
            ),
        ]
        XCTAssertEqual(visibleOrphanedLeftovers(leftovers, ignoring: []).map(\.path), ["/tmp/Whisky"])
        XCTAssertTrue(visibleOrphanedLeftovers(leftovers, ignoring: ["/tmp/Whisky.plist"]).isEmpty)
        let data = sampleScanData(leftovers: leftovers)
        let script = cleanupScript(from: data, ignoringLeftovers: ["/tmp/Whisky.plist"])
        // No removal line for the hidden group, not merely no path in a comment.
        XCTAssertFalse(script.contains("rm -rf"), script)
    }

    func testClearIgnoredLeftovers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-settings-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try saveSettings(AppAtticSettings(ignoredLeftoverPaths: ["/tmp/Foo"]), to: url)
        var settings = try loadSettings(from: url)
        XCTAssertEqual(settings.ignoredLeftoverPaths, ["/tmp/Foo"])
        settings.ignoredLeftoverPaths = []
        try saveSettings(settings, to: url)
        XCTAssertEqual(try loadSettings(from: url).ignoredLeftoverPaths, [])
    }

    func testPruneSelectionDropsGoneAndIgnored() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned"),
                LeftoverItem(name: "Hide", path: "/tmp/Hide", root: "Caches", kind: "dir", status: "orphaned"),
            ],
            software: [
                SoftwareItem(name: "App", kind: "app", path: "/Apps/App.app", source: "app", tier: "remove"),
            ],
            outdated: [
                OutdatedEntry(name: "jq", manager: "brew-formula"),
            ]
        )
        let pruned = pruneCleanupSelection(
            leftovers: ["/tmp/Keep", "/tmp/Hide", "/tmp/Gone"],
            apps: ["/Apps/App.app", "/Apps/Missing.app"],
            outdated: ["brew-formula:jq", "brew-formula:wget"],
            data: data,
            ignoring: ["/tmp/Hide"]
        )
        XCTAssertEqual(pruned.leftovers, Set(["/tmp/Keep"]))
        XCTAssertEqual(pruned.apps, Set(["/Apps/App.app"]))
        XCTAssertEqual(pruned.outdated, Set(["brew-formula:jq"]))
    }

    func testPruneSelectionDropsKeepTierAndNonUpdatableOutdated() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned"),
                LeftoverItem(name: "Owned", path: "/tmp/Owned", root: "Caches", kind: "dir", status: "owned"),
            ],
            software: [
                SoftwareItem(name: "KeepMe", kind: "app", path: "/Apps/Keep.app", source: "app", tier: "keep"),
                SoftwareItem(name: "ReviewMe", kind: "app", path: "/Apps/Review.app", source: "app", tier: "review"),
                SoftwareItem(name: "RemoveMe", kind: "app", path: "/Apps/Remove.app", source: "app", tier: "remove"),
            ],
            outdated: [
                OutdatedEntry(name: "jq", manager: "brew-formula"),
                OutdatedEntry(name: "sketchy", manager: "brew-cask", kind: "untrusted"),
                OutdatedEntry(name: "Pages", manager: "app-store"),
            ]
        )
        let pruned = pruneCleanupSelection(
            leftovers: ["/tmp/Keep", "/tmp/Owned"],
            apps: ["/Apps/Keep.app", "/Apps/Review.app", "/Apps/Remove.app"],
            outdated: ["brew-formula:jq", "brew-cask:sketchy", "app-store:Pages"],
            data: data,
            ignoring: []
        )
        XCTAssertEqual(pruned.leftovers, Set(["/tmp/Keep"]))
        XCTAssertEqual(pruned.apps, Set(["/Apps/Review.app", "/Apps/Remove.app"]))
        XCTAssertEqual(pruned.outdated, Set(["brew-formula:jq"]))
    }

    func testResolvedSelectionFallsBackWhenHidden() {
        XCTAssertEqual(resolvedSelection("gone", visibleIds: ["a", "b"]), "a")
        XCTAssertEqual(resolvedSelection("b", visibleIds: ["a", "b"]), "b")
        XCTAssertNil(resolvedSelection("gone", visibleIds: []))
        XCTAssertEqual(resolvedSelection(nil, visibleIds: ["a"]), "a")
    }

    func testCommandFailureMessageIncludesStderr() {
        XCTAssertEqual(
            commandFailureMessage(status: 1, stderr: ""),
            "Command failed (exit 1)."
        )
        XCTAssertEqual(
            commandFailureMessage(status: 2, stderr: "  brew: no such keg  "),
            "Command failed (exit 2). brew: no such keg"
        )
    }

    func testCommandFailureMessageReportsTheEndOfALongStderr() {
        // A capped read keeps the tail, and a package manager prints the reason
        // where it stopped, so the report has to quote from the end.
        let stderr = String(repeating: "installing\n", count: 200) + "E: Subprocess exited with error\n"
        let message = commandFailureMessage(status: 1, stderr: stderr)
        XCTAssertTrue(message.hasSuffix("E: Subprocess exited with error"), message)
        // The cap is 400 characters of detail behind a 25-character prefix.
        // Exactly, not "<= something": a bound looser than the real one passes
        // even when nothing is capped.
        XCTAssertEqual(message.count, 425, String(message.count))
        XCTAssertLessThan(message.count, stderr.count, "the head of a long stderr must be dropped")
    }

    func testCommandFailureMessageRedactsHomePath() {
        XCTAssertEqual(
            commandFailureMessage(
                status: 1,
                stderr: "Error: Permission denied @ unlink_internal - /home/alice/Library/Caches/Homebrew/foo",
                home: "/home/alice"
            ),
            "Command failed (exit 1). Error: Permission denied @ unlink_internal - ~/Library/Caches/Homebrew/foo"
        )
        XCTAssertTrue(
            commandFailureMessage(status: 1, stderr: "/home/alice2/secret", home: "/home/alice")
                .contains("/home/alice2")
        )
    }

    /// These errors name the settings and cache files, which live under the
    /// account home, so their text reaches the terminal, the error bar, and
    /// any pasted bug report with the account name in it.
    func testPersistenceErrorsDoNotCarryTheAccountPath() throws {
        // redactHomePaths matches the standardized home, so build the input
        // from that form or the comparison is between two spellings.
        let home = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        try XCTSkipIf(home.count <= 1 || !home.contains("/"), "no redaction is attempted for a root-only home")

        let settings = SettingsError.unreadable(
            path: home + "/.local/share/appattic/settings.json",
            reason: "permission denied"
        )
        XCTAssertEqual(
            settings.description,
            "cannot read settings ~/.local/share/appattic/settings.json: permission denied"
        )
        XCTAssertFalse(settingsErrorUserMessage(settings).contains(home), settingsErrorUserMessage(settings))

        let io = AppAtticIOError.readFailed(
            path: home + "/.local/share/appattic/last-scan.json",
            message: "The file could not be opened because it is not readable."
        )
        XCTAssertEqual(
            io.errorDescription,
            "Could not read ~/.local/share/appattic/last-scan.json: "
                + "The file could not be opened because it is not readable."
        )
    }

    func testSaveSettingsRestrictsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-perm-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("appattic")
        let url = dir.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try saveSettings(AppAtticSettings(ignoredLeftoverPaths: ["/home/alice/Caches/Foo"]), to: url)
        let fileMode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        let dirMode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(dirMode & 0o777, 0o700)
    }

    func testCleanupScriptSkipsIgnoredLeftovers() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned"),
                LeftoverItem(name: "Hide", path: "/tmp/Hide", root: "Caches", kind: "dir", status: "orphaned"),
            ]
        )
        let script = cleanupScript(from: data, ignoringLeftovers: ["/tmp/Hide"])
        XCTAssertTrue(script.contains("/tmp/Keep"))
        XCTAssertFalse(script.contains("/tmp/Hide"))
    }

    func testExportedScanDataDropsIgnoredLeftovers() {
        let data = sampleScanData(
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
                LeftoverItem(name: "Hide", path: "/tmp/Hide", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 20),
            ]
        )
        let exported = exportedScanData(from: data, ignoringLeftovers: ["/tmp/Hide"], fromCache: true)
        XCTAssertEqual(exported.leftovers.map(\.path), ["/tmp/Keep"])
        XCTAssertEqual(exported.totals.orphaned_items, 1)
        XCTAssertEqual(exported.totals.orphaned_bytes, 10)
        XCTAssertEqual(exported.from_cache, true)
    }

    func testExportedScanDataKeepsAppsInstalledCount() {
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
            brew_available: false,
            totals: ScanTotals(
                apps_installed: 7,
                orphaned_items: 1,
                orphaned_bytes: 10,
                system_leftover_bytes: 0,
                reclaimable_bytes: 10,
                stale_apps: 0,
                outdated_apps: 0
            ),
            leftovers: [
                LeftoverItem(name: "Keep", path: "/tmp/Keep", root: "Caches", kind: "dir", status: "orphaned", size_bytes: 10),
            ],
            software: [
                SoftwareItem(name: "Foo", kind: "app", path: "/Apps/Foo.app", source: "app"),
            ]
        )
        let exported = exportedScanData(from: data, ignoringLeftovers: [], fromCache: false)
        XCTAssertEqual(exported.totals.apps_installed, 7)
        XCTAssertEqual(exported.leftovers.count, 1)
    }

    func testExportedScanDataKeepsACheckThatDidNotRunMissing() {
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
            brew_available: false,
            totals: ScanTotals(
                apps_installed: 0,
                orphaned_items: 0,
                orphaned_bytes: 0,
                system_leftover_bytes: 0,
                reclaimable_bytes: 0,
                stale_apps: 0,
                outdated_apps: nil
            ),
            leftovers: [],
            software: [],
            outdated: nil,
            packages: nil
        )
        let exported = exportedScanData(from: data)
        XCTAssertNil(exported.outdated)
        XCTAssertNil(exported.packages)
        XCTAssertNil(exported.totals.outdated_apps)
    }

    func testExportedScanDataKeepsAnEmptyListFromACheckThatRan() {
        let data = sampleScanData()
        let exported = exportedScanData(from: data)
        XCTAssertEqual(exported.outdated?.count, 0)
        XCTAssertEqual(exported.packages?.count, 0)
        XCTAssertEqual(exported.totals.outdated_apps, 0)
    }

    func testToggleListedSelectionDeselectClearsWholeSet() {
        let selected: Set = ["/a", "/b", "/c"]
        XCTAssertEqual(toggleListedSelection(selected: selected, visible: ["/a"]), [])
        XCTAssertEqual(toggleListedSelection(selected: ["/a"], visible: ["/a", "/b"]), ["/a", "/b"])
    }

    func testScanResultRestoresVersionFromCurrentVersion() {
        let data = sampleScanData(
            software: [
                SoftwareItem(
                    name: "jq",
                    kind: "formula",
                    path: "/opt/homebrew/bin/jq",
                    source: "brew-formula",
                    current_version: "1.7"
                ),
            ]
        )
        let result = scanResult(from: data)
        XCTAssertEqual(result.software[0].version, "1.7")
    }

    func testVisibleStaleSoftwareIncludesSystemWhenAsked() {
        let items = [
            SoftwareItem(name: "Idle", kind: "app", path: "/Apps/Idle.app", source: "app", tier: "review"),
            SoftwareItem(name: "Safari", kind: "app", path: "/Apps/Safari.app", source: "system", tier: "system"),
            SoftwareItem(name: "Keep", kind: "app", path: "/Apps/Keep.app", source: "app", tier: "keep"),
        ]
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: false).map(\.name), ["Idle"])
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: true).map(\.name), ["Idle", "Safari"])
    }

    func testRemainingPendingAppPathsKeepsSteamWithoutAppId() {
        let leftover = SoftwareItem(name: "Foo", kind: "app", path: "/Apps/Foo.app", source: "app", tier: "remove")
        let steam = SoftwareItem(name: "EmuDevz", kind: "app", path: "/tmp/steamapps/common/EmuDevz", source: "steam", tier: "remove")
        let kept = remainingPendingAppPaths(
            selected: [leftover.path, steam.path],
            software: [leftover, steam]
        )
        XCTAssertEqual(kept, [steam.path])
    }

    func testRemainingPendingAppPathsKeepsSteamHandoff() {
        let leftover = SoftwareItem(name: "Foo", kind: "app", path: "/Apps/Foo.app", source: "app", tier: "remove")
        let steam = SoftwareItem(
            name: "EmuDevz",
            kind: "app",
            path: "/tmp/steamapps/common/EmuDevz",
            source: "steam",
            tier: "remove",
            steam_appid: "4260720"
        )
        XCTAssertTrue(isHandoffUninstallCommand(uninstallCommand(
            source: steam.source,
            name: steam.name,
            path: steam.path,
            caskName: nil,
            steamAppId: steam.steam_appid
        )))
        let kept = remainingPendingAppPaths(
            selected: [leftover.path, steam.path],
            software: [leftover, steam]
        )
        XCTAssertEqual(kept, [steam.path])
    }

    func testVisibleStaleCountIncludesSystemWhenAsked() {
        let items = [
            SoftwareItem(name: "Idle", kind: "app", path: "/Apps/Idle.app", source: "app", tier: "review"),
            SoftwareItem(name: "Safari", kind: "app", path: "/Apps/Safari.app", source: "system", tier: "system"),
        ]
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: true).count, 2)
        XCTAssertEqual(visibleStaleSoftware(items, includeSystem: false).count, 1)
    }
}

final class ResolveScanTests: XCTestCase {
    func testUsesCacheWhenFreshAndFingerprintMatch() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cached = sampleScanData(scannedAt: "2026-08-17T12:00:00Z")
        try writeScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: cached), to: cacheURL)
        var liveCalls = 0
        let resolved = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in
                liveCalls += 1
                return sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
            }
        )
        XCTAssertEqual(liveCalls, 0)
        XCTAssertTrue(resolved.fromCache)
        XCTAssertEqual(resolved.data.scanned_at, "2026-08-17T12:00:00Z")
        XCTAssertEqual(resolved.data.from_cache, true)
    }

    func testFreshOrForceLiveSkipsCache() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-fresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        try writeScanCache(
            ScanCacheFile(fingerprint: "fp", includeSystem: false, data: sampleScanData(scannedAt: "2026-08-17T12:00:00Z")),
            to: cacheURL
        )
        var liveCalls = 0
        let live = sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
        let fresh = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in
                liveCalls += 1
                return live
            }
        )
        XCTAssertEqual(liveCalls, 1)
        XCTAssertFalse(fresh.fromCache)
        XCTAssertEqual(fresh.data.scanned_at, "2026-08-17T13:00:00Z")

        liveCalls = 0
        let update = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: true,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in
                liveCalls += 1
                return live
            }
        )
        XCTAssertEqual(liveCalls, 1)
        XCTAssertFalse(update.fromCache)
    }

    func testStaleCacheRunsLiveScanAndSaves() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-stale-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        try writeScanCache(
            ScanCacheFile(fingerprint: "old", includeSystem: false, data: sampleScanData(scannedAt: "2026-08-17T12:00:00Z")),
            to: cacheURL
        )
        let live = sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
        let resolved = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "new" },
            liveScan: { _ in live }
        )
        XCTAssertFalse(resolved.fromCache)
        let saved = try XCTUnwrap(loadScanCache(from: cacheURL))
        XCTAssertEqual(saved.fingerprint, "new")
        XCTAssertEqual(saved.data.scanned_at, "2026-08-17T13:00:00Z")
    }

    func testDoesNotOverwriteCacheWhenFingerprintMovesDuringScan() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-move-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        try writeScanCache(
            ScanCacheFile(fingerprint: "old", includeSystem: false, data: sampleScanData(scannedAt: "2026-08-17T12:00:00Z")),
            to: cacheURL
        )
        var n = 0
        let resolved = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: {
                n += 1
                return n == 1 ? "before" : "after"
            },
            liveScan: { _ in sampleScanData(scannedAt: "2026-08-17T13:00:00Z") }
        )
        XCTAssertFalse(resolved.fromCache)
        XCTAssertEqual(resolved.data.scanned_at, "2026-08-17T13:00:00Z")
        // resolveScan samples the fingerprint once before the scan and once
        // after; a single sample could not detect a move.
        XCTAssertEqual(n, 2)
        let saved = try XCTUnwrap(loadScanCache(from: cacheURL))
        XCTAssertEqual(saved.fingerprint, "old")
        XCTAssertEqual(saved.data.scanned_at, "2026-08-17T12:00:00Z")
    }

    func testDoesNotCreateCacheWhenFingerprintMovesDuringScan() {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-nocreate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        var n = 0
        _ = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: {
                n += 1
                return n == 1 ? "before" : "after"
            },
            liveScan: { _ in sampleScanData(scannedAt: "2026-08-17T13:00:00Z") }
        )
        XCTAssertNil(loadScanCache(from: cacheURL))
        XCTAssertEqual(n, 2)
    }

    func testDoesNotSaveIncompleteLiveScan() {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-incomplete-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        var live = sampleScanData(scannedAt: "2026-08-17T13:00:00Z")
        live.incomplete = true
        _ = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: false,
            cacheURL: cacheURL,
            now: parseISODate("2026-08-17T12:30:00Z")!,
            fingerprintFn: { "fp" },
            liveScan: { _ in live }
        )
        XCTAssertNil(loadScanCache(from: cacheURL))
    }
}

func sampleScanData(
    scannedAt: String = "2026-08-17T12:00:00Z",
    leftovers: [LeftoverItem] = [],
    software: [SoftwareItem] = [],
    outdated: [OutdatedEntry] = [],
    packages: [PackageEntry] = []
) -> ScanData {
    ScanData(
        scanned_at: scannedAt,
        duration_s: 1,
        brew_available: false,
        totals: ScanTotals(
            apps_installed: 0,
            orphaned_items: leftovers.filter { $0.status == "orphaned" }.count,
            orphaned_bytes: leftovers.reduce(0) { $0 + ($1.size_bytes ?? 0) },
            system_leftover_bytes: 0,
            reclaimable_bytes: leftovers.reduce(0) { $0 + ($1.size_bytes ?? 0) },
            stale_apps: 0,
            outdated_apps: outdated.count
        ),
        leftovers: leftovers,
        software: software,
        outdated: outdated,
        packages: packages
    )
}
