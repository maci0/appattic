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
