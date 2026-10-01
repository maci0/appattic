import XCTest
@testable import AppAtticScan

// Walk budgets are the one place a scan's output depends on machine speed:
// `directoryByteSize` reports partial sizes and `probeActivityMtime` reports no
// activity once the deadline passes, and both feed leftover status. These pin
// that the deadline reads the injected clock, so a replay can step it instead
// of inheriting the host's uptime.
final class ClockDeterminismTests: XCTestCase {
    private func makeTree(_ tag: String, files: Int, bytes: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clock-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<files {
            try Data(repeating: 0x61, count: bytes)
                .write(to: root.appendingPathComponent("f\(i).bin"))
        }
        return root
    }

    /// Returns 0 on the first call, then jumps far past any deadline. Real
    /// uptime never behaves this way, so these assertions fail if the walk
    /// reads the system clock instead of the injected one.
    private func jumpingClock() -> MonotonicFn {
        var calls = 0
        return {
            calls += 1
            return calls <= 1 ? 0 : 10_000
        }
    }

    func testDirectoryByteSizeWalksFullyOnFrozenClock() throws {
        let root = try makeTree("frozen", files: 4, bytes: 2048)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, complete) = directoryByteSize(root.path, timeout: 6, clock: { 0 })
        XCTAssertTrue(complete)
        XCTAssertEqual(bytes, 4 * 2048)
    }

    func testDirectoryByteSizeStopsWhenInjectedClockPassesDeadline() throws {
        let root = try makeTree("jump", files: 8, bytes: 2048)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, complete) = directoryByteSize(root.path, timeout: 0.5, clock: jumpingClock())
        XCTAssertFalse(complete, "a walk past the injected deadline is partial")
        XCTAssertLessThan(bytes, 8 * 2048)
    }

    func testProbeActivityMtimeFindsMtimeOnFrozenClock() throws {
        let root = try makeTree("probe-frozen", files: 2, bytes: 16)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(probeActivityMtime(root.path, timeout: 5, clock: { 0 }))
    }

    func testProbeActivityMtimeGivesUpWhenInjectedClockPassesTimeout() throws {
        let root = try makeTree("probe-jump", files: 2, bytes: 16)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(
            probeActivityMtime(root.path, timeout: 0.5, clock: jumpingClock()),
            "no entry is stat'd once the injected clock is past the budget"
        )
    }

    func testProbeActivityMtimeReadsTheInjectedClockNotUptime() throws {
        let root = try makeTree("probe-fixed", files: 2, bytes: 16)
        defer { try? FileManager.default.removeItem(at: root) }
        // A clock stuck at 0 never expires, however slow the host is, so the
        // result says nothing on its own: walking two files takes well under
        // 0.001 s of real uptime, so an implementation reading the host clock
        // would pass too. What distinguishes the two is whether the budget is
        // ever read from the injected clock at all.
        var reads = 0
        let found = probeActivityMtime(root.path, timeout: 0.001, clock: {
            reads += 1
            return 0
        })
        XCTAssertGreaterThan(reads, 0, "the probe must read the injected clock, not the host's uptime")
        XCTAssertNotNil(found)
    }

    // `duSize`, `duSizes` and `pathSizes` are the batch and single entry points
    // a full scan measures with, and all three fall back to the in-process
    // walk when `du` cannot answer. That fallback carries a deadline, so the
    // clock has to reach it: a scan that measures sizes with an injected clock
    // and falls back to the host's uptime reports a different partial size on a
    // loaded host than on an idle one, and the replay diverges.
    private func makeTree(_ tag: String, subdirs: Int, filesPer: Int, bytes: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clock-batch-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for d in 0..<subdirs {
            let sub = root.appendingPathComponent("d\(d)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<filesPer {
                try Data(repeating: 0x61, count: bytes)
                    .write(to: sub.appendingPathComponent("f\(f).bin"))
            }
        }
        return root
    }

    /// Every `du` invocation fails with empty output, so the caller must fall
    /// back to the in-process walk, which is the only path that reads a clock.
    private func noDu(_: [String], _: TimeInterval) -> (Int32, String, String) {
        (1, "", "")
    }

    func testDuSizesWalkFallbackReadsTheInjectedClock() throws {
        let root = try makeTree("du-batch", subdirs: 2, filesPer: 3, bytes: 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<2).map { root.appendingPathComponent("d\($0)").path }
        var reads = 0
        let sizes = duSizes(paths, timeout: 0.5, run: noDu, clock: {
            reads += 1
            return 0
        })
        XCTAssertGreaterThan(
            reads, 0,
            "the du fallback must read the injected clock, not the host's uptime"
        )
        for p in paths {
            XCTAssertEqual(sizes[p]?.0, 3 * 1024)
        }
    }

    func testDuSizesWalkFallbackStopsOnInjectedDeadline() throws {
        let root = try makeTree("du-deadline", subdirs: 1, filesPer: 6, bytes: 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("d0").path
        let pair = duSizes([path], timeout: 0.5, run: noDu, clock: jumpingClock())[path] ?? (0, true)
        XCTAssertFalse(pair.1, "a walk past the injected deadline is partial")
        XCTAssertLessThan(pair.0, 6 * 1024)
    }

    func testDuSizeWalkFallbackReadsTheInjectedClock() throws {
        let root = try makeTree("du-single", subdirs: 1, filesPer: 2, bytes: 512)
        defer { try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let (bytes, measured) = duSize(root.appendingPathComponent("d0").path, timeout: 0.5, run: noDu, clock: {
            reads += 1
            return 0
        })
        XCTAssertGreaterThan(reads, 0, "duSize's walk fallback must read the injected clock")
        XCTAssertTrue(measured)
        XCTAssertEqual(bytes, 2 * 512)
    }

    func testPathSizesForwardsTheInjectedClockToItsWalk() throws {
        let root = try makeTree("path-sizes", subdirs: 1, filesPer: 2, bytes: 256)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("d0").path
        var reads = 0
        let sizes = pathSizes([path], timeout: 0.5, run: noDu, clock: {
            reads += 1
            return 0
        })
        XCTAssertGreaterThan(reads, 0, "pathSizes must forward its clock to duSizes")
        XCTAssertEqual(sizes[path]?.0, 2 * 256)
    }
}
