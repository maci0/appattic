import XCTest
@testable import AppAtticScan

// Fixed differential corpus: old split/trim implementations vs the byte scans.
// Guards the tricky edges (whitespace-only tab fields, single-token leaders,
///mid-list "name" rows, 5+ column tails).
final class ParserParityTests: XCTestCase {
    func testFlatpakWhitespaceOnlyTabFields() {
        // Old `filter { !$0.isEmpty }` kept `" "` as a positional placeholder.
        let rows = parseFlatpakUpdates("5.0.8\t \tS\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "5.0.8")
        XCTAssertEqual(rows[0].latestVersion, "")
        XCTAssertEqual(rows[0].title, "S")
        // 5+ tab fields fold into the summary with "\t", empties dropped.
        let wide = parseFlatpakUpdates("k\tv\tt\ta\t\tb\n")
        XCTAssertEqual(wide[0].summary, "a\tb")
        // Leading whitespace trims off, leaving a version-less row.
        XCTAssertEqual(parseFlatpakUpdates("\t \tv\n").map(\.name), ["v"])
    }

    func testSnapHeaderOnlySkipsFirstLine() {
        // Single-token leaders must not shift the header check onto row 3.
        let pkgs = parseSnapRefreshList("APPLICATION\nv\nname     rc\n--\t2.43.0-1.1\t|\twarning:\n")
        let byName = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.name, $0.latestVersion) })
        XCTAssertEqual(byName["name"], "rc")
        XCTAssertEqual(byName["--"], "2.43.0-1.1")
        // Header on line 1 still skips; notice still empties.
        XCTAssertEqual(parseSnapRefreshList("Name\na 1.0\n").map(\.name), ["a"])
        XCTAssertTrue(parseSnapRefreshList("All snaps up to date.\n").isEmpty)
        // A package literally named "all" is data, not the notice.
        XCTAssertEqual(parseSnapRefreshList("all 1.0\nsnaps 2.0\n").count, 2)
    }

    func testZypperSeparatorsAndStatus() {
        let text = "S | Repository | Name | Current Version | Available Version | Arch\n--+--+--+--+--\nv | Update | git | 2.43.0-1.1 | 2.45.1-1.1 | x86_64\ns | Update | skipme | 1 | 2 | x86_64\n"
        let pkgs = parseZypperListUpdates(text)
        XCTAssertEqual(pkgs.map(\.name), ["git"])
        XCTAssertEqual(pkgs[0].latestVersion, "2.45.1-1.1")
        let unn = parseZypperUnneeded("i | libfoo | package | 1.2.3-1 | x86_64 | repo\n")
        XCTAssertEqual(unn.map(\.name), ["libfoo"])
    }

    func testDpkgRcAndOrphansDiagnostics() {
        XCTAssertEqual(parseDpkgRc("rc  oldpkg  1.0-1  amd64  leftover\n").map(\.name), ["oldpkg"])
        XCTAssertTrue(parseDpkgRc("rcx foo 1.0\n").isEmpty)
        let orphans = parsePacmanOrphans("error: failed\nwarning: x\nlibfoo 1.2.3-1\nbare\n")
        XCTAssertEqual(orphans.map(\.name), ["libfoo", "bare"])
        XCTAssertEqual(parseDnfUnneeded("Packages\nlibfoo\n").map(\.name), ["libfoo"])
    }
}
