import XCTest
@testable import AppAtticScan

/// The search-box predicates behind every list page's filter. They lived in
/// the macOS UI's view model and the Packages filter alone, so the other three
/// rows had no test outside the process that renders them.
final class SearchTests: XCTestCase {
    private func leftover(
        _ name: String,
        path: String = "/tmp/Foo",
        root: String = "Caches",
        status: String = "orphaned",
        owner: String? = nil,
        reason: String? = nil,
        summary: String? = nil,
        shadows: String? = nil,
        extraPaths: [String]? = nil
    ) -> LeftoverItem {
        LeftoverItem(
            name: name,
            path: path,
            root: root,
            kind: "dir",
            status: status,
            owner: owner,
            reason: reason,
            summary: summary,
            shadows: shadows,
            extra_paths: extraPaths
        )
    }

    private func software(
        _ name: String,
        path: String = "/Applications/Foo.app",
        source: String = "brew",
        tier: String? = nil,
        reason: String? = nil,
        summary: String? = nil,
        outdated: Bool? = nil
    ) -> SoftwareItem {
        SoftwareItem(
            name: name,
            kind: "app",
            path: path,
            source: source,
            tier: tier,
            reason: reason,
            summary: summary,
            outdated: outdated
        )
    }

    func testEmptyQueryIsNilAndMatchesEveryRow() {
        XCTAssertNil(searchQuery(""))
        let q = searchQuery("")
        XCTAssertTrue(leftoverMatchesSearch(leftover("Anything"), q))
        XCTAssertTrue(softwareMatchesSearch(software("Anything"), q))
        XCTAssertTrue(outdatedMatchesSearch(OutdatedEntry(name: "A", manager: "brew"), q))
    }

    func testWhitespaceQueryStillFiltersRatherThanMatchingEverything() {
        // The pages these predicates replaced skipped the row test only when
        // the folded query was empty, so a space is a real query. Dropping it
        // here would silently turn "type a space" into "show everything".
        XCTAssertEqual(searchQuery(" "), " ")
        XCTAssertFalse(leftoverMatchesSearch(leftover("Firefox"), searchQuery(" ")))
        XCTAssertTrue(leftoverMatchesSearch(leftover("Firefox", reason: "no bundle id"), searchQuery(" ")))
    }

    func testLeftoverMatchesOnEveryFieldTheRowShows() {
        let item = leftover(
            "Firefox",
            path: "/Users/u/Library/Caches/Firefox",
            root: "Caches",
            owner: "u",
            reason: "no bundle id",
            summary: "app data",
            shadows: "/opt/homebrew/bin/firefox",
            extraPaths: ["/Users/u/Library/Saved App State"]
        )
        for query in [
            "firefox",                    // name
            "Library/Caches",             // path
            "Caches",                     // root
            "orphaned",                   // status
            "bundle",                     // owner/reason
            "app data",                   // summary
            "homebrew",                   // shadows
            "Saved App State",            // extra path
        ] {
            XCTAssertTrue(leftoverMatchesSearch(item, searchQuery(query)), query)
        }
        XCTAssertFalse(leftoverMatchesSearch(item, searchQuery("whisky")))
    }

    func testSoftwareMatchesTheOutdatedFlagAsAPrefix() {
        let flagged = software("Orca", outdated: true)
        XCTAssertTrue(softwareMatchesSearch(flagged, searchQuery("outdat")))
        XCTAssertTrue(softwareMatchesSearch(flagged, searchQuery("outdated")))
        // A row not flagged must not answer the same query.
        XCTAssertFalse(softwareMatchesSearch(software("Orca"), searchQuery("outdated")))
    }

    func testSoftwareAndOutdatedMatchTheirOwnFields() {
        let sw = software("Orca", source: "steam", tier: "review", reason: "idle")
        for query in ["orca", "Applications", "steam", "review", "idle"] {
            XCTAssertTrue(softwareMatchesSearch(sw, searchQuery(query)), query)
        }
        let entry = OutdatedEntry(
            name: "wget", manager: "brew", title: "wget", summary: "1.21 -> 1.24", reason: "brew"
        )
        for query in ["wget", "brew", "1.21"] {
            XCTAssertTrue(outdatedMatchesSearch(entry, searchQuery(query)), query)
        }
        XCTAssertFalse(outdatedMatchesSearch(entry, searchQuery("whisky")))
    }

    func testSearchFoldsAnNFDNameAgainstAnNFCQuery() {
        // macOS reports filenames in NFD; the search box takes NFC. The same
        // rule `filterPackages` already pins for the Packages page.
        let nfd = leftover("Cafe\u{0301}")
        XCTAssertTrue(leftoverMatchesSearch(nfd, searchQuery("café")))
        XCTAssertTrue(leftoverMatchesSearch(nfd, searchQuery("CAFÉ")))
    }

    func testPackagesSearchStillFoldsTheSameWay() {
        // Guards the extraction in `filterPackages`: it now folds through
        // `searchQuery`, so this pins that the Packages page is unchanged.
        let rows = [
            PackageEntry(
                name: "libCafe\u{0301}", manager: "apt", kind: "orphan",
                size_bytes: 10, size_measured: true
            ),
        ]
        XCTAssertEqual(filterPackages(rows, filter: .all, search: "café").map(\.name), ["libCafe\u{0301}"])
        XCTAssertEqual(filterPackages(rows, filter: .all, search: "CAFÉ").map(\.name), ["libCafe\u{0301}"])
        XCTAssertEqual(filterPackages(rows, filter: .all, search: "").map(\.name), ["libCafe\u{0301}"])
    }
}