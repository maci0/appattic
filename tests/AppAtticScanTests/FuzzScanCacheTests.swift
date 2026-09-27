import XCTest
@testable import AppAtticScan

/// Fuzzes the scan cache, the one JSON file this app reads back: written by a
/// previous run, kept across a release, and reachable by anything running as
/// the account. Every leftover path and package name a report prints, and
/// every removal a cleanup script runs, comes out of it. The harness mutates
/// the bytes of a real snapshot, reads them back through the reader, and
/// asserts both halves of the boundary: what comes out is a value or a typed
/// error and never a trap, and what that value writes out decodes to itself, so
/// a snapshot that loads is a snapshot the next run can serve.
final class FuzzScanCacheTests: XCTestCase {
    private var scratchDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-fuzz-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDir { try? FileManager.default.removeItem(at: scratchDir) }
        scratchDir = nil
        try super.tearDownWithError()
    }

    private func scratchURL(_ name: String) -> URL { scratchDir.appendingPathComponent(name) }

    /// `ScanData` is not `Equatable`, so two snapshots are compared as the bytes
    /// they encode to, with sorted keys so dictionary order cannot fail the
    /// comparison on its own.
    private func canonicalJSON(_ data: ScanData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(data)
    }

    /// A snapshot with a row in every collection the report reads, so the
    /// mutations land on real fields rather than on an empty object.
    private static func seedCache() -> ScanCacheFile {
        ScanCacheFile(
            fingerprint: "ver:1.0.0\neval:20\napps:/Applications:Foo",
            includeSystem: false,
            data: ScanData(
                scanned_at: "2026-08-17T12:00:00Z",
                duration_s: 1.5,
                brew_available: true,
                totals: ScanTotals(
                    apps_installed: 2,
                    orphaned_items: 1,
                    orphaned_bytes: 10,
                    system_leftover_bytes: 0,
                    reclaimable_bytes: 10,
                    stale_apps: 1,
                    outdated_apps: 1
                ),
                leftovers: [
                    LeftoverItem(
                        name: "Foo",
                        path: "/tmp/Foo",
                        root: "Caches",
                        kind: "dir",
                        status: "orphaned",
                        owner: "Foo",
                        size_bytes: 10,
                        size_measured: true,
                        mtime: "2026-08-01T00:00:00Z",
                        reason: "app gone",
                        summary: "10 bytes",
                        extra_paths: ["/tmp/Foo/sub"],
                        shadows: "foo"
                    ),
                ],
                software: [
                    SoftwareItem(
                        name: "Bar",
                        kind: "app",
                        path: "/Applications/Bar.app",
                        source: "brew-cask",
                        version: "1.0",
                        size_bytes: 100,
                        size_measured: true,
                        data_bytes: 20,
                        data_paths: ["/tmp/Bar"],
                        last_used: "2026-08-01T00:00:00Z",
                        tier: "review",
                        reason: "unused 30 days",
                        cask_name: "bar",
                        is_leaf: true,
                        outdated: true,
                        current_version: "1.0",
                        latest_version: "2.0",
                        summary: "1.0 -> 2.0"
                    ),
                ],
                outdated: [
                    OutdatedEntry(name: "Bar", manager: "brew-cask", current_version: "1.0", latest_version: "2.0"),
                ],
                packages: [
                    PackageEntry(
                        name: "libfoo",
                        manager: "pacman",
                        kind: "orphan",
                        version: "1.2.3-1",
                        size_bytes: 5,
                        size_measured: true
                    ),
                ],
                from_cache: true
            )
        )
    }

    /// The JSON text the harness mutates: the encoder's own spelling of a real
    /// snapshot, so the seeds are the bytes a scan actually writes.
    private static func seedTexts() throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = String(decoding: try encoder.encode(seedCache()), as: UTF8.self)
        return [
            snapshot,
            "{}",
            "[]",
            "null",
            "",
            "   ",
            #"{"fingerprint":1}"#,
            #"{"data":{"leftovers":[{"name":"a","path":"/a","root":"Caches","kind":"dir","status":"orphaned","size_bytes":1,"size_measured":true}]}}"#,
        ]
    }

    /// The value the reader hands on has to survive its own writer. A snapshot
    /// that loads and then fails to encode is a snapshot the next run rejects,
    /// so the pair assertion crosses the boundary in both directions.
    private func assertRoundTrips(
        _ cache: ScanCacheFile,
        _ where_: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let out = scratchURL("round-trip.json")
        try writeScanCache(cache, to: out)
        let back = try readScanCache(from: out)
        // `writeScanCache` forces the flag off whatever the value said, so the
        // comparison is on the value that actually reached the disk.
        var expected = cache
        expected.data.from_cache = false
        XCTAssertEqual(back.fingerprint, expected.fingerprint, where_, file: file, line: line)
        XCTAssertEqual(back.includeSystem, expected.includeSystem, where_, file: file, line: line)
        XCTAssertEqual(try canonicalJSON(back.data), try canonicalJSON(expected.data), where_, file: file, line: line)
        XCTAssertEqual(back.data.from_cache, false, "from_cache not forced off: \(where_)", file: file, line: line)
    }

    /// A cached path reaches the script only quoted, or the row is skipped. A
    /// newline, a quote, or a `$` in the path is what turns an argument into a
    /// second command, so the quoted spelling has to be the one that appears.
    private func assertQuotedArgument(
        _ cmd: String,
        contains value: String,
        _ where_: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !value.isEmpty else { return }
        if cmd.hasPrefix("#") {
            XCTAssertTrue(
                cmd.contains(shellQuote(value)) || cmd.contains(shellComment(value)),
                "a skipped row still names its value raw: \(cmd.debugDescription) \(where_)",
                file: file, line: line
            )
            return
        }
        XCTAssertTrue(
            cmd.contains(shellQuote(value)),
            "value spliced unquoted into a command: \(value.debugDescription) in \(cmd.debugDescription) \(where_)",
            file: file, line: line
        )
    }

    /// The reader is total: a mutated file is a snapshot or a typed error, and
    /// a snapshot is deterministic, is never marked as a cache hit, reads its
    /// own stamp the way `isScanCacheExpired` promises, and hands its rows to
    /// the script builders only as quoted arguments.
    func testMutatedSnapshotIsAValueOrATypedError() throws {
        let url = scratchURL("last-scan.json")
        let now = Date()
        var rng = FuzzRandom(seed: 0x5EED_CA9E)
        for base in try FuzzScanCacheTests.seedTexts() {
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng)
                let where_ = "seed \(seed): \(text.debugDescription)"
                try Data(text.utf8).write(to: url)

                let first: ScanCacheFile
                do {
                    first = try readScanCache(from: url)
                } catch let error as AppAtticIOError {
                    // The error is a decision the caller can act on, not a
                    // failure that escapes as some other type.
                    XCTAssertFalse(error.description.isEmpty, "error says nothing: \(where_)")
                    continue
                } catch {
                    XCTFail("unexpected error type: \(where_): \(error)")
                    continue
                }

                XCTAssertEqual(
                    try canonicalJSON(try readScanCache(from: url).data),
                    try canonicalJSON(first.data),
                    "not deterministic: \(where_)"
                )

                // The stamp decides expiry, so a stamp this build cannot read
                // is expired and a stamp inside the window is not, whatever
                // else in the snapshot was mutated.
                let stamp = parseISODate(first.data.scanned_at)
                if stamp == nil {
                    XCTAssertTrue(isScanCacheExpired(first, now: now), "unreadable stamp read as fresh: \(where_)")
                } else if stamp!.timeIntervalSince(now) >= 0, stamp!.timeIntervalSince(now) <= scanCacheMaxAge {
                    XCTAssertFalse(isScanCacheExpired(first, now: now), "a stamp inside the window read as expired: \(where_)")
                }

                try assertRoundTrips(first, where_)
                for item in first.data.leftovers {
                    let cmd = leftoverRemoveCommand(for: item)
                    XCTAssertEqual(leftoverRemoveCommand(for: item), cmd, "not deterministic: \(where_) \(item.path.debugDescription)")
                    assertQuotedArgument(cmd, contains: item.path, where_)
                    // A status this build does not know is a newer build's row:
                    // it is not listed, and nothing downstream reads it as a
                    // leftover to delete.
                    if item.leftoverStatus == nil {
                        XCTAssertFalse(item.isListedLeftover, "unknown status listed: \(where_) \(item.status.debugDescription)")
                    }
                }
                for item in first.data.software {
                    let cmd = uninstallCommand(for: item)
                    XCTAssertEqual(uninstallCommand(for: item), cmd, "not deterministic: \(where_) \(item.name.debugDescription)")
                    // A name, cask name, or package id that reads as an option
                    // is dropped where it comes from the scan, and a cached row
                    // is no different: the row is skipped, never the command.
                    for argument in [item.name, item.cask_name, item.pkg_id].compactMap({ $0 }) {
                        if !isSafeCommandArgument(argument) {
                            XCTAssertTrue(
                                cmd.hasPrefix("# skipped"),
                                "an option-shaped argument reached a manager: \(argument.debugDescription) in \(cmd.debugDescription) \(where_)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// `loadScanCache` reads for the report: a file that decodes to nothing is
    /// deleted rather than re-read on every launch, and one that decodes is
    /// left alone for the scan to overwrite.
    func testLoadDropsWhatDoesNotDecodeAndKeepsWhatDoes() throws {
        let url = scratchURL("last-scan.json")
        var rng = FuzzRandom(seed: 0x5EED_DEED)
        for base in try FuzzScanCacheTests.seedTexts() {
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng)
                let where_ = "seed \(seed): \(text.debugDescription)"
                try Data(text.utf8).write(to: url)

                let loaded = loadScanCache(from: url)
                let onDisk = FileManager.default.fileExists(atPath: url.path)
                if let loaded {
                    XCTAssertTrue(onDisk, "a snapshot that loaded was deleted: \(where_)")
                    XCTAssertEqual(
                        try canonicalJSON(try readScanCache(from: url).data),
                        try canonicalJSON(loaded.data),
                        where_
                    )
                } else {
                    XCTAssertFalse(onDisk, "a snapshot that did not decode stayed on disk: \(where_)")
                }
            }
        }
    }

    /// A file past the ceiling is refused on its size, before the decoder ever
    /// sees it, and a missing file is a miss rather than a failure.
    func testSizeCeilingAndMissingFile() throws {
        let url = scratchURL("last-scan.json")
        let cache = FuzzScanCacheTests.seedCache()
        try writeScanCache(cache, to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
        XCTAssertThrowsError(try readScanCache(from: url, maxBytes: size - 1)) { error in
            guard let io = error as? AppAtticIOError else {
                XCTFail("not a typed error: \(error)")
                return
            }
            XCTAssertFalse(io.description.isEmpty)
        }
        XCTAssertEqual(try readScanCache(from: url, maxBytes: size).fingerprint, cache.fingerprint)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(loadScanCache(from: url))
    }
}
