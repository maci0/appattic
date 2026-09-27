import XCTest
@testable import AppAtticScan

/// Fuzzes the two untrusted inputs the CLI takes: the argv vector and
/// `COLORFGBG`. A crash here is a crash before any scan starts, on whatever
/// the shell hands over, so the harness asserts behaviour rather than only
/// watching for traps.
final class FuzzCLIArgumentsTests: XCTestCase {
    /// Flags each command accepts. The generator only ever builds a vector
    /// from these, so a clean parse is the expected outcome, not a hope.
    private static let validCommands = ["config", "report", "leftovers", "stale", "outdated", "packages", "update", "disk"]

    private static let validVectors: [[String]] = [
        [], ["--version"], ["-v"], ["--help"], ["-h"], ["help"], ["help", "disk"], ["config"],
        ["report", "--include-system", "--fresh", "--no-color", "--dry-run"],
        ["leftovers", "--top", "10"],
        ["leftovers", "--category", "caches", "--category", "browser"],
        ["report", "--leftovers-only"],
        ["report", "--stale-only"],
        ["outdated", "--json", "/tmp/appattic.json"],
        ["packages"], ["stale"],
        ["disk", "/var", "--top", "5", "--allocated"],
        ["disk", "--all-file-systems"],
        ["update", "--dry-run"],
        ["update", "--yes"],
        ["update", "-y", "--json", "/tmp/u.json"],
    ]

    /// Tokens that must produce a usage error wherever they appear. `--` is
    /// not among them: it ends the options, so it only reads as a bad command
    /// name in what follows it. `CLIFlagTests.testEndOfOptionsTerminator` pins
    /// that, and a token here is inserted at every position, where a
    /// terminator would swallow the rest of the vector.
    private static let rejectedTokens = [
        "", " ", "  \t ", "-", "--nope", "-x", "--json", "--top", "--category",
        "--top=", "--top=-1", "--top=abc", "--top=99999999999999999999",
        "--json=", "--json=-out", "--category=", "--category=-x",
        String(repeating: "z", count: 4096),
        "\u{1F600}", "leftovers\u{0}", "\u{FEFF}report", "dísk", "REPORT",
    ]

    private func describe(_ args: [String]) -> String {
        "seed args: \(args.map { "\"\($0)\"" }.joined(separator: " "))"
    }

    func testValidVectorsParseCleanlyAndKeepTheirValues() {
        for vector in FuzzCLIArgumentsTests.validVectors {
            let opts = parseCLIArguments(vector)
            XCTAssertNil(opts.parseError, "\(vector): \(opts.error ?? "")")
            XCTAssertNil(opts.error, describe(vector))
        }
        let disk = parseCLIArguments(["disk", "/var", "--top", "5", "--allocated"])
        XCTAssertEqual(disk.command, "disk")
        XCTAssertEqual(disk.diskPath, "/var")
        XCTAssertEqual(disk.top, 5)
        XCTAssertTrue(disk.allocated)

        let cats = parseCLIArguments(["leftovers", "--category", "caches", "--category", "browser"])
        XCTAssertEqual(cats.category, ["caches", "browser"])

        let json = parseCLIArguments(["outdated", "--json=/tmp/a.json"])
        XCTAssertEqual(json.json, "/tmp/a.json")

        for vector in FuzzCLIArgumentsTests.validVectors where vector.contains("disk") {
            XCTAssertTrue(FuzzCLIArgumentsTests.validCommands.contains(parseCLIArguments(vector).command))
        }
    }

    /// Every generated vector mixes documented flags, values, and positionals
    /// the way a shell can. The parse must not trap and must report the values
    /// it was handed.
    func testMutatedValidVectorsNeverTrapAndKeepCommandAndTop() {
        var rng = FuzzRandom(seed: 0x5EED_C11A)
        let junk = FuzzMutator.text(
            from: "--top= /var |caches\n\t",
            using: &rng
        )
        // Build from the pool, not from one mutated blob: token boundaries
        // matter to a hand-rolled parser, and a blob has none.
        for seed in fuzzSeeds {
            var built: [String] = []
            let pool = FuzzCLIArgumentsTests.validCommands
                + ["--json", "/tmp/a.json", "--top", "7", "--category", "caches", "--version", "--yes"]
            for _ in 0...(rng.int(6)) { built.append(rng.element(pool)) }
            if !junk.isEmpty { built.insert(junk, at: built.isEmpty ? 0 : rng.int(built.count)) }

            let opts = parseCLIArguments(built)
            XCTAssertEqual(opts.error, opts.parseError?.description, "seed \(seed): \(describe(built))")
            // Same input, same answer: the parser carries no state between runs.
            let again = parseCLIArguments(built)
            XCTAssertEqual(again.command, opts.command, "seed \(seed): \(describe(built))")
            XCTAssertEqual(again.top, opts.top, "seed \(seed): \(describe(built))")
            XCTAssertEqual(again.category, opts.category, "seed \(seed): \(describe(built))")
            XCTAssertEqual(again.parseError, opts.parseError, "seed \(seed): \(describe(built))")
        }
    }

    /// A token the parser does not know is a usage error, wherever it sits in
    /// the vector, and the message names the offending token.
    func testRejectedTokenAnywhereYieldsAUsageError() {
        var rng = FuzzRandom(seed: 0x5EED_C11B)
        for (seed, token) in fuzzSeeds.enumerated() {
            for filler in FuzzCLIArgumentsTests.validVectors {
                let placement = rng.int(filler.count + 1)
                var args = filler
                args.insert(token, at: placement)
                let opts = parseCLIArguments(args)
                guard let error = opts.parseError else {
                    XCTFail("accepted \(token) in \(describe(args)) (seed \(seed))")
                    continue
                }
                XCTAssertFalse(error.description.isEmpty, describe(args))
                XCTAssertEqual(opts.error, error.description, describe(args))
            }
        }
    }

    /// First error wins, so an already-broken vector keeps its error when a
    /// later boolean flag is appended. Anything the user has to fix first is
    /// the one they are told about.
    func testFirstErrorSurvivesLaterBooleanFlags() {
        var rng = FuzzRandom(seed: 0x5EED_C11C)
        let booleans = ["--version", "-v", "--help", "-h", "--include-system", "--fresh", "--no-color", "--dry-run", "--yes", "-y"]
        for broken in FuzzCLIArgumentsTests.rejectedTokens {
            let first = parseCLIArguments([broken])
            XCTAssertNotNil(first.parseError, "expected \(broken) to be rejected")
            for flag in booleans {
                let opts = parseCLIArguments([broken, flag])
                XCTAssertEqual(opts.parseError, first.parseError, "\(broken) then \(flag)")
            }
        }
        for _ in 0..<200 {
            let vector = [
                FuzzCLIArgumentsTests.rejectedTokens[rng.int(FuzzCLIArgumentsTests.rejectedTokens.count)],
                rng.element(booleans),
                FuzzCLIArgumentsTests.rejectedTokens[rng.int(FuzzCLIArgumentsTests.rejectedTokens.count)],
            ]
            let opts = parseCLIArguments(vector)
            XCTAssertNotNil(opts.parseError, describe(vector))
        }
    }

    func testMutatedToneStringsFallBackOrClassifyWithoutTrapping() {
        let toneSeeds = ["0;0", "0;7", "0;6", "0;8", "15;15", "0;49", "0;50", "0;99", "default;0", ";", "0", "0;1;2", " 0 ; 6 ", "0;+6", "0;0x6", "0;abc", "", ";0", "0;", "7;7"]
        for raw in toneSeeds {
            let tone = cliTone(env: ["COLORFGBG": raw])
            let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2, let bg = Int(fields[1].trimmingCharacters(in: .whitespaces)) else {
                XCTAssertEqual(tone, .light, "COLORFGBG=\(raw)")
                continue
            }
            // 0-6 are the base palette, 7 is white as an xterm index but a
            // near-black background as a percentage, 8 and up is a percentage.
            let expected: CliTone = bg <= 6 ? .dark : (bg < 8 ? .light : (bg < 50 ? .dark : .light))
            XCTAssertEqual(tone, expected, "COLORFGBG=\(raw)")
        }
        var rng = FuzzRandom(seed: 0x5EED_C11D)
        for seed in fuzzSeeds {
            let raw = FuzzMutator.text(from: toneSeeds.joined(separator: "|"), using: &rng)
            let tone = cliTone(env: ["COLORFGBG": raw])
            let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
            if fields.count != 2 {
                XCTAssertEqual(tone, .light, "seed \(seed): COLORFGBG=\(raw.debugDescription)")
            }
            // No env key at all is the fallback too.
            XCTAssertEqual(cliTone(env: [:]), .light)
        }
    }
}
