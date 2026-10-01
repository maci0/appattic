import XCTest

#if canImport(Glibc)
import Glibc
#endif

@testable import AppAtticScan

/// Move a file's modification date to `date`, fraction included.
///
/// `FileManager.setAttributes` cannot set a pre-1970 date that has a fraction
/// on Linux: corelibs-foundation turns the interval into whole microseconds,
/// and `Date(timeIntervalSince1970: -1.5)` arrives at `utimes` as a negative
/// `tv_usec`, which the kernel refuses with `EINVAL`, surfaced as
/// `NSFileWriteUnknownError`. The stamp is the fingerprint of exactly that kind
/// of mtime, so the test lands the date with the syscall instead of weakening
/// what it checks. The nanoseconds are the normalized form `utimensat` wants,
/// so `-1.5` is `tv_sec -2, tv_nsec 500000000`. Darwin's Foundation does this
/// conversion itself, so the ordinary call stays there.
func setModificationDate(_ date: Date, atPath path: String) throws {
    #if canImport(Glibc)
    let interval = date.timeIntervalSince1970
    let seconds = interval.rounded(.down)
    let nanos = Int32(((interval - seconds) * 1_000_000_000).rounded())
    var times = [
        timespec(tv_sec: Int(seconds), tv_nsec: Int(nanos)),
        timespec(tv_sec: Int(seconds), tv_nsec: Int(nanos)),
    ]
    guard utimensat(AT_FDCWD, path, &times, 0) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    #else
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    #endif
}

final class CacheTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1.5,
            brew_available: true,
            totals: ScanTotals(
                apps_installed: 2,
                orphaned_items: 1,
                orphaned_bytes: 10,
                system_leftover_bytes: 0,
                reclaimable_bytes: 10,
                stale_apps: 0,
                outdated_apps: 0
            ),
            leftovers: [
                LeftoverItem(
                    name: "Foo",
                    path: "/tmp/Foo",
                    root: "Caches",
                    kind: "dir",
                    status: "orphaned",
                    size_bytes: 10,
                    size_measured: true
                ),
            ],
            software: [],
            outdated: [],
            from_cache: true
        )
        try writeScanCache(ScanCacheFile(fingerprint: "fp1", includeSystem: false, data: data), to: url)
        let loaded = try XCTUnwrap(loadScanCache(from: url))
        XCTAssertEqual(loaded.fingerprint, "fp1")
        XCTAssertFalse(loaded.includeSystem)
        XCTAssertEqual(loaded.data.scanned_at, data.scanned_at)
        XCTAssertEqual(loaded.data.leftovers, data.leftovers)
        XCTAssertEqual(loaded.data.leftovers[0].name, "Foo")
        XCTAssertEqual(loaded.data.leftovers[0].path, "/tmp/Foo")
        XCTAssertEqual(loaded.data.leftovers[0].status, "orphaned")
        XCTAssertEqual(loaded.data.leftovers[0].size_bytes, 10)
        XCTAssertEqual(loaded.data.from_cache, false)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertNotEqual(mode, -1)
        XCTAssertEqual(mode & 0o077, 0)
    }

    func testStaleWhenFingerprintOrIncludeSystemOrAgeChanges() {
        let data = sampleScanData()
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        let now = parseISODate("2026-08-17T12:30:00Z")!
        XCTAssertFalse(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: now, maxAge: 3600))
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "b", now: now, maxAge: 3600))
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: true, fingerprint: "a", now: now, maxAge: 3600))
        let later = parseISODate("2026-08-18T12:30:00Z")!
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: later, maxAge: 3600))
        let clockMovedBack = parseISODate("2026-08-17T11:30:00Z")!
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: clockMovedBack, maxAge: 3600))
    }

    func testMissingCacheFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-missing-\(UUID().uuidString).json")
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertThrowsError(try readScanCache(from: url)) { error in
            guard case AppAtticIOError.readFailed = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
        }
    }

    /// A file that cannot be decoded is read in full and rejected on every
    /// launch, and a machine whose scans keep failing leaves it on disk holding
    /// the account's own paths. It is dropped instead.
    func testCorruptCacheFileIsDropped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a snapshot".utf8).write(to: url)
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The malformed strings the Swift `JSONDecoder` some Foundation versions
    /// ship trap on rather than throw for: its string unwrap is a `try!` and the
    /// scanner leaves the unescaped-control-character and invalid-UTF-8 checks
    /// to it. A cache is a file anything running as the account can write, so a
    /// key *or a value* holding either one has to come back as a dropped file
    /// and not as a dead process. `JSONSerialization` rejects both key
    /// spellings here; the value spellings are what the scan in `readScanCache`
    /// is for, since whether that serialization rejects every one of them is
    /// not something this suite can measure on Linux.
    func testCacheStringsTheDecoderWouldTrapOnAreDropped() throws {
        let inputs: [(what: String, bytes: Data)] = [
            ("a raw newline in a key", Data("{\"fingerpr\nnt\":1}".utf8)),
            ("invalid UTF-8 in a key", Data([0x7B, 0x22, 0x66, 0xFF, 0x22, 0x3A, 0x31, 0x7D])),
            ("a raw newline in a value", Data("{\"fingerprint\":\"ver:1.0.0\neval:20\"}".utf8)),
            ("a raw tab in a value", Data("{\"fingerprint\":\"ver:1.0.0\teval:20\"}".utf8)),
        ]
        for (what, bytes) in inputs {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("appattic-control-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try bytes.write(to: url)
            XCTAssertThrowsError(try readScanCache(from: url), what) { error in
                guard case AppAtticIOError.decodeFailed = error else {
                    return XCTFail("\(what): expected decodeFailed, got \(error)")
                }
            }
            XCTAssertNil(loadScanCache(from: url), what)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(what): the refused file stayed on disk"
            )
        }
    }

    /// The snapshot is a whole-inventory JSON, so its size scales with the
    /// number of rows. Past the ceiling it is not a snapshot, and reading it
    /// would take the whole file into memory before the decoder could reject it.
    func testSnapshotPastTheByteCeilingIsNotRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-oversized-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeScanCache(
            ScanCacheFile(fingerprint: "fp", includeSystem: false, data: sampleScanData()),
            to: url
        )
        XCTAssertEqual(try readScanCache(from: url).fingerprint, "fp")
        XCTAssertThrowsError(try readScanCache(from: url, maxBytes: 1)) { error in
            guard case AppAtticIOError.readFailed = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
        }
    }

    func testWriteScanCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = sampleScanData()
        try writeScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: data), to: url)
        let loaded = try readScanCache(from: url)
        XCTAssertEqual(loaded.fingerprint, "fp")
        XCTAssertEqual(loaded.data.scanned_at, data.scanned_at)
        XCTAssertEqual(loaded.data.from_cache, false)
    }

    func testWriteScanCacheRestrictsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-perm-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("appattic")
        let url = dir.appendingPathComponent("last-scan.json")
        defer { try? FileManager.default.removeItem(at: root) }
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
                outdated_apps: 0
            ),
            leftovers: [
                LeftoverItem(
                    name: "Foo",
                    path: "/home/alice/.cache/Foo",
                    root: "Caches",
                    kind: "dir",
                    status: "orphaned"
                ),
            ],
            software: []
        )
        try writeScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: data), to: url)
        let fileMode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        let dirMode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(dirMode & 0o777, 0o700)
    }

    func testFingerprintIncludesAppVersion() {
        let fp = scanFingerprint(which: { _ in nil }, run: { _, _ in (1, "", "") })
        XCTAssertTrue(fp.contains("ver:\(appAtticVersion)"), fp)
        XCTAssertTrue(fp.contains("eval:20"), fp)
        XCTAssertTrue(fp.contains("packages:1"), fp)
    }

    func testFingerprintInventoryIncludesHomeLeavesAndSystemAgents() {
        PlatformOverride.linux = false
        defer { PlatformOverride.linux = nil }
        let fp = scanFingerprint(which: { _ in nil }, run: { _, _ in (1, "", "") })
        XCTAssertTrue(fp.contains("home-.mozilla"), fp)
        XCTAssertTrue(fp.contains("launchagents-system"), fp)
        XCTAssertFalse(fp.contains("brew-f:"), fp)
        XCTAssertFalse(fp.contains("mas:"), fp)
    }

    func testUserToolDirStampsSkipsEmptyAndHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-stamps-\(UUID().uuidString)")
        let local = root.appendingPathComponent("local")
        let usr = root.appendingPathComponent("usr")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usr, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: local.appendingPathComponent("herdr"))
        try Data("x".utf8).write(to: usr.appendingPathComponent("huginn"))
        try Data("x".utf8).write(to: usr.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(
            atPath: usr.appendingPathComponent("gone").path,
            withDestinationPath: "no-such-target"
        )
        let lines = userToolDirStamps([
            ("localbin", local.path),
            ("usrlocalbin", usr.path),
            ("missing", root.appendingPathComponent("nope").path),
        ])
        XCTAssertEqual(lines, ["localbin:herdr", "usrlocalbin:gone?,huginn"])
    }

    func testDirNameStampListsNonHiddenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("herdr"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden"))
        XCTAssertEqual(dirNameStamp("localbin", dir.path), "localbin:herdr")
        XCTAssertEqual(dirNameStamp("localbin", dir.appendingPathComponent("missing").path), "")
    }

    func testInventoryEntryStampChangesWhenEntryIsUpdated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-stamp-\(UUID().uuidString)")
        let entry = dir.appendingPathComponent("Example@2.desktop")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old".utf8).write(to: entry)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: entry.path)
        let before = inventoryEntryStamp(dir: dir.path, name: entry.lastPathComponent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: entry.path)
        XCTAssertTrue(before.hasPrefix("Example\\@2.desktop@"), before)
        XCTAssertNotEqual(before, inventoryEntryStamp(dir: dir.path, name: entry.lastPathComponent))
    }

    func testFingerprintStampsWineAndBrewPrefixBin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fp-tools-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: bin.appendingPathComponent("mytool"))
        try Data("x".utf8).write(to: bin.appendingPathComponent("brew"))
        let fp = scanFingerprint(
            which: { name in
                switch name {
                case "brew": return bin.appendingPathComponent("brew").path
                case "wine": return "/usr/bin/wine"
                default: return nil
                }
            },
            run: { _, _ in (1, "", "") }
        )
        XCTAssertTrue(fp.contains("path:wine"), fp)
        XCTAssertFalse(fp.contains("path:docker"), fp)
        XCTAssertTrue(fp.contains("brewbin:brew,mytool") || fp.contains("brewbin:mytool,brew"), fp)
    }

    func testLinuxPkgStampPathsCoverNativeManagers() {
        let labels = Set(linuxPkgStampPaths(home: "/home/u", env: [:]).map(\.0))
        XCTAssertTrue(labels.contains("pacman"), "\(labels)")
        XCTAssertTrue(labels.contains("dnf"), "\(labels)")
        XCTAssertTrue(labels.contains("rpm"), "\(labels)")
        XCTAssertTrue(labels.contains("zypp"), "\(labels)")
        XCTAssertTrue(labels.contains("dpkg"), "\(labels)")
        XCTAssertTrue(labels.contains("flatpak-user"), "\(labels)")
        let paths = Dictionary(uniqueKeysWithValues: linuxPkgStampPaths(home: "/home/u", env: [:]))
        XCTAssertEqual(paths["pacman"], "/var/lib/pacman/local")
        XCTAssertEqual(paths["flatpak-user"], "/home/u/.local/share/flatpak")
        let xdg = Dictionary(uniqueKeysWithValues: linuxPkgStampPaths(
            home: "/home/u",
            env: ["XDG_DATA_HOME": "/tmp/myshare"]
        ))
        XCTAssertEqual(xdg["flatpak-user"], "/tmp/myshare/flatpak")
        XCTAssertEqual(xdg["pacman"], "/var/lib/pacman/local")
    }

    func testPathMtimeStampSkipsMissingAndRecordsMtime() throws {
        XCTAssertEqual(pathMtimeStamp("flatpak-user", "/nope/appattic-missing-flatpak"), "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtime-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = dir.appendingPathComponent("stampme")
        try Data("x".utf8).write(to: entry)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: entry.path
        )
        let line = pathMtimeStamp("flatpak-user", entry.path)
        XCTAssertFalse(line.contains("missing"), line)
        // The literal IEEE-754 bit pattern of 100.0, not the production
        // expression rebuilt here: that would agree with any value it returns.
        XCTAssertEqual(line, "flatpak-user:4636737291354636288", line)
        // Sub-second and pre-1970 mtimes must not collapse: a whole-second
        // stamp lets a package tree edited twice inside one second keep the
        // fingerprint it had before the edit, and the next run reuses a stale
        // cached scan.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100.25)],
            ofItemAtPath: entry.path
        )
        let subSecond = pathMtimeStamp("flatpak-user", entry.path)
        XCTAssertNotEqual(line, subSecond)
        try setModificationDate(Date(timeIntervalSince1970: -1.5), atPath: entry.path)
        let beforeEpoch = pathMtimeStamp("flatpak-user", entry.path)
        XCTAssertNotEqual(subSecond, beforeEpoch)
    }

    /// A rewrite inside the same second is still a change: the stamp carries
    /// sub-second precision, so the fingerprint does not miss it.
    func testPathMtimeStampDistinguishesSubSecondRewrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtime-subsecond-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.1)],
            ofItemAtPath: dir.path
        )
        let before = pathMtimeStamp("flatpak-user", dir.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.9)],
            ofItemAtPath: dir.path
        )
        XCTAssertNotEqual(before, pathMtimeStamp("flatpak-user", dir.path))
    }

    func testAndroidSdkStampWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-stamp-\(UUID().uuidString)")
        let sdk = root.appendingPathComponent("Android")
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("emulator"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(androidSdkStamp(sdkDirs: [sdk.path]), "android-sdk")
        XCTAssertEqual(androidSdkStamp(sdkDirs: [root.appendingPathComponent("empty").path]), "")
    }

    func testRootInventoryStampMovesOnNestedWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("root-stamp-\(UUID().uuidString)")
        let alpha = dir.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: alpha.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = rootInventoryStamp("Caches", dir.path)
        XCTAssertTrue(first.hasPrefix("root:Caches:Alpha"), first)
        // A write below the entry is what `applyRecentActivity` reads, so the
        // stamp has to move with it: the orphan it reported has become active.
        // The nested file is stamped into the future so the comparison against
        // the directory's own mtime does not depend on filesystem timestamp
        // granularity.
        let nested = alpha.appendingPathComponent("inner/written.txt")
        try Data("nested".utf8).write(to: nested)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: nested.path
        )
        let second = rootInventoryStamp("Caches", dir.path)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasPrefix("root:Caches:Alpha"), second)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Beta"), withIntermediateDirectories: true)
        let withBeta = rootInventoryStamp("Caches", dir.path)
        XCTAssertTrue(withBeta.contains(",Beta@"), withBeta)
        XCTAssertEqual(rootInventoryStamp("Caches", dir.appendingPathComponent("missing").path), "root:Caches:missing")
    }

    /// A root too large to walk nested is stamped `partial:`, so a stamp that
    /// did not walk cannot be read as one that did. The cutoff is on the entry
    /// count and not on a clock, so the same root is stamped the same way on
    /// every run and the two fingerprints of one scan still agree.
    func testRootInventoryStampMarksRootsTooLargeToProbe() throws {
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("root-stamp-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: big) }
        for i in 0...rootStampProbeEntries {
            try FileManager.default.createDirectory(
                at: big.appendingPathComponent("d\(i)"), withIntermediateDirectories: true
            )
        }
        let over = rootInventoryStamp("Caches", big.path)
        XCTAssertTrue(over.hasPrefix("root:Caches:partial:"), String(over.prefix(40)))
        XCTAssertEqual(over, rootInventoryStamp("Caches", big.path))
    }

    /// A root the scan never probes nested (`skipNestedRoots`) keeps the stamp
    /// it had: a nested write there cannot change any status the scan reports,
    /// so paying for the walk would buy nothing. The write lands one level
    /// below the entry, as in `testRootInventoryStampMovesOnNestedWrite`, so
    /// the entry's own mtime (which every root stamps) does not move with it.
    func testRootInventoryStampSkipsNestedForSkippedRoots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("root-stamp-skip-\(UUID().uuidString)")
        let alpha = dir.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: alpha.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let alphaMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: alpha.path)[.modificationDate] as? Date
        )
        let first = rootInventoryStamp("Containers", dir.path)
        XCTAssertEqual(first, "root:Containers:Alpha@\(alphaMtime.timeIntervalSince1970.bitPattern)", first)
        let nested = alpha.appendingPathComponent("inner/written.txt")
        try Data("nested".utf8).write(to: nested)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: nested.path
        )
        XCTAssertEqual(rootInventoryStamp("Containers", dir.path), first)
    }

    /// `commitScanCache` drops the snapshot unless the two stamps of one scan
    /// are equal, so both have to be cut from the same elapsed-time source. The
    /// nested probe inside `inventoryEntryStamp` is bounded by a clock; a stamp
    /// that reads the host's uptime instead of the injected one walks further on
    /// a loaded host than on an idle one, and the pair disagrees about a machine
    /// that did not change.
    func testInventoryEntryStampProbeReadsTheInjectedClock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-clock-\(UUID().uuidString)")
        let entry = dir.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: entry.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("nested".utf8).write(to: entry.appendingPathComponent("inner/written.txt"))
        var reads = 0
        _ = inventoryEntryStamp(dir: dir.path, name: "Alpha", includeNestedActivity: true, clock: {
            reads += 1
            return 0
        })
        XCTAssertGreaterThan(reads, 0, "the nested probe must read the injected clock, not the host's uptime")
    }

    func testRootInventoryStampForwardsTheInjectedClock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("root-stamp-clock-\(UUID().uuidString)")
        let entry = dir.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: entry.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reads = 0
        _ = rootInventoryStamp("Caches", dir.path, clock: {
            reads += 1
            return 0
        })
        XCTAssertGreaterThan(reads, 0, "rootInventoryStamp must forward its clock to the nested probe")
    }

    func testStampJoinEscapesCommaNewlineAndBang() {
        XCTAssertEqual(stampEscape("Alpha,Beta"), "Alpha\\,Beta")
        XCTAssertEqual(stampEscape("a\\b"), "a\\\\b")
        XCTAssertEqual(stampEscape("wget 1\ncurl 2"), "wget 1\\ncurl 2")
        XCTAssertEqual(stampEscape("A!5"), "A\\!5")
        XCTAssertEqual(stampJoin(["Alpha", "Beta"]), "Alpha,Beta")
        XCTAssertEqual(stampJoin(["Alpha,Beta"]), "Alpha\\,Beta")
        XCTAssertNotEqual(stampJoin(["Alpha,Beta"]), stampJoin(["Alpha", "Beta"]))
        // The nested-mtime separator cannot be spelled by a name.
        XCTAssertNotEqual(stampJoin(["A!5"]), stampJoin(["A"]) + "!5")
    }

    /// Every entry carries its own `@mtime`, so the escaped name is followed
    /// by the entry's mtime bits.
    func testRootInventoryStampEscapesCommaInName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("root-comma-\(UUID().uuidString)")
        let entry = dir.appendingPathComponent("Alpha,Beta")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: entry.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(
            rootInventoryStamp("Caches", dir.path),
            "root:Caches:Alpha\\,Beta@\(mtime.timeIntervalSince1970.bitPattern)"
        )
    }

    func testIncompleteCacheIsAlwaysStale() {
        var data = ScanData(
            scanned_at: "2026-08-17T12:00:00Z",
            duration_s: 1,
            brew_available: true,
            totals: ScanTotals(
                apps_installed: 0,
                orphaned_items: 0,
                orphaned_bytes: 0,
                system_leftover_bytes: 0,
                reclaimable_bytes: 0,
                stale_apps: 0,
                outdated_apps: 0
            ),
            leftovers: [],
            software: [],
            incomplete: true
        )
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        let now = parseISODate("2026-08-17T12:30:00Z")!
        XCTAssertTrue(isScanCacheStale(cache, includeSystem: false, fingerprint: "a", now: now, maxAge: 3600))
        data.incomplete = nil
        let complete = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        XCTAssertFalse(isScanCacheStale(complete, includeSystem: false, fingerprint: "a", now: now, maxAge: 3600))
    }

    func testIsScanCacheExpiredChecksAgeAlone() throws {
        func snapshot(_ scannedAt: String) -> ScanData {
            ScanData(
                scanned_at: scannedAt,
                duration_s: 1,
                brew_available: false,
                totals: ScanTotals(
                    apps_installed: 0,
                    orphaned_items: 0,
                    orphaned_bytes: 0,
                    system_leftover_bytes: 0,
                    reclaimable_bytes: 0,
                    stale_apps: 0,
                    outdated_apps: 0
                ),
                leftovers: [],
                software: []
            )
        }
        let data = snapshot("2026-08-17T12:00:00Z")
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: data)
        let now = parseISODate("2026-08-17T12:30:00Z")!
        XCTAssertFalse(isScanCacheExpired(cache, now: now, maxAge: 3600))
        XCTAssertTrue(
            isScanCacheExpired(cache, now: parseISODate("2026-08-17T13:30:01Z")!, maxAge: 3600)
        )
        XCTAssertTrue(
            isScanCacheExpired(cache, now: parseISODate("2026-08-17T11:30:00Z")!, maxAge: 3600)
        )
        XCTAssertTrue(
            isScanCacheExpired(
                ScanCacheFile(fingerprint: "a", includeSystem: false, data: snapshot("not a date")),
                now: now,
                maxAge: 3600
            )
        )
        // Age alone ignores the fingerprint and the scan mode, so a caller
        // that cannot stamp the inventory still gets the same bound.
        XCTAssertFalse(
            isScanCacheExpired(
                ScanCacheFile(fingerprint: "other", includeSystem: true, data: data),
                now: now,
                maxAge: 3600
            )
        )
    }

    func testCommitScanCacheSkipsWhenFingerprintMovesOrIncomplete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-commit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = sampleScanData()
        XCTAssertFalse(try commitScanCache(includeSystem: false, data: data, before: "a", after: "b", to: url))
        XCTAssertNil(loadScanCache(from: url))
        var incomplete = data
        incomplete.incomplete = true
        XCTAssertFalse(try commitScanCache(includeSystem: false, data: incomplete, before: "a", after: "a", to: url))
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertTrue(try commitScanCache(includeSystem: false, data: data, before: "a", after: "a", to: url))
        let saved = try XCTUnwrap(loadScanCache(from: url))
        XCTAssertEqual(saved.fingerprint, "a")
    }

    func testCommitScanCacheReportsWriteFailure() throws {
        let blocked = try blockedCacheParent("commit")
        let data = sampleScanData()

        XCTAssertThrowsError(try commitScanCache(
            includeSystem: false,
            data: data,
            before: "a",
            after: "a",
            to: blocked.appendingPathComponent("last-scan.json")
        )) { error in
            guard case .writeFailed(let path, _)? = error as? AppAtticIOError else {
                return XCTFail("a failed write must be .writeFailed, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("last-scan.json"), path)
        }
    }

    /// A scan that never reached disk is not a scan that was deliberately not
    /// kept, so `resolveScan` has to hand the reason back to its caller.
    func testCommitScanCacheReportsWriteFailureToResolveScan() throws {
        let blocked = try blockedCacheParent("commit-resolve")

        let resolved = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: true,
            cacheURL: blocked.appendingPathComponent("last-scan.json"),
            fingerprintFn: { "a" },
            liveScan: { _ in sampleScanData(scannedAt: "2026-08-17T13:00:00Z") }
        )
        XCTAssertFalse(resolved.fromCache)
        XCTAssertEqual(resolved.data.scanned_at, "2026-08-17T13:00:00Z")
        let failure = try XCTUnwrap(resolved.cacheWriteFailure)
        XCTAssertTrue(failure.hasPrefix("Could not write "), failure)
        XCTAssertTrue(failure.contains("last-scan.json"), failure)
    }

    /// The inventory changing while the scan ran is a different failure from a
    /// write that never landed: the scan is complete and trustworthy, the cache
    /// just cannot be stamped, so the caller is told why and nothing more.
    func testResolveScanReportsAFingerprintThatMovedUnderIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-cache-moved-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let stamps = ["a", "b"]
        var call = 0
        let resolved = resolveScan(
            includeSystem: false,
            fresh: true,
            forceLive: true,
            cacheURL: url,
            fingerprintFn: {
                defer { call += 1 }
                return stamps[min(call, stamps.count - 1)]
            },
            liveScan: { _ in sampleScanData(scannedAt: "2026-08-17T13:00:00Z") }
        )

        XCTAssertFalse(resolved.fromCache)
        XCTAssertNotEqual(
            resolved.data.incomplete, true,
            "a completed scan is complete however the cache went"
        )
        XCTAssertEqual(
            resolved.cacheWriteFailure,
            "installed software changed while the scan was running"
        )
        XCTAssertNil(loadScanCache(from: url), "a moved fingerprint must not stamp the cache")
    }

    /// A regular file standing where the cache directory must be: creating the
    /// directory fails on every platform, so the write failure is certain
    /// rather than a race with `rename` semantics.
    private func blockedCacheParent(_ tag: String) throws -> URL {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-blocker-\(tag)-\(UUID().uuidString)")
        try Data().write(to: blocker)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocker) }
        return blocker
    }

    func testClearScanCacheRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = sampleScanData()
        try writeScanCache(ScanCacheFile(fingerprint: "fp", includeSystem: false, data: data), to: url)
        XCTAssertNotNil(loadScanCache(from: url))
        // True while nothing is left at the path, which covers a file taken and
        // a file that was never there: a caller that purges the snapshot must
        // not warn that a stale inventory might survive on a machine that has
        // none. A removal that did not land is still false, so the two cases a
        // caller acts on are still told apart.
        XCTAssertTrue(clearScanCache(at: url))
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertTrue(clearScanCache(at: url), "nothing was there to keep")
        XCTAssertFalse(try eraseScanCache(at: url), "nothing was there to erase")
    }

    /// The purge reports on what is left at the path, so a removal that cannot
    /// land is false: the snapshot is a full inventory of the account's paths,
    /// and a file that survived a purge has to be named rather than read as a
    /// clean one. `fileExists` stats the path, so it answers true here and the
    /// call under test really does reach `removeItem` rather than returning on
    /// the absent-file guard.
    ///
    /// The parent directory is read-and-execute only, so the unlink is refused
    /// with `EACCES`, which no uid can bypass: root's `CAP_DAC_OVERRIDE` drops
    /// to a directory's own execute bit here, and the suite has to hold under
    /// a root run. Restored in teardown, before the directory is taken, so a
    /// failed assertion cannot strand the next test's tmp.
    func testClearScanCacheIsFalseWhenARemovalDoesNotLand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-clear-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("last-scan.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: url)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        addTeardownBlock {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        XCTAssertFalse(clearScanCache(at: url), "the snapshot survived the purge")
        XCTAssertTrue(fm.fileExists(atPath: url.path), "the snapshot is still on disk")
    }

    /// The cache is a full inventory of the account's paths, so a snapshot past
    /// the retention bound is deleted instead of kept, and a fresh one is not.
    func testDeleteExpiredScanCacheRemovesOnlyPastTheRetentionBound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-expire-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = parseISODate("2026-08-17T12:30:00Z")!
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: sampleScanData())

        try writeScanCache(cache, to: url)
        XCTAssertFalse(deleteExpiredScanCache(cache, now: now, maxAge: 3600, at: url))
        XCTAssertNotNil(loadScanCache(from: url))

        // A fingerprint mismatch is not a retention reason: the snapshot is one
        // rescan away from usable, and it is the only copy when a scan races an
        // install and `commitScanCache` refuses to write over it.
        XCTAssertFalse(deleteExpiredScanCache(cache, now: now, maxAge: 3600, at: url))
        XCTAssertNotNil(loadScanCache(from: url))

        let later = parseISODate("2026-08-20T12:30:00Z")!
        XCTAssertTrue(deleteExpiredScanCache(cache, now: later, maxAge: 3600, at: url))
        XCTAssertNil(loadScanCache(from: url))
    }

    /// An expired snapshot is purged on launch, and the purge is checked there:
    /// the snapshot is the account's whole path inventory, so a removal that
    /// did not land has to be reportable rather than a discarded return value.
    func testExpiredSnapshotPurgeIsTrueWhenNothingIsLeft() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = parseISODate("2026-08-20T12:30:00Z")!
        let cache = ScanCacheFile(fingerprint: "a", includeSystem: false, data: sampleScanData())

        try writeScanCache(cache, to: url)
        XCTAssertTrue(isScanCacheExpired(cache, now: now))
        XCTAssertTrue(deleteExpiredScanCache(cache, now: now, maxAge: 3600, at: url))
        // A launch that found the file already gone is not a purge that failed,
        // so the second purge says so instead of producing a spurious warning.
        XCTAssertTrue(clearScanCache(at: url))
    }

    /// An erase is the user asking for the account's own paths to leave the
    /// disk now, so it deletes a snapshot of any age and never reads it first.
    /// A snapshot that was already gone is the wanted state, not a failure.
    func testEraseScanCacheRemovesASnapshotOfAnyAge() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-erase-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let fresh = sampleScanData(scannedAt: "2026-08-20T12:29:00Z")
        try writeScanCache(ScanCacheFile(fingerprint: "a", includeSystem: false, data: fresh), to: url)
        XCTAssertNotNil(loadScanCache(from: url))

        XCTAssertTrue(try eraseScanCache(at: url))
        XCTAssertNil(loadScanCache(from: url))
        XCTAssertFalse(try eraseScanCache(at: url))
    }

    /// A scan that finds a snapshot past the retention bound rescans live and
    /// leaves the fresh one, not the expired inventory, on disk.
    func testResolveScanReplacesExpiredCacheWithTheLiveScan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-resolve-expired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = parseISODate("2026-08-20T12:30:00Z")!
        try writeScanCache(
            ScanCacheFile(fingerprint: "old", includeSystem: false, data: sampleScanData()),
            to: url
        )
        let live = sampleScanData(scannedAt: "2026-08-20T12:29:00Z")
        let result = resolveScan(
            includeSystem: false,
            fresh: false,
            forceLive: false,
            cacheURL: url,
            now: now,
            fingerprintFn: { "old" },
            liveScan: { _ in live }
        )
        XCTAssertFalse(result.fromCache)
        XCTAssertEqual(result.data.scanned_at, live.scanned_at)
        let saved = try XCTUnwrap(loadScanCache(from: url))
        XCTAssertEqual(saved.data.scanned_at, live.scanned_at)
    }

    /// `duration_s` is a `Double`, so a `"duration_s": 1e999` in
    /// `last-scan.json` decodes to an infinity and a negative one decodes as
    /// itself. `JSON` spells neither: `JSONEncoder` throws on a non-finite
    /// value rather than writing it, so one such number failed the whole
    /// `--json` report, and a negative one showed as a scan that took less
    /// than no time.
    func testNonFiniteCachedDurationDoesNotReachTheReport() throws {
        func snapshot(_ duration: Double) -> ScanData {
            ScanData(
                scanned_at: "2026-08-17T12:00:00Z",
                duration_s: duration,
                brew_available: false,
                totals: ScanTotals(
                    apps_installed: 0,
                    orphaned_items: 0,
                    orphaned_bytes: 0,
                    system_leftover_bytes: 0,
                    reclaimable_bytes: 0,
                    stale_apps: 0,
                    outdated_apps: 0
                ),
                leftovers: [],
                software: []
            )
        }
        for bad in [Double.infinity, -Double.infinity, Double.nan, -3.5] {
            let result = scanResult(from: snapshot(bad))
            XCTAssertEqual(result.durationS, 0)
            XCTAssertEqual(result.toScanData().duration_s, 0)
            XCTAssertNoThrow(try JSONEncoder().encode(result.toScanData()))
        }
        // A real duration still rounds to one decimal rather than being dropped.
        XCTAssertEqual(scanResult(from: snapshot(1.25)).toScanData().duration_s, 1.3)
        XCTAssertEqual(scanResult(from: snapshot(0.04)).toScanData().duration_s, 0)
    }

    /// A fingerprint has to be a statement about the machine as it is now, not
    /// about the toolchain list an earlier scan left behind. The macOS window
    /// stamps once at launch and once before every rescan, and only the rescan
    /// used to rebuild the list the default `which` walks, so a tool directory
    /// installed in between was invisible to the stamp that decided whether the
    /// snapshot was still current.
    func testScanFingerprintRebuildsTheSearchListEveryTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        resetWhichSearchDirectories()
        // Warm the list the way a launch does, then stamp again. With the
        // fingerprint rebuilding the list, both stamps are made against the
        // machine as it is and they agree; the count pins that the lookups ran
        // rather than being answered from a list the first stamp left cached.
        var lookups = 0
        func stamp() -> String {
            lookups = 0
            return scanFingerprint(
                which: { _ in
                    lookups += 1
                    return nil
                },
                run: { _, _ in (1, "", "") },
                fileStamps: { [rootInventoryStamp("fixture", root.path)] }
            )
        }
        let first = stamp()
        let afterFirst = lookups
        let second = stamp()
        XCTAssertEqual(first, second, "a stamp must not depend on a list an earlier one cached")
        XCTAssertGreaterThan(afterFirst, 0, "the injected which must actually have been called")
        try Data("changed".utf8).write(to: root.appendingPathComponent("app"))
        XCTAssertNotEqual(first, stamp(), "a change in the injected inventory must change the stamp")
    }
}
