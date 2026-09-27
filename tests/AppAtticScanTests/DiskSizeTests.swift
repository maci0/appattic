import XCTest
@testable import AppAtticScan

final class DiskSizeTests: XCTestCase {
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


    func testDuSizesBatchesOneSpawnAndFallsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-batch-\(UUID().uuidString)")
        let dirA = root.appendingPathComponent("a")
        let dirB = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x65, count: 100).write(to: dirA.appendingPathComponent("f.bin"))
        try Data(repeating: 0x65, count: 100).write(to: dirB.appendingPathComponent("g.bin"))
        var spawns = 0
        let run: CommandRun = { cmd, _ in
            spawns += 1
            // Only dirA reported; dirB must fall back to the in-process walk.
            // The missing path falls back too.
            return (0, "4\t\(dirA.path)\n", "")
        }
        let sizes = duSizes([dirA.path, dirB.path, root.appendingPathComponent("gone").path], run: run)
        // One spawn per chunk, not one per path (nor per fallback binary).
        XCTAssertEqual(spawns, 1)
        XCTAssertEqual(sizes[dirA.path]?.0, 4096)
        XCTAssertEqual(sizes[dirA.path]?.1, true)
        XCTAssertEqual(sizes[dirB.path]?.0, 100)
        XCTAssertEqual(sizes[dirB.path]?.1, true)
        XCTAssertEqual(sizes[root.appendingPathComponent("gone").path]?.1, false)
    }


    func testDuSizesFilePathsNeedNoSpawn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("du-batch-file-\(UUID().uuidString).bin")
        try Data(repeating: 0x66, count: 512).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var spawns = 0
        let run: CommandRun = { cmd, _ in
            spawns += 1
            return (1, "", "")
        }
        let sizes = duSizes([url.path], run: run)
        XCTAssertEqual(spawns, 0)
        XCTAssertEqual(sizes[url.path]?.0, 512)
    }
}
