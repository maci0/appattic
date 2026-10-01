import XCTest
@testable import AppAtticScan

/// The option-injection guard on a name that reaches a package manager.
/// `shellQuote` leaves a leading `-` unquoted, so a name from a registry, a
/// tap, or the scan cache is read as an option by the command it lands in.
/// The rule is small enough to be one expression in `ShellScript.swift` and
/// load-bearing enough that the predicate itself is pinned here, alongside
/// each caller that has to honour it. A caller that forgot the check would
/// still pass a test that only inspected the predicate.
final class ShellScriptTests: XCTestCase {
    /// The rule, on its own: empty is never a name, a leading dash is always
    /// an option, and everything else stands on its quoting.
    func testIsSafeCommandArgument() {
        XCTAssertFalse(isSafeCommandArgument(""), "an empty word is not a name to remove")
        XCTAssertFalse(isSafeCommandArgument("-"), "`-` is stdin")
        XCTAssertFalse(isSafeCommandArgument("--force"))
        XCTAssertFalse(isSafeCommandArgument("--allow-unauthenticated"))
        // Only the leading byte decides. Everything after it is quoted.
        XCTAssertTrue(isSafeCommandArgument("wget"))
        XCTAssertTrue(isSafeCommandArgument("libwebkit2gtk-4.1"))
        XCTAssertTrue(isSafeCommandArgument("foo-bar"))
        XCTAssertTrue(isSafeCommandArgument("a-b"))
    }

    /// `isSafeCmdIdent` is the tighter gate `listDenoGlobals` applies, and its
    /// twin in the core is `jsonbuf.isSafeCmdIdent`. The two readers of
    /// `~/.deno/bin` have to agree on which globals exist, or the CLI lists a
    /// package the core's removal script does not know.
    ///
    /// The byte set is `a-z A-Z 0-9 - _ . +`, so both sides of every range are
    /// pinned, along with the non-ASCII and shell-metacharacter refusals.
    /// `isSafeCommandArgument` above would accept all of them.
    func testIsSafeCmdIdentMatchesTheZigIdentByteSet() {
        for ok in ["a", "z", "A", "Z", "0", "9", "-", "_", ".", "+", "eslint",
                   "libwebkit2gtk-4.1", "a+b", "a_b", "a.b", "a-b"] {
            XCTAssertTrue(isSafeCmdIdent(ok), ok)
        }
        for bad in ["", "-", "--force", "/", "a/b", "a b", "a'b", "a;b", "a$b",
                    "@scope/pkg", "a:b", "a@b", "a=b", "a,b", "a%", "a~", "a|b",
                    "caf\u{00E9}", "\u{65E5}\u{672C}\u{8A9E}", "a\u{0301}"] {
            XCTAssertFalse(isSafeCmdIdent(bad), bad)
        }
        // A non-ASCII name is refused here exactly as `jsonbuf.isSafeCmdIdent`
        // refuses it, byte by byte: a multi-byte scalar is several bytes, none
        // of which is in the set, so the first one already fails.
        XCTAssertTrue(isSafeCommandArgument("caf\u{00E9}"))
        XCTAssertFalse(isSafeCmdIdent("caf\u{00E9}"))
    }

    /// A row with no name is refused, not scripted as `apt remove `.
    func testPackageRemoveRefusesAnEmptyName() {
        XCTAssertEqual(
            packageRemoveCommand(PackageEntry(name: "", manager: "apt", kind: "orphan")),
            "# skipped : name reads as a command option"
        )
    }

    /// The mark-manual path returns nil rather than a comment, because there is
    /// no script line to annotate: the entry is simply left unmarkable.
    func testPackageMarkManualRefusesNameThatReadsAsAnOption() {
        let hostile = PackageEntry(name: "--assume-yes", manager: "apt", kind: "orphan")
        XCTAssertTrue(hostile.canMarkManual, "the manager can mark manual, so only the name can refuse")
        XCTAssertNil(packageMarkManualCommand(hostile))
    }

    /// An ordinary name is kept, inside the presence guard every removal
    /// carries: a re-run over a package the first run purged has to skip the
    /// line rather than exit nonzero under `set -e`. `ScriptReRunTests` runs
    /// the line twice against a stub manager and asserts the second run
    /// reaches the line below it.
    func testPackageMarkManualKeepsAnOrdinaryName() {
        XCTAssertEqual(
            packageMarkManualCommand(PackageEntry(name: "curl", manager: "apt", kind: "orphan")),
            "if dpkg -s curl >/dev/null 2>&1; then apt-mark manual curl; fi"
        )
    }

    /// The update path is the same rule with the same consequence: no command,
    /// so nothing runs with a registry-supplied option.
    func testUpdateCommandRefusesNameThatReadsAsAnOption() {
        let hostile = OutdatedPkg(name: "--force", manager: "apt")
        XCTAssertEqual(hostile.upgradableManager, .apt, "otherwise this test proves nothing about the guard")
        XCTAssertNil(updateCommand(hostile))
        XCTAssertEqual(
            updateCommand(OutdatedPkg(name: "curl", manager: "apt", currentVersion: "8.0", latestVersion: "8.5")),
            "apt-get -y install --only-upgrade curl"
        )
    }
}
