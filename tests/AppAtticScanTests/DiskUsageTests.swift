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
    #endif
}
