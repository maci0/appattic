import XCTest
@testable import AppAtticScan

// Bucket collapsing walks dictionaries and sets, so an unsorted read picks a
// different survivor on every process (Swift seeds hashing per run). These
// pin the tie-breaks that make the choice reproducible.
final class GroupingDeterminismTests: XCTestCase {
    private func item(_ name: String, key: String, size: Int = 0) -> DataItem {
        DataItem(
            path: "/Users/x/Library/Caches/\(key)/\(name)",
            name: name,
            rootLabel: "Caches",
            kind: "dir",
            status: "orphaned",
            sizeBytes: size
        )
    }

    func testVendorPrefixCollapseKeepsLargestBucket() {
        var buckets: [String: [DataItem]] = [
            "com.acme.alpha": [item("com.acme.alpha", key: "com.acme.alpha", size: 10)],
            "com.acme.beta": [item("com.acme.beta", key: "com.acme.beta", size: 90)],
        ]
        collapseVendorPrefixBuckets(&buckets)
        XCTAssertEqual(buckets.keys.sorted(), ["com.acme.beta"])
        XCTAssertEqual(buckets["com.acme.beta"]?.count, 2)
    }

    func testVendorPrefixCollapseBreaksEqualSizeTiesByKey() {
        var buckets: [String: [DataItem]] = [
            "com.acme.beta": [item("com.acme.beta", key: "com.acme.beta", size: 10)],
            "com.acme.alpha": [item("com.acme.alpha", key: "com.acme.alpha", size: 10)],
        ]
        collapseVendorPrefixBuckets(&buckets)
        XCTAssertEqual(buckets.keys.sorted(), ["com.acme.alpha"])
        XCTAssertEqual(buckets["com.acme.alpha"]?.count, 2)
    }

    func testBundleIdChildCollapseBreaksEqualLengthParentTieByKey() {
        var buckets: [String: [DataItem]] = [
            "aaa-parent": [item("com.acme.alpha", key: "aaa-parent")],
            "zzz-parent": [item("com.acme.alpha", key: "zzz-parent")],
            "child": [item("com.acme.alpha.beta", key: "child")],
        ]
        collapseBundleIdChildBuckets(&buckets)
        XCTAssertEqual(buckets.keys.sorted(), ["aaa-parent", "zzz-parent"])
        XCTAssertEqual(buckets["aaa-parent"]?.count, 2)
        XCTAssertNil(buckets["child"])
    }

    func testPreferredBrokenLinkNameIgnoresInputOrder() {
        // Equal-length names with no tool-folder hit: the old last-max read
        // returned whichever of the two the directory happened to list first.
        XCTAssertEqual(
            preferredBrokenLinkName(["zeta", "abcd"], toolFolder: "tool"),
            preferredBrokenLinkName(["abcd", "zeta"], toolFolder: "tool")
        )
        XCTAssertEqual(
            preferredBrokenLinkName(["zeta", "abcd"], toolFolder: "tool"),
            "abcd"
        )
    }

    func testPreferredBrokenLinkNamePrefersShortestVariantPrefix() {
        XCTAssertEqual(
            preferredBrokenLinkName(["mini-agent-pro", "mini-agent"], toolFolder: "agent"),
            "mini-agent"
        )
    }

    func testPreferredBrokenLinkNamePrefersToolFolderName() {
        XCTAssertEqual(
            preferredBrokenLinkName(["node-20", "node"], toolFolder: "node"),
            "node"
        )
    }
}
