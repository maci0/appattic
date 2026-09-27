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
        // A clock stuck at 0 never expires, however slow the host is.
        XCTAssertNotNil(probeActivityMtime(root.path, timeout: 0.001, clock: { 0 }))
    }
}
