import XCTest
@testable import AppAtticScan

final class UtilTests: XCTestCase {
    func testResolveDistroPackageManagerFamilyThenPath() {
        let none: WhichFn = { _ in nil }
        XCTAssertEqual(resolveDistroPackageManager(family: "arch", which: none), .pacman)
        XCTAssertEqual(resolveDistroPackageManager(family: "debian", which: none), .apt)
        XCTAssertEqual(resolveDistroPackageManager(family: "fedora", which: none), .dnf)
        XCTAssertEqual(resolveDistroPackageManager(family: "suse", which: none), .zypper)
        XCTAssertNil(resolveDistroPackageManager(family: "unknown", which: none))
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "pacman" ? "/usr/bin/pacman" : nil }),
            .pacman
        )
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "dnf" ? "/usr/bin/dnf" : nil }),
            .dnf
        )
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "zypper" ? "/usr/bin/zypper" : nil }),
            .zypper
        )
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "apt" ? "/usr/bin/apt" : nil }),
            .apt
        )
        XCTAssertEqual(
            resolveDistroPackageManager(
                family: "unknown",
                which: { ["pacman", "apt"].contains($0) ? "/usr/bin/\($0)" : nil }
            ),
            .pacman
        )
    }

    func testIsDnfListingNoise() {
        XCTAssertTrue(isDnfListingNoise("Last metadata expiration check: 1:23:45 ago"))
        XCTAssertTrue(isDnfListingNoise("Packages"))
        XCTAssertTrue(isDnfListingNoise("Finding unneeded"))
        XCTAssertTrue(isDnfListingNoise("Available Upgrades"))
        XCTAssertTrue(isDnfListingNoise("Obsoleting Packages"))
        XCTAssertFalse(isDnfListingNoise("libfoo"))
        XCTAssertFalse(isDnfListingNoise("git.x86_64                    2.45.1-1.fc40           updates"))
    }

    func testNormStripsPunctuation() {
        XCTAssertEqual(norm("Google Chrome"), "googlechrome")
        XCTAssertEqual(norm("iTerm2"), "iterm2")
        XCTAssertEqual(norm("a1b2"), "a1b2")
    }

    func testNormCollapsesNFCAndNFD() {
        let nfc = "Café"
        let nfd = "Cafe\u{0301}"
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        XCTAssertEqual(norm(nfc), "cafe")
        XCTAssertEqual(norm(nfd), "cafe")
        XCTAssertEqual(norm("Cafe"), "cafe")
        XCTAssertEqual(norm("CAFÉ"), "cafe")
    }

    func testNormCaseFoldsSharpS() {
        XCTAssertEqual(norm("Straße"), "strasse")
    }

    func testPathIdentityKeyUsesNFC() {
        let nfc = "/tmp/Café"
        let nfd = "/tmp/Cafe\u{0301}"
        XCTAssertEqual(pathIdentityKey(nfc), pathIdentityKey(nfd))
        XCTAssertEqual(pathIdentityKey(nfc), nfc.precomposedStringWithCanonicalMapping)
    }

    func testReadUTF8FileReplacesInvalidBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utf8-\(UUID().uuidString).txt")
        try Data([0x41, 0xFF, 0x42]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(readUTF8File(url.path), "A\u{FFFD}B")
        XCTAssertNil(readUTF8File(url.appendingPathComponent("missing").path))
    }

    func testDecodeUTF8StripsLeadingBOM() {
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(contentsOf: "ID=debian\n".utf8)
        XCTAssertEqual(decodeUTF8(bom), "ID=debian\n")
        XCTAssertEqual(decodeUTF8(Data("ID=debian\n".utf8)), "ID=debian\n")
        XCTAssertEqual(decodeUTF8(Data([0xEF, 0xBB, 0xBF])), "")
    }

    func testPosixLowercasedDoesNotUseTurkishI() {
        let turkish = Locale(identifier: "tr_TR")
        XCTAssertEqual("IINA".lowercased(with: turkish), "ıına")
        XCTAssertEqual(posixLowercased("IINA"), "iina")
        XCTAssertEqual(posixLowercased("I"), "i")
        XCTAssertEqual(posixLowercased("Straße"), "straße")
    }

    func testHumanSize() {
        XCTAssertEqual(humanSize(0), "0 B")
        XCTAssertEqual(humanSize(1023), "1023 B")
        XCTAssertEqual(humanSize(1024), "1.0 KB")
        XCTAssertEqual(humanSize(1_048_576), "1.0 MB")
        // 1048525 / 1024 = 1023.95, which %.1f would print as "1024.0 KB".
        XCTAssertEqual(humanSize(1_048_525), "1.0 MB")
        XCTAssertEqual(humanSize(1023 * 1024), "1023.0 KB")
    }

    func testAddBytesSaturates() {
        XCTAssertEqual(addBytes(10, 20), 30)
        XCTAssertEqual(addBytes(Int.max, 1), Int.max)
        XCTAssertEqual(addBytes(Int.max, Int.max), Int.max)
    }

    func testRestrictOwnerOnlyClearsGroupAndOtherBits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-mode-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        restrictOwnerOnly(path: url.path)
        let mode = posixMode(url.path)
        XCTAssertNotEqual(mode, -1)
        XCTAssertEqual(mode & 0o077, 0)
        XCTAssertEqual(mode & 0o600, 0o600)
    }

    func testCleanupPathDirectoriesIncludeLinuxAndDarwinBins() {
        let dirs = cleanupPathDirectories(home: "/home/x")
        XCTAssertTrue(dirs.contains("/home/linuxbrew/.linuxbrew/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/home/x/.local/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/home/x/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/usr/local/bin"), "\(dirs)")
    }

    func testXdgUserDirsHonorEnvEmptyAndFallback() {
        let home = "/home/x"
        XCTAssertEqual(xdgDataHome(home: home, env: [:]), "/home/x/.local/share")
        XCTAssertEqual(xdgConfigHome(home: home, env: [:]), "/home/x/.config")
        XCTAssertEqual(xdgCacheHome(home: home, env: [:]), "/home/x/.cache")
        XCTAssertEqual(xdgStateHome(home: home, env: [:]), "/home/x/.local/state")
        XCTAssertEqual(
            xdgDataHome(home: home, env: ["XDG_DATA_HOME": "/tmp/myshare"]),
            "/tmp/myshare"
        )
        XCTAssertEqual(
            xdgConfigHome(home: home, env: ["XDG_CONFIG_HOME": ""]),
            "/home/x/.config"
        )
        XCTAssertEqual(
            xdgDataHome(home: home, env: ["XDG_DATA_HOME": "   "]),
            "/home/x/.local/share"
        )
        XCTAssertEqual(
            xdgCacheHome(home: home, env: ["XDG_CACHE_HOME": "~/mycache"]),
            "/home/x/.cache"
        )
        XCTAssertEqual(
            xdgStateHome(home: home, env: ["XDG_STATE_HOME": "relative/state"]),
            "/home/x/.local/state"
        )
    }

    func testHumanDays() {
        XCTAssertEqual(humanDays(0), "1h")
        XCTAssertEqual(humanDays(0.5), "12h")
        XCTAssertEqual(humanDays(3), "3d")
        XCTAssertEqual(humanDays(21), "3w")
    }

    func testParseMdlsDate() {
        XCTAssertNil(parseMdlsDate("(null)"))
        XCTAssertNil(parseMdlsDate(""))
        let parsed = parseMdlsDate("2026-08-15 00:56:17 +0000")
        XCTAssertNotNil(parsed)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.year, from: parsed!), 2026)
        XCTAssertEqual(cal.component(.month, from: parsed!), 8)
        XCTAssertEqual(cal.component(.day, from: parsed!), 15)
        XCTAssertEqual(cal.component(.hour, from: parsed!), 0)
        XCTAssertEqual(cal.component(.minute, from: parsed!), 56)
        XCTAssertEqual(cal.component(.second, from: parsed!), 17)
    }

    func testParseISODateAcceptsZAndOffset() {
        let z = parseISODate("2026-08-17T12:30:00Z")
        let offset = parseISODate("2026-08-17T12:30:00+00:00")
        XCTAssertNotNil(z)
        XCTAssertEqual(z!.timeIntervalSince1970, offset!.timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(parseISODate(isoString(z))!.timeIntervalSince1970, z!.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParseISODateFractionalMicrosecondsFromXBEL() {
        let micro = parseISODate("2026-04-01T15:00:00.123456Z")
        let whole = parseISODate("2026-04-01T15:00:00Z")
        XCTAssertNotNil(micro)
        XCTAssertNotNil(whole)
        XCTAssertEqual(micro!.timeIntervalSince(whole!), 0.123, accuracy: 0.001)
        XCTAssertNotNil(parseISODate("2026-04-01T15:00:00.000000Z"))
        XCTAssertNotNil(parseISODate("2026-04-01T15:00:00.123456+00:00"))
    }

    func testParseISODateTimezoneLessIsUTC() {
        let naive = parseISODate("2026-04-01T15:00:00")
        let z = parseISODate("2026-04-01T15:00:00Z")
        XCTAssertNotNil(naive)
        XCTAssertEqual(naive!.timeIntervalSince1970, z!.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParseISODateOffsetIsInstantNotWallClock() {
        let paris = parseISODate("2026-08-17T14:30:00+02:00")
        let z = parseISODate("2026-08-17T12:30:00Z")
        XCTAssertNotNil(paris)
        XCTAssertEqual(paris!.timeIntervalSince1970, z!.timeIntervalSince1970, accuracy: 0.5)
    }

    func testParseISODateRejectsImpossibleCivilDate() {
        XCTAssertNil(parseISODate("2026-02-31T15:00:00"))
        XCTAssertNil(parseMdlsDate("2026-02-31 15:00:00 +0000"))
    }

    func testParseISODateUtcInstantIsPreviousLocalDayInNewYork() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dt = try XCTUnwrap(parseISODate("2026-03-08T04:30:00Z"))
        XCTAssertEqual(cal.component(.year, from: dt), 2026)
        XCTAssertEqual(cal.component(.month, from: dt), 3)
        XCTAssertEqual(cal.component(.day, from: dt), 7)
        XCTAssertEqual(cal.component(.hour, from: dt), 23)
    }

    func testDateFromUnixEpochScalesMillisAndMicros() {
        let seconds: TimeInterval = 1_717_200_000
        XCTAssertEqual(dateFromUnixEpoch(seconds).timeIntervalSince1970, seconds, accuracy: 0.5)
        XCTAssertEqual(dateFromUnixEpoch(seconds * 1_000).timeIntervalSince1970, seconds, accuracy: 0.5)
        XCTAssertEqual(dateFromUnixEpoch(seconds * 1_000_000).timeIntervalSince1970, seconds, accuracy: 0.5)
    }

    func testDaysSinceNil() {
        XCTAssertNil(daysSince(nil))
        let now = Date(timeIntervalSince1970: 1_787_011_200)
        XCTAssertEqual(daysSince(now.addingTimeInterval(-3 * 86400), now: now), 3.0)
    }

    func testDaysSinceIsElapsedHoursNotCalendarDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twelveHours = now.addingTimeInterval(-12 * 3600)
        XCTAssertEqual(daysSince(twelveHours, now: now)!, 0.5, accuracy: 0.0001)
        XCTAssertNil(calendarDaysSince(nil))
    }

    func testCalendarDaysSinceSpringForwardIsYesterdayNotToday() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.timeZone = tz
        c.year = 2026; c.month = 3; c.day = 7; c.hour = 23; c.minute = 30
        let saturday = try XCTUnwrap(cal.date(from: c))
        c.day = 8; c.hour = 22; c.minute = 30
        let sunday = try XCTUnwrap(cal.date(from: c))
        XCTAssertLessThan(sunday.timeIntervalSince(saturday) / 86400, 1)
        XCTAssertEqual(calendarDaysSince(saturday, now: sunday, calendar: cal), 1)
    }

    func testCalendarDaysSinceFallBackSameDayStaysToday() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.timeZone = tz
        c.year = 2026; c.month = 11; c.day = 1; c.hour = 0; c.minute = 0
        let morning = try XCTUnwrap(cal.date(from: c))
        c.hour = 23; c.minute = 30
        let evening = try XCTUnwrap(cal.date(from: c))
        XCTAssertGreaterThan(evening.timeIntervalSince(morning) / 86400, 1)
        XCTAssertEqual(calendarDaysSince(morning, now: evening, calendar: cal), 0)
    }

    func testRunCommandReturnsLargeStdoutBeforeTimeout() {
        let (rc, out, err) = runCommand(
            ["/bin/sh", "-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' a"],
            timeout: 5
        )
        XCTAssertEqual(rc, 0, err)
        XCTAssertEqual(out.count, 256 * 1024)
    }

    func testRunCommandTimesOutAndKills() {
        let start = monotonicSeconds()
        let (rc, _, err) = runCommand(["/bin/sleep", "30"], timeout: 0.4)
        XCTAssertEqual(rc, 127)
        XCTAssertEqual(err, "timeout")
        XCTAssertLessThan(monotonicSeconds() - start, 3)
    }

    func testRunCommandReturnsPromptlyWhenChildExits() {
        let start = monotonicSeconds()
        let (rc, _, err) = runCommand(["/bin/true"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertLessThan(monotonicSeconds() - start, 1.5)
    }

    func testRunCommandDecodesInvalidUTF8() {
        let (rc, out, err) = runCommand(["/bin/sh", "-c", "printf '\\xff'"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertEqual(out, "\u{FFFD}", "invalid UTF-8 must become a replacement character, not empty (brew JSON would look like a failed command)")
    }

    func testDirectoryByteSizeCountsFilesInDirectoryWithSpaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-spaces-\(UUID().uuidString)")
            .appendingPathComponent("Application Support")
        let dir = root.appendingPathComponent("BetterDisplay")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let payload = Data(repeating: 0x61, count: 5000)
        try payload.write(to: dir.appendingPathComponent("cache.bin"))
        let (bytes, ok) = directoryByteSize(dir.path, timeout: 6)
        XCTAssertTrue(ok, "directoryByteSize failed for \(dir.path)")
        XCTAssertEqual(bytes, 5000)
    }

    func testDirectoryByteSizePmapMeasuresEveryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-pmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var dirs: [String] = []
        for i in 0..<24 {
            let dir = root.appendingPathComponent("App \(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: UInt8(i), count: 1024).write(to: dir.appendingPathComponent("f.bin"))
            dirs.append(dir.path)
        }
        let results = pmap(dirs, workers: 4) { directoryByteSize($0, timeout: 6) }
        for (path, pair) in zip(dirs, results) {
            XCTAssertTrue(pair.1, "unmeasured \(path)")
            XCTAssertGreaterThanOrEqual(pair.0, 1024, path)
        }
    }

    func testPmapRunCommandKeepsStdoutWithWorker() {
        let n = 32
        let results = pmap(Array(0..<n), workers: 16) { i -> String in
            let (rc, out, err) = runCommand(["/bin/echo", "item-\(i)"], timeout: 5)
            XCTAssertEqual(rc, 0, err)
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(results.count, n)
        for i in 0..<n {
            XCTAssertEqual(results[i], "item-\(i)")
        }
    }

    func testDirectoryByteSizeKeepsPartialTotalOnTimeout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<8 {
            try Data(repeating: 0x61, count: 1024).write(to: root.appendingPathComponent("f\(i).bin"))
        }
        let (bytes, ok) = directoryByteSize(root.path, timeout: -1)
        XCTAssertFalse(ok, "timeout is a partial measurement")
        XCTAssertGreaterThanOrEqual(bytes, 0)
        XCTAssertLessThan(bytes, 8 * 1024 + 1)
    }

    func testParseDuKBRequiresLeadingInteger() {
        XCTAssertEqual(parseDuKB("49188\t/Applications/The Unarchiver.app\n").0, 49188 * 1024)
        XCTAssertTrue(parseDuKB("49188\t/Applications/The Unarchiver.app\n").1)
        XCTAssertFalse(parseDuKB("").1)
        XCTAssertFalse(parseDuKB("du: Operation not permitted\n").1)
        XCTAssertFalse(parseDuKB("-5\t/x\n").1)
        XCTAssertFalse(parseDuKB("0\t/x\n").1)
        let overflow = parseDuKB("\(Int.max)\t/x\n")
        XCTAssertFalse(overflow.1)
        XCTAssertEqual(overflow.0, 0)
    }

    func testIntFromSizeAttributeAcceptsBoxedIntegers() {
        XCTAssertEqual(intFromSizeAttribute(NSNumber(value: 5000)), 5000)
        XCTAssertEqual(intFromSizeAttribute(5000), 5000)
        XCTAssertEqual(intFromSizeAttribute(Int64(5000)), 5000)
        XCTAssertEqual(intFromSizeAttribute(UInt64(5000)), 5000)
        XCTAssertEqual(intFromSizeAttribute(nil), 0)
        XCTAssertEqual(intFromSizeAttribute("nope"), 0)
        XCTAssertEqual(intFromSizeAttribute(NSNumber(value: -1)), 0)
        XCTAssertEqual(intFromSizeAttribute(UInt64.max), Int.max)
    }

    func testFileSizeReadsNSNumberBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("blob.bin").path
        try Data(repeating: 0x61, count: 5000).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(fileSize(path), 5000)
        XCTAssertEqual(fileSize(dir.appendingPathComponent("missing.bin").path), 0)
    }

    func testDuSizeFallsBackWhenSpawnedDuIsUnusable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x62, count: 4096).write(to: root.appendingPathComponent("blob.bin"))
        let denied: CommandRun = { cmd, _ in
            if cmd.contains(where: { $0.hasSuffix("mdls") }) { return (1, "", "not indexed") }
            return (0, "du: Operation not permitted\n", "")
        }
        let (bytes, ok) = duSize(root.path, timeout: 6, run: denied)
        XCTAssertTrue(ok)
        XCTAssertEqual(bytes, 4096)
    }

    func testDuSizeFallsBackWhenDuReportsZeroForNonemptyTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-zero-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x63, count: 2048).write(to: root.appendingPathComponent("blob.bin"))
        let zero: CommandRun = { cmd, _ in
            if cmd.contains(where: { $0.hasSuffix("mdls") }) { return (1, "", "") }
            return (0, "0\t\(root.path)\n", "")
        }
        let (bytes, ok) = duSize(root.path, timeout: 6, run: zero)
        XCTAssertTrue(ok)
        XCTAssertEqual(bytes, 2048)
    }

    func testDuSizeUsesSpotlightSizeWhenWalkCannotMeasure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-mdls-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let run: CommandRun = { cmd, _ in
            if cmd.contains(where: { $0.hasSuffix("mdls") }) { return (0, "49163005\n", "") }
            return (1, "", "denied")
        }
        let (bytes, ok) = duSize(root.path, timeout: -1, run: run)
        XCTAssertTrue(ok)
        XCTAssertEqual(bytes, 49_163_005)
    }

    func testDuSizeIgnoresSpotlightStubSizeOnNonAppDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caskroom-\(UUID().uuidString)")
            .appendingPathComponent("bbedit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data(repeating: 0x64, count: 5000).write(to: root.appendingPathComponent("payload.bin"))
        let stub: CommandRun = { cmd, _ in
            if cmd.contains(where: { $0.hasSuffix("mdls") }) { return (0, "2\n", "") }
            return (0, "0\t\(root.path)\n", "")
        }
        let (bytes, ok) = duSize(root.path, timeout: 6, run: stub)
        XCTAssertTrue(ok)
        XCTAssertEqual(bytes, 5000)
    }

    func testSpotlightFSSizeParsesRawBytes() {
        let run: CommandRun = { _, _ in (0, "49163005\n", "") }
        XCTAssertEqual(spotlightFSSize("/Applications/The Unarchiver.app", run: run), 49_163_005)
        let missing: CommandRun = { _, _ in (0, "(null)\n", "") }
        XCTAssertNil(spotlightFSSize("/tmp/missing.app", run: missing))
    }

    func testRedactHomePathsReplacesHomePrefixOnly() {
        XCTAssertEqual(
            redactHomePaths(
                "rm: cannot remove '/home/alice/Library/Caches/Foo': Permission denied",
                home: "/home/alice"
            ),
            "rm: cannot remove '~/Library/Caches/Foo': Permission denied"
        )
        XCTAssertEqual(
            redactHomePaths("failed at /home/alice", home: "/home/alice"),
            "failed at ~"
        )
        XCTAssertEqual(
            redactHomePaths("/home/alice2/secret", home: "/home/alice"),
            "/home/alice2/secret"
        )
        XCTAssertEqual(redactHomePaths("/tmp/x", home: "/"), "/tmp/x")
    }

    func testWriteOwnerOnlyFileIsOwnerReadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owner-only-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOwnerOnlyFile(Data("secret".utf8), to: url)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "secret")
    }
}
