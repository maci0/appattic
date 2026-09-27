import Foundation
import XCTest
@testable import AppAtticScan

/// A scan fans out through `pmap`, so `progress` used to be invoked from several
/// worker threads at once and a caller keeping state behind the callback read
/// and wrote it unsynchronised. These pin the serialized contract and the
/// one-scan-at-a-time scope of the shared failure set.
///
/// Run under `swift test --sanitize=thread` to get the memory-ordering evidence;
/// the assertions below catch the behavioural half.
final class ScanConcurrencyTests: XCTestCase {
    /// Detects two callbacks in flight at the same time. The counters are
    /// deliberately unsynchronised: the callback runs on one thread by
    /// contract, so they need no lock and any overlap shows up as a peak above
    /// one.
    private final class OverlapDetector {
        private(set) var peak = 0
        private var inFlight = 0

        func enter() {
            inFlight += 1
            if inFlight > peak { peak = inFlight }
        }

        func leave() {
            inFlight -= 1
        }
    }

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-200 * 86400)
        for i in 0..<12 {
            let dir = root.appendingPathComponent("DeadApp\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 2048)
                .write(to: dir.appendingPathComponent("cache.bin"))
            try FileManager.default.setAttributes(
                [.modificationDate: old], ofItemAtPath: dir.path
            )
        }
        return root
    }

    private func scan(roots: [URL], progress: @escaping @Sendable (String) -> Void) -> ScanResult {
        performScan(
            includeSystem: false,
            apps: [],
            brew: BrewSnapshot(available: false),
            leftoverRoots: roots.map { ("Application Support", $0.path, "dir") },
            linuxOutdated: [],
            appStoreOutdated: [],
            packages: [],
            history: HistoryIndex(),
            skipLiveUsage: true,
            progress: progress
        )
    }

    func testProgressIsNeverInvokedConcurrently() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = OverlapDetector()
        let messages = Messages()

        let result = scan(roots: [root]) { message in
            detector.enter()
            messages.append(message)
            detector.leave()
        }

        XCTAssertGreaterThan(messages.count, 0, "the scan emitted no progress at all")
        XCTAssertEqual(
            detector.peak, 1,
            "progress ran on \(detector.peak) threads at once; pmap workers reach the callback directly"
        )
        XCTAssertTrue(result.orphanedItems.contains { $0.name == "DeadApp0" })
    }

    /// Two scans in one process share the failure set, which is reset at the
    /// start of each. Without a scan-level lock one scan's reset can land
    /// inside another's, and each result is then labelled from the other's
    /// evidence. The lanes below are identical, so every result must agree.
    func testConcurrentScansAgreeOnIncompleteness() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let lanes = 4
        let results = Results()

        DispatchQueue.concurrentPerform(iterations: lanes) { _ in
            results.append(scan(roots: [root], progress: { _ in }).incomplete)
        }

        XCTAssertEqual(results.values.count, lanes)
        XCTAssertEqual(
            Set(results.values), Set([results.values[0]]),
            "concurrent scans disagreed on `incomplete`, so one read another's failure set"
        )
        XCTAssertTrue(
            scanCheckFailures().isEmpty,
            "a failure from one scan leaked into the process-global set: \(scanCheckFailures())"
        )
    }
}

/// Locked, unlike the detector above: this one only records progress for the
/// "did the scan say anything" assertion and must not be the thing that trips
/// the sanitizer.
private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool?] = []

    var values: [Bool?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool?) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
