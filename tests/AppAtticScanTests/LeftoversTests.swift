import XCTest
@testable import AppAtticScan

/// The identity predicates decide whether a directory under a shared support
/// root belongs to "system" or to an installed app. A false accept hides a
/// real leftover; a false reject offers to delete something the OS still needs.
/// Each case below is one side of the documented pattern.
final class LeftoversTests: XCTestCase {
    func testIsBundleIdAcceptsLowercaseDottedIdentifiers() {
        XCTAssertTrue(isBundleId("com.apple.safari"))
        XCTAssertTrue(isBundleId("org.mozilla.firefox"))
        XCTAssertTrue(isBundleId("io.github.kde.konsole"))
        XCTAssertTrue(isBundleId("a.b"), "one-char segments still make a dotted id")
        XCTAssertTrue(isBundleId("1.2"))
        XCTAssertTrue(isBundleId("com.my-company.my_app"))
        XCTAssertTrue(isBundleId("com._leading_underscore.is.allowed.after.the.first.dot"))
    }

    func testIsBundleIdRejectsWhatItMustNotOwn() {
        XCTAssertFalse(isBundleId("com"), "a bare word is a display name, not an id")
        XCTAssertFalse(isBundleId("com."), "a trailing dot leaves an empty segment")
        XCTAssertFalse(isBundleId(".com"), "a leading dot leaves an empty first segment")
        XCTAssertFalse(isBundleId("com..apple"), "an interior empty segment is not an id")
        XCTAssertFalse(isBundleId("com_foo.bar"), "the first segment is [a-z0-9]+ with no separator")
        XCTAssertFalse(isBundleId("com-foo.bar"))
        XCTAssertFalse(isBundleId("com.Firefox"), "the pattern is lowercase; callers pass lowercased input")
        XCTAssertFalse(isBundleId("ab"), "needs at least one dot, so 2 characters cannot qualify")
        XCTAssertFalse(isBundleId("com apple"))
        XCTAssertFalse(isBundleId("com.apple/x"))
        XCTAssertFalse(isBundleId(""))
    }

    func testIsDaemonNameMatchesTheDaemonPattern() {
        XCTAssertTrue(isDaemonName("loginwindowd"))
        XCTAssertTrue(isDaemonName("syspolicyd"))
        XCTAssertTrue(isDaemonName("diskarbitrationd"))
        XCTAssertTrue(isDaemonName("a1234567d"), "9 alnum between the lead and the trailing d")
    }

    func testIsDaemonNameRejectsShortUppercaseAndDottedNames() {
        XCTAssertFalse(isDaemonName("a123456d"), "9 characters is below the length floor")
        XCTAssertFalse(isDaemonName("syspolicy"), "no trailing d")
        XCTAssertFalse(isDaemonName("Syspolicyd"), "the pattern is lowercase")
        XCTAssertFalse(isDaemonName("syspolicy-d"))
        XCTAssertFalse(isDaemonName("com.apple.coreservicesd"), "a dotted reverse name is not a launchd label")
        XCTAssertFalse(isDaemonName(""))
    }

    func testIsTeamIdRequiresEightToTwelveAlnumWithADigit() {
        XCTAssertTrue(isTeamId("ABCDE123"))
        XCTAssertTrue(isTeamId("a1b2c3d4"))
        XCTAssertTrue(isTeamId("12345678"), "digits satisfy the lookahead on their own")
        XCTAssertTrue(isTeamId("ABCDEFGH1234"), "12 characters is the upper bound")
    }

    func testIsTeamIdRejectsWrongLengthMissingDigitAndPunctuation() {
        XCTAssertFalse(isTeamId("ABCDE12"), "7 characters is below the lower bound")
        XCTAssertFalse(isTeamId("ABCDEFGHIJKL1"), "13 characters is above the upper bound")
        XCTAssertFalse(isTeamId("ABCDEFGH"), "no digit, so the lookahead fails")
        XCTAssertFalse(isTeamId("ABC-12345"))
        XCTAssertFalse(isTeamId("ABCDEFG1 "))
        XCTAssertFalse(isTeamId(""))
    }

    func testIsUUIDAcceptsBothHexCases() {
        XCTAssertTrue(isUUID("123E4567-E89B-12D3-A456-426614174000"))
        XCTAssertTrue(isUUID("123e4567-e89b-12d3-a456-426614174000"))
        XCTAssertTrue(isUUID("00000000-0000-0000-0000-000000000000"))
    }

    func testIsUUIDRejectsWrongLengthShapeAndNonHex() {
        XCTAssertFalse(isUUID("123E4567-E89B-12D3-A456-42661417400"), "35 characters")
        XCTAssertFalse(isUUID("123E4567-E89B-12D3-A456-4266141740000"), "37 characters")
        XCTAssertFalse(isUUID("123E4567E89B12D3A456426614174000"), "dashes are required")
        XCTAssertFalse(isUUID("123E45678-E89B-12D3-A456-426614174000"), "hyphen positions are fixed")
        XCTAssertFalse(isUUID("123E4567-E89B-12D3-A456-42661417400G"), "G is not a hex digit")
        XCTAssertFalse(isUUID("G23E4567-E89B-12D3-A456-426614174000"), "the first group is hex too")
        XCTAssertFalse(isUUID(""))
    }

    func testOrphanedBySizeBreaksEqualSizeOnPath() {
        // Two leftovers of the same size used to swap places between processes,
        // which changed the report order and the `--top N` cut.
        let result = ScanResult()
        result.dataItems = [
            DataItem(path: "/u/Library/Caches/beta", name: "beta", rootLabel: "Caches", kind: "dir", status: "orphaned", sizeBytes: 10),
            DataItem(path: "/u/Library/Caches/alpha", name: "alpha", rootLabel: "Caches", kind: "dir", status: "orphaned", sizeBytes: 10),
            DataItem(path: "/u/Library/Caches/huge", name: "huge", rootLabel: "Caches", kind: "dir", status: "orphaned", sizeBytes: 99),
        ]
        XCTAssertEqual(orphanedBySize(result).map(\.name), ["huge", "alpha", "beta"])
        result.dataItems.reverse()
        XCTAssertEqual(orphanedBySize(result).map(\.name), ["huge", "alpha", "beta"])
    }
}
