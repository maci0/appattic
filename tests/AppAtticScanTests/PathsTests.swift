import XCTest
@testable import AppAtticScan

final class PathsTests: XCTestCase {
    func testNormStripsPunctuation() {
        XCTAssertEqual(norm("Google Chrome"), "googlechrome")
        XCTAssertEqual(norm("iTerm2"), "iterm2")
        XCTAssertEqual(norm("a1b2"), "a1b2")
    }


    func testNormCollapsesNFCAndNFD() {
        let nfc = "Café"
        let nfd = "Cafe\u{0301}"
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        XCTAssertEqual(norm(nfc), "cafe")
        XCTAssertEqual(norm(nfd), "cafe")
        XCTAssertEqual(norm("Cafe"), "cafe")
        XCTAssertEqual(norm("CAFÉ"), "cafe")
    }


    func testNormCaseFoldsSharpS() {
        XCTAssertEqual(norm("Straße"), "strasse")
    }


    func testPathIdentityKeyUsesNFC() {
        let nfc = "/tmp/Café"
        let nfd = "/tmp/Cafe\u{0301}"
        XCTAssertEqual(pathIdentityKey(nfc), pathIdentityKey(nfd))
        XCTAssertEqual(pathIdentityKey(nfc), nfc.precomposedStringWithCanonicalMapping)
    }


    func testCleanupPathDirectoriesIncludeLinuxAndDarwinBins() {
        let dirs = cleanupPathDirectories(home: "/home/x")
        XCTAssertTrue(dirs.contains("/home/linuxbrew/.linuxbrew/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/home/x/.local/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/home/x/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/usr/local/bin"), "\(dirs)")
    }


    func testXdgUserDirsHonorEnvEmptyAndFallback() {
        let home = "/home/x"
        XCTAssertEqual(xdgDataHome(home: home, env: [:]), "/home/x/.local/share")
        XCTAssertEqual(xdgConfigHome(home: home, env: [:]), "/home/x/.config")
        XCTAssertEqual(xdgCacheHome(home: home, env: [:]), "/home/x/.cache")
        XCTAssertEqual(xdgStateHome(home: home, env: [:]), "/home/x/.local/state")
        XCTAssertEqual(
            xdgDataHome(home: home, env: ["XDG_DATA_HOME": "/tmp/myshare"]),
            "/tmp/myshare"
        )
        XCTAssertEqual(
            xdgConfigHome(home: home, env: ["XDG_CONFIG_HOME": ""]),
            "/home/x/.config"
        )
        XCTAssertEqual(
            xdgDataHome(home: home, env: ["XDG_DATA_HOME": "   "]),
            "/home/x/.local/share"
        )
        XCTAssertEqual(
            xdgCacheHome(home: home, env: ["XDG_CACHE_HOME": "~/mycache"]),
            "/home/x/.cache"
        )
        XCTAssertEqual(
            xdgStateHome(home: home, env: ["XDG_STATE_HOME": "relative/state"]),
            "/home/x/.local/state"
        )
    }


    func testXdgSystemDirsTreatEmptyAsUnset() {
        XCTAssertEqual(xdgSystemDirs(env: [:]), "/usr/local/share:/usr/share")
        XCTAssertEqual(xdgSystemDirs(env: ["XDG_DATA_DIRS": ""]), "/usr/local/share:/usr/share")
        XCTAssertEqual(xdgSystemDirs(env: ["XDG_DATA_DIRS": "   "]), "/usr/local/share:/usr/share")
        XCTAssertEqual(xdgSystemDirs(env: ["XDG_DATA_DIRS": "/opt/share"]), "/opt/share")
    }


    func testRedactHomePathsReplacesHomePrefixOnly() {
        XCTAssertEqual(
            redactHomePaths(
                "rm: cannot remove '/home/alice/Library/Caches/Foo': Permission denied",
                home: "/home/alice"
            ),
            "rm: cannot remove '~/Library/Caches/Foo': Permission denied"
        )
        XCTAssertEqual(
            redactHomePaths("failed at /home/alice", home: "/home/alice"),
            "failed at ~"
        )
        XCTAssertEqual(
            redactHomePaths("/home/alice2/secret", home: "/home/alice"),
            "/home/alice2/secret"
        )
        XCTAssertEqual(redactHomePaths("/tmp/x", home: "/"), "/tmp/x")
    }


    func testRedactHomePathsAcrossNormalizationForms() {
        // macOS reports the account path decomposed; tools print it composed.
        let nfdHome = "/Users/Jose\u{0301}"
        XCTAssertEqual(
            redactHomePaths("rm: cannot remove '/Users/José/Downloads': Permission denied", home: nfdHome),
            "rm: cannot remove '~/Downloads': Permission denied"
        )
        XCTAssertEqual(
            redactHomePaths("rm: cannot remove '/Users/Jose\u{0301}/Downloads'", home: "/Users/José"),
            "rm: cannot remove '~/Downloads'"
        )
        XCTAssertEqual(
            redactHomePaths("/Users/Jose\u{0301}2/secret", home: nfdHome),
            "/Users/Jose\u{0301}2/secret"
        )
    }


    func testRedactHomePathsStaysCorrectPastTheMemoBound() {
        // The standardized-home memo is bounded; a caller that keeps handing it
        // fresh keys must still get redacted output, not a stale or missing entry.
        for i in 0..<32 {
            let home = "/tmp/redact-bound-\(i)"
            XCTAssertEqual(
                redactHomePaths("rm: cannot remove '\(home)/Caches/Foo': denied", home: home),
                "rm: cannot remove '~/Caches/Foo': denied",
                "home \(home)"
            )
        }
    }

    func testRedactHomePathsWithEmptyHomeDoesNotBorrowTheProcessHome() throws {
        // An empty home is a real argument, not "resolve the process home".
        // The memo must not hand back the process-home slot for it.
        let processHome = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        try XCTSkipIf(processHome.count <= 1, "no redaction is attempted for a root-only home")
        let text = "rm: cannot remove '\(processHome)/Library/Caches/Foo': Permission denied"
        XCTAssertEqual(redactHomePaths(text), "rm: cannot remove '~/Library/Caches/Foo': Permission denied")
        XCTAssertEqual(redactHomePaths(text, home: ""), text)
        // And it stays that way when other homes have passed through the memo.
        for i in 0..<32 {
            XCTAssertEqual(redactHomePaths("at /tmp/redact-empty-\(i)/x", home: "/tmp/redact-empty-\(i)"), "at ~/x")
        }
        XCTAssertEqual(redactHomePaths(text, home: ""), text)
    }
}
