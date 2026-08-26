import XCTest
@testable import AppAtticScan

final class UtilTests: XCTestCase {
    func testNormStripsPunctuation() {
        XCTAssertEqual(norm("Google Chrome"), "googlechrome")
        XCTAssertEqual(norm("iTerm2"), "iterm2")
        XCTAssertEqual(norm("a1b2"), "a1b2")
    }

    func testHumanSize() {
        XCTAssertEqual(humanSize(0), "0 B")
        XCTAssertEqual(humanSize(1024), "1.0 KB")
    }

    func testCleanupPathDirectoriesIncludeLinuxAndDarwinBins() {
        let dirs = cleanupPathDirectories(home: "/home/x")
        XCTAssertTrue(dirs.contains("/home/linuxbrew/.linuxbrew/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/home/x/.local/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/usr/local/bin"), "\(dirs)")
    }

    func testHumanDays() {
        XCTAssertTrue(humanDays(0.5).hasSuffix("h"))
        XCTAssertEqual(humanDays(3), "3d")
        XCTAssertEqual(humanDays(21), "3w")
    }

    func testParseMdlsDate() {
        XCTAssertNil(parseMdlsDate("(null)"))
        XCTAssertNil(parseMdlsDate(""))
        XCTAssertNotNil(parseMdlsDate("2026-08-15 00:56:17 +0000"))
    }

    func testDaysSinceNil() {
        XCTAssertNil(daysSince(nil))
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
        let start = Date()
        let (rc, _, err) = runCommand(["/bin/sleep", "30"], timeout: 0.4)
        XCTAssertEqual(rc, 127)
        XCTAssertEqual(err, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRunCommandDecodesInvalidUTF8() {
        let (rc, out, err) = runCommand(["/bin/sh", "-c", "printf '\\xff'"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertFalse(out.isEmpty, "invalid UTF-8 must not become an empty string (brew JSON would look like a failed command)")
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
}
