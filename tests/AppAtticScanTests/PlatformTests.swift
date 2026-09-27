import XCTest
@testable import AppAtticScan

final class PlatformTests: XCTestCase {
    func testResolveDistroPackageManagerFamilyThenPath() {
        let none: WhichFn = { _ in nil }
        XCTAssertEqual(resolveDistroPackageManager(family: "arch", which: none), .pacman)
        XCTAssertEqual(resolveDistroPackageManager(family: "debian", which: none), .apt)
        XCTAssertEqual(resolveDistroPackageManager(family: "fedora", which: none), .dnf)
        XCTAssertEqual(resolveDistroPackageManager(family: "suse", which: none), .zypperPkg)
        XCTAssertNil(resolveDistroPackageManager(family: "unknown", which: none))
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "pacman" ? "/usr/bin/pacman" : nil }),
            .pacman
        )
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "dnf" ? "/usr/bin/dnf" : nil }),
            .dnf
        )
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "zypper" ? "/usr/bin/zypper" : nil }),
            .zypperPkg
        )
        XCTAssertEqual(
            resolveDistroPackageManager(family: "unknown", which: { $0 == "apt" ? "/usr/bin/apt" : nil }),
            .apt
        )
        XCTAssertEqual(
            resolveDistroPackageManager(
                family: "unknown",
                which: { ["pacman", "apt"].contains($0) ? "/usr/bin/\($0)" : nil }
            ),
            .pacman
        )
    }


    func testParseOsReleaseSplitsLinesStripsQuotesAndSkipsComments() {
        let fields = parseOsRelease(
            """
            # a comment line
               \tID=arch
            NAME="Arch Linux"

            ID_LIKE='archlinux'
              PRETTY_NAME="Arch Linux"\t
            LINUX_SOURCE=example:x=1
            EMPTY=
            no-equals-here
            =value-first
            """
        )
        XCTAssertEqual(fields["ID"], "arch")
        XCTAssertEqual(fields["NAME"], "Arch Linux")
        XCTAssertEqual(fields["ID_LIKE"], "archlinux", "single quotes wrap a value as well as double")
        XCTAssertEqual(fields["PRETTY_NAME"], "Arch Linux", "padding around the value and its quotes is dropped")
        XCTAssertEqual(fields["LINUX_SOURCE"], "example:x=1", "only the first equals separates key from value")
        XCTAssertEqual(fields["EMPTY"], "")
        XCTAssertNil(fields["no-equals-here"], "a line without an equals is not a field")
        XCTAssertNil(fields[""], "a line starting with an equals has an empty key and is dropped")
        XCTAssertEqual(fields.count, 6)
    }

    func testParseOsReleaseHandlesEveryLineEnding() {
        for text in ["ID=arch\nNAME=Arch\n", "ID=arch\r\nNAME=Arch\r\n", "ID=arch\rNAME=Arch\r", "ID=arch\nNAME=Arch"] {
            let fields = parseOsRelease(text)
            XCTAssertEqual(fields, ["ID": "arch", "NAME": "Arch"], text.debugDescription)
        }
    }

    func testParseOsReleaseLeavesAnUnmatchedQuoteInTheValue() {
        // A single leading quote is data, not a pair to strip.
        XCTAssertEqual(parseOsRelease("ID=\"arch\n")["ID"], "\"arch")
        XCTAssertEqual(parseOsRelease("ID=\"\n")["ID"], "\"")
    }

    func testParseOsReleaseLetsALaterAssignmentWin() {
        XCTAssertEqual(parseOsRelease("ID=arch\nID=manjaro\n")["ID"], "manjaro")
    }

    func testIsDnfListingNoise() {
        XCTAssertTrue(isDnfListingNoise("Last metadata expiration check: 1:23:45 ago"))
        XCTAssertTrue(isDnfListingNoise("Packages"))
        XCTAssertTrue(isDnfListingNoise("Finding unneeded"))
        XCTAssertTrue(isDnfListingNoise("Available Upgrades"))
        XCTAssertTrue(isDnfListingNoise("Obsoleting Packages"))
        XCTAssertFalse(isDnfListingNoise("libfoo"))
        XCTAssertFalse(isDnfListingNoise("git.x86_64                    2.45.1-1.fc40           updates"))
    }
}
