import XCTest
@testable import AppAtticScan

/// Fuzzes the guard line the removal commands are built from and parsed back
/// by. `guardedRemoveCommand` writes `if <query>; then <action>; fi`, and
/// `parseGuardedRemove` is what `commandNeedsRoot` and `withRootCmd` read to
/// find the action inside it. A split in the wrong place moves the privilege
/// escalation onto a different half of the line, so the harness holds the two
/// ends to each other: a line built from a quoted name parses back to exactly
/// the halves it was built from, and a line with anything after the last
/// `; fi` is not a guard at all.
///
/// The name is the untrusted half. It is drawn from the grammar the package
/// parsers actually produce, a whitespace-free token, because a name carrying
/// a space cannot reach a guard: every builder quotes a name that a listing
/// parser already cut at whitespace.
final class FuzzGuardedRemoveTests: XCTestCase {
    /// Seeded names from the managers this table covers, mutated with the
    /// mutator's own alphabet so a cut, a duplicated delimiter, or a spliced
    /// option dash shows up in the middle of a name.
    private static let nameSeeds = [
        "libfoo",
        "brew-cask",
        "wget@1.21.4",
        "python3.12",
        "org.gimp.GIMP",
        "com.example.app-helper",
        "a",
    ]

    private func fuzzedName(using rng: inout FuzzRandom) -> String {
        let base = rng.element(FuzzGuardedRemoveTests.nameSeeds)
        var bytes = FuzzMutator.bytes(from: Array(base.utf8), using: &rng, hotBytes: FuzzMutator.asciiHotBytes)
        // The grammar: a name is one token, and the shell words built around it
        // are separated by single spaces. A space in a name is not a shape the
        // parsers emit, so it is not built here either.
        bytes.removeAll { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 == 0x00 }
        if bytes.isEmpty { return base }
        // A name the shell would read as an option is dropped where it comes
        // from, so half the corpus leads with a dash to keep that path covered.
        if rng.int(2) == 0 { bytes[0] = 0x2D }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The two ends of the guard: whatever name the corpus produced, the line
    /// splits back into the query and the action it was written from, and the
    /// escalation lands inside the action.
    func testGuardLineSplitsBackIntoTheHalvesItWasBuiltFrom() {
        var rng = FuzzRandom(seed: 0x5EED_6A16)
        for _ in fuzzSeeds {
            let name = fuzzedName(using: &rng)
            let where_ = name.debugDescription
            guard isSafeCommandArgument(name) else {
                // A name that reads as an option never reaches a command, so
                // the builder drops the row instead of wrapping it in a guard.
                XCTAssertTrue(
                    uninstallCommand(
                        source: "brew-formula",
                        name: name,
                        path: "/opt/\(name)",
                        caskName: nil,
                        steamAppId: nil,
                        pkgId: nil
                    ).hasPrefix("# skipped"),
                    where_
                )
                continue
            }
            let q = shellQuote(name)
            for line in [
                guardedRemoveCommand(present: "brew list --formula \(q)", remove: "brew uninstall \(q)"),
                guardedRemoveCommand(present: "flatpak info \(q)", remove: "flatpak uninstall -y \(q)"),
                guardedRemoveCommand(present: "test -e \(q)", remove: "rm -rf \(q)"),
            ] {
                let split = parseGuardedRemove(line)
                guard let split else {
                    XCTFail("a guard this module wrote did not parse: \(line.debugDescription) \(where_)")
                    continue
                }
                XCTAssertFalse(split.present.isEmpty, "empty query: \(line.debugDescription) \(where_)")
                XCTAssertFalse(split.action.isEmpty, "empty action: \(line.debugDescription) \(where_)")
                XCTAssertTrue(split.present.contains(q), "query lost the name: \(line.debugDescription) \(where_)")
                XCTAssertTrue(split.action.contains(q), "action lost the name: \(line.debugDescription) \(where_)")
                // Rewriting the halves reproduces the line, so the split and
                // the writer agree on where the boundaries are.
                XCTAssertEqual(guardedRemoveCommand(present: split.present, remove: split.action), line, where_)
                // The escalation belongs to the action; the query is a read.
                if commandNeedsRoot(line) {
                    XCTAssertTrue(
                        withRootCmd(line).contains("; then rootcmd \(split.action); fi"),
                        "escalation outside the action: \(withRootCmd(line).debugDescription) \(where_)"
                    )
                }
            }
        }
    }

    /// Nothing after the last `; fi` is a tail the callers never judge, so a
    /// line carrying one is not a guard. The known tails are refused by name,
    /// and the whole mutator alphabet goes through the same check from real
    /// guards.
    func testGuardWithATailIsNotAGuard() {
        for tailed in [
            "if test -e '/a b'; then rm -rf '/a b'; fi; reboot",
            "if test -e '/a b'; then rm -rf '/a b'; fi\nreboot",
            "if test -e '/a b'; then rm -rf '/a b'; fi extra",
        ] {
            XCTAssertNil(parseGuardedRemove(tailed), tailed.debugDescription)
        }
        let guards = [
            "if test -e '/a b'; then rm -rf '/a b'; fi",
            "if dpkg -s libfoo >/dev/null 2>&1; then apt-get purge -y libfoo; fi",
        ]
        var rng = FuzzRandom(seed: 0x5EED_7A1E)
        for base in guards {
            for seed in fuzzSeeds {
                let line = FuzzMutator.text(from: base, using: &rng)
                let where_ = "seed \(seed): \(line.debugDescription)"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let split = parseGuardedRemove(line) else { continue }
                // Whatever parsed, the two halves are cut from the line and
                // the line carries nothing the caller would not have judged.
                XCTAssertTrue(trimmed.hasPrefix("if "), where_)
                XCTAssertTrue(trimmed.hasSuffix("; fi"), "a tail survived the split: \(where_)")
                XCTAssertTrue(trimmed.contains(split.present), "query not in the line: \(where_)")
                XCTAssertTrue(trimmed.contains(split.action), "action not in the line: \(where_)")
                XCTAssertFalse(split.present.isEmpty, "empty query: \(where_)")
                XCTAssertFalse(split.action.isEmpty, "empty action: \(where_)")
            }
        }
    }
}
