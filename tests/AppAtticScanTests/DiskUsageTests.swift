import XCTest
@testable import AppAtticScan

final class DiskUsageTests: XCTestCase {
    func testScanCountsFilesAndDoesNotFollowDirectorySymlink() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("disk-\(UUID().uuidString)")
        let big = td.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let payload = Data(repeating: 0x78, count: 4096)
        try payload.write(to: big.appendingPathComponent("a.bin"))
        try Data("hi\n".utf8).write(to: td.appendingPathComponent("small.txt"))
        try FileManager.default.createSymbolicLink(
            at: td.appendingPathComponent("linkdir"),
            withDestinationURL: big
        )

        let tree = scanDiskUsage(root: td.path, oneFileSystem: true)
        XCTAssertFalse(tree.unreadable)
        let byName = Dictionary(uniqueKeysWithValues: tree.children.map { ($0.name, $0) })
        XCTAssertNotNil(byName["big"])
        XCTAssertTrue(byName["big"]!.isDir)
        XCTAssertGreaterThanOrEqual(byName["big"]!.apparent, 4096)
        XCTAssertNotNil(byName["small.txt"])
        XCTAssertFalse(byName["small.txt"]!.isDir)
        XCTAssertGreaterThanOrEqual(byName["small.txt"]!.apparent, 3)
        XCTAssertNotNil(byName["linkdir"])
        XCTAssertFalse(byName["linkdir"]!.isDir, "directory symlink must not be descended")
        XCTAssertGreaterThanOrEqual(tree.items, 3)
        tree.sortChildren(allocatedSize: false)
        XCTAssertEqual(tree.children.first?.name, "big")
    }

    func testDecodeDirentNameRejectsBytesThatAreNotUTF8() {
        // A POSIX name may hold any byte but NUL and `/`. Decoding 0xff with a
        // lossy decoder yields a U+FFFD, whose re-encoded bytes name a different
        // file, so the walk must refuse the entry instead of misattributing it.
        let bad: [UInt8] = [0x63, 0x61, 0x66, 0xff, 0x65, 0x00]
        let badName = bad.withUnsafeBytes { decodeDirentName($0) }
        XCTAssertNil(badName)

        let truncated: [UInt8] = [0x63, 0x61, 0x66, 0xc3]
        let truncatedName = truncated.withUnsafeBytes { decodeDirentName($0) }
        XCTAssertNil(truncatedName)
    }

    func testDecodeDirentNameKeepsValidUTF8AndStopsAtNUL() {
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xc3, 0xa9, 0x00, 0x6a, 0x75, 0x6e, 0x6b]
        let decoded = bytes.withUnsafeBytes { decodeDirentName($0) }
        XCTAssertEqual(decoded, "café")

        let ascii: [UInt8] = Array("notes.txt".utf8)
        let plain = ascii.withUnsafeBytes { decodeDirentName($0) }
        XCTAssertEqual(plain, "notes.txt")
    }

    /// Equal-size children fall back to the name. Byte order would put "Über"
    /// and every CJK name after all ASCII ones; collation orders by letter.
    func testSortChildrenTieBreaksOnLocaleCollation() {
        let root = DiskUsageNode(name: "root", path: "/tmp/root", apparent: 300, allocated: 300, isDir: true)
        root.children = [
            DiskUsageNode(name: "Über", path: "/tmp/root/Über", apparent: 100, allocated: 100),
            DiskUsageNode(name: "apple", path: "/tmp/root/apple", apparent: 100, allocated: 100),
            DiskUsageNode(name: "Zebra", path: "/tmp/root/Zebra", apparent: 100, allocated: 100),
        ]
        root.sortChildren(allocatedSize: false)
        let names = root.children.map(\.name)
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(
            names,
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    func testFormatDiskTreeListsLargestFirst() {
        let root = DiskUsageNode(name: "root", path: "/tmp/root", apparent: 100, allocated: 200, isDir: true)
        root.children = [
            DiskUsageNode(name: "small", path: "/tmp/root/small", apparent: 10, allocated: 10),
            DiskUsageNode(name: "large", path: "/tmp/root/large", apparent: 90, allocated: 90, isDir: true),
        ]
        root.sortChildren(allocatedSize: false)
        let text = formatDiskTree(root, allocatedSize: false, top: 1)
        XCTAssertTrue(text.contains("root  \(humanSize(100))"), text)
        XCTAssertTrue(text.contains("large"), text)
        XCTAssertFalse(text.contains("small"), text)
    }

    func testHiddenEntriesCountWhatTheTopSliceDrops() {
        let root = DiskUsageNode(name: "root", path: "/tmp/root", apparent: 100, allocated: 100, isDir: true)
        let shown = DiskUsageNode(name: "shown", path: "/tmp/root/shown", apparent: 50, allocated: 50, isDir: true)
        let hidden = DiskUsageNode(name: "hidden", path: "/tmp/root/hidden", apparent: 40, allocated: 40, isDir: true)
        // 3 children of the hidden subtree, none of which the tree would print.
        hidden.children = (0..<3).map {
            DiskUsageNode(name: "h\($0)", path: "/tmp/root/hidden/h\($0)", apparent: 1, allocated: 1)
        }
        root.children = [shown, hidden, DiskUsageNode(name: "third", path: "/tmp/root/third", apparent: 1)]
        XCTAssertEqual(diskTreeHiddenEntries(root, top: 1), 2)
        XCTAssertEqual(diskTreeHiddenEntries(root, top: 5), 0)
        XCTAssertEqual(diskTreeHiddenEntries(root, top: 0), 3)
    }

    func testDiskJSONRoundTripFields() throws {
        let node = DiskUsageNode(name: "a", path: "/a", apparent: 4, allocated: 8, items: 2, isDir: true)
        node.children = [DiskUsageNode(name: "b", path: "/a/b", apparent: 4, allocated: 8)]
        let data = try diskUsageJSON(node)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "a")
        XCTAssertEqual(obj["apparent"] as? Int, 4)
        XCTAssertEqual(obj["allocated"] as? Int, 8)
        let kids = try XCTUnwrap(obj["children"] as? [[String: Any]])
        XCTAssertEqual(kids.first?["name"] as? String, "b")
    }

    /// The streaming writer replaced a `[String: Any]` tree + `JSONSerialization`.
    /// Same parsed value, including quoting, escapes, and awkward integers.
    func testDiskUsageJSONMatchesJSONSerializationReference() throws {
        func reference(_ n: DiskUsageNode) -> [String: Any] {
            [
                "name": n.name,
                "path": n.path,
                "apparent": n.apparent,
                "allocated": n.allocated,
                "items": n.items,
                "isDir": n.isDir,
                "unreadable": n.unreadable,
                "mountPoint": n.mountPoint,
                "children": n.children.map { reference($0) },
            ]
        }

        let root = DiskUsageNode(
            name: "od\"d\\name\nline\ttab",
            path: "/tmp/\u{1F600}\u{7}bell",
            apparent: Int.max,
            allocated: 0,
            items: 3,
            mtime: nil,
            isDir: true,
            unreadable: true,
            mountPoint: true
        )
        root.children = [
            DiskUsageNode(name: "", path: "/tmp/empty", apparent: -5, allocated: 1024, items: -1),
            DiskUsageNode(name: "\u{4}\u{8}\u{0C}\r", path: "/tmp/ctrl", apparent: 1, allocated: 2, isDir: true),
            DiskUsageNode(name: "leaf", path: "/tmp/leaf", apparent: 7, allocated: 9),
        ]

        let got = try XCTUnwrap(JSONSerialization.jsonObject(with: diskUsageJSON(root)) as? [String: Any])
        let want = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: reference(root), options: [.prettyPrinted, .sortedKeys])
            ) as? [String: Any]
        )
        XCTAssertEqual(NSDictionary(dictionary: got), NSDictionary(dictionary: want))
        XCTAssertEqual(got["apparent"] as? Int, Int.max, "Int.max must survive the digit buffer")
    }

    func testValidateDiskRootRejectsMissingPathAndFile() throws {
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: td) }
        let file = td.appendingPathComponent("a.txt")
        try Data("hi\n".utf8).write(to: file)

        XCTAssertNoThrow(try validateDiskRoot(td.path))
        let missing = td.appendingPathComponent("nope").path
        XCTAssertThrowsError(try validateDiskRoot(missing)) { error in
            XCTAssertEqual(error as? DiskRootError, .missing(path: missing))
            XCTAssertEqual(error.localizedDescription, "no such directory: \(missing)")
        }
        XCTAssertThrowsError(try validateDiskRoot(file.path)) { error in
            XCTAssertEqual(error as? DiskRootError, .notADirectory(path: file.path))
            XCTAssertEqual(error.localizedDescription, "not a directory: \(file.path)")
        }
    }

    /// `appattic disk` defaults to the account home, so a typo there printed
    /// the account name to stderr before the message was redacted.
    func testDiskRootErrorRedactsTheAccountHome() {
        let home = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        guard home.count > 1, home.contains("/") else { return }
        let missing = DiskRootError.missing(path: home + "/nope")
        XCTAssertEqual(missing.description, "no such directory: ~/nope")
        XCTAssertFalse(missing.description.contains(home), missing.description)
    }

    #if os(Linux)
    // `mountsText` is the /proc/mounts reader's injection point; the macOS
    // branch lists mounted volumes through FileManager and ignores it.
    func testListDiskVolumesSkipsProc() {
        let mounts = """
        /dev/sda1 / ext4 rw 0 0
        proc /proc proc rw 0 0
        /dev/sda2 /home ext4 rw 0 0
        """
        let vols = listDiskVolumes(home: "/home/u", mountsText: mounts)
        XCTAssertTrue(vols.contains { $0.isRoot && $0.rootPath == "/" })
        XCTAssertFalse(vols.contains { $0.rootPath == "/proc" })
        XCTAssertTrue(vols.contains { $0.rootPath == "/home" && $0.isHome })
    }

    func testListDiskVolumesUnescapesOctalInMountPoint() {
        // The kernel escapes space, tab, newline, and backslash as octal.
        let mounts = """
        /dev/sda1 / rw ext4 rw 0 0
        /dev/sdb1 /mnt/my\\040disk ext4 rw 0 0
        /dev/sdc1 /mnt/back\\134slash ext4 rw 0 0
        """
        let vols = listDiskVolumes(home: "/home/u", mountsText: mounts)
        XCTAssertTrue(vols.contains { $0.rootPath == "/mnt/my disk" })
        XCTAssertTrue(vols.contains { $0.rootPath == "/mnt/back\\slash" })
    }
    #endif
}
