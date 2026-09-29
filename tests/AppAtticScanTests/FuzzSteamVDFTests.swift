import XCTest
@testable import AppAtticScan

/// Fuzzes the VDF reader behind `findSteamApps`: `appmanifest_*.acf` and
/// `libraryfolders.vdf` are files any process running as the account can
/// write, and `steamAppRecord` puts the name, the install dir, and the app id
/// from one of them into the record the uninstall script is generated from.
/// Both readers are hand-rolled quote scanning over a bracket-depth counter,
/// so the harness checks that every string that comes out is text the file
/// actually holds.
final class FuzzSteamVDFTests: XCTestCase {
    /// `"`, `{` and `}` are what the VDF readers key on, and `FuzzMutator`
    /// leaves them out of its hot bytes for the harnesses that hold two
    /// readers of one path against each other. Here they are the whole
    /// grammar, so they are the bytes worth mutating.
    private static let hotBytes: [UInt8] = FuzzMutator.hotBytes + [0x22, 0x7B, 0x7D]

    /// Bit 2 of `StateFlags`, the bit that says the game is installed. The
    /// parser keeps it private, so it is spelled out here.
    private static let installedFlag = 4

    /// A real `appmanifest_*.acf`, with the one line Steam writes that is not
    /// a key, and a real `libraryfolders.vdf`.
    private static let manifestSeed = """
    "AppState"
    {
    \t"appid"\t\t"570"
    \t"name"\t\t"Dota 2"
    \t"StateFlags"\t\t"4"
    \t"installdir"\t\t"dota 2 beta"
    \t"LastPlayed"\t\t"1769229316"
    \t"SizeOnDisk"\t\t"484359177"
    \t"buildid"\t\t"5378433"
    \t"LastUpdated"\t\t"1734600000"
    }
    """

    private static let librarySeeds = [
        """
        "libraryfolders"
        {
        \t"0"
        {
        \t\t"path"\t\t"/home/user/.steam/steam"
        \t\t"label"\t\t""
        \t\t"contentid"\t\t"1234567890"
        \t\t"apps"
        \t\t{
        \t\t\t"570"\t\t"484359177"
        \t\t}
        \t}
        \t"1"
        {
        \t\t"path"\t\t"/mnt/games/SteamLibrary"
        \t\t"apps"
        \t\t{
        \t\t\t"440"\t\t"1000"
        \t\t}
        \t}
        }
        """,
        "\"path\"\t\t\"/only/one\"\n",
        "\"path\"\t\t\"/dupe\"\n\"path\"\t\t\"/dupe\"\n",
        "\"path\"\t\t\"\"\n",
        "\"Path\"\t\t\"/wrong/case\"\n",
    ]

    /// How many key,value pairs a file of this text could yield at one depth:
    /// one per line carrying at least two quoted spans, and never more.
    private func pairCapacity(_ text: String, depth wanted: Int) -> Int {
        var depth = 0
        var capacity = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if depth == wanted, vdfQuotedStrings(String(line)).count >= 2 { capacity += 1 }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth < 0 { depth = 0 }
        }
        return capacity
    }

    private func assertCutFromFile(
        _ value: String,
        _ text: String,
        _ where_: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // An empty span is legal in a VDF (`"label" ""`), and searching a
        // string for the empty one does not answer what was asked, so the
        // containment check is only meaningful for a span with something in
        // it.
        if !value.isEmpty {
            XCTAssertTrue(text.contains(value), "value is not text the file holds: \(value.debugDescription) \(where_)", file: file, line: line)
        }
        XCTAssertFalse(value.contains("\""), "quote left in value: \(value.debugDescription) \(where_)", file: file, line: line)
        XCTAssertFalse(value.contains("\n"), "value spans lines: \(value.debugDescription) \(where_)", file: file, line: line)
    }

    /// The invariants `vdfPairs` must hold whatever it is handed: a key and a
    /// value cut from one line of the file with the quotes taken off, at most
    /// one pair per line that carries two quoted spans, and the same answer
    /// twice.
    func testMutatedVDFPairsYieldKeysCutFromTheFile() {
        var rng = FuzzRandom(seed: 0x5EED_5644)
        for text in [
            FuzzSteamVDFTests.manifestSeed,
            FuzzSteamVDFTests.librarySeeds[0],
            FuzzSteamVDFTests.librarySeeds[1],
        ] {
            for seed in fuzzSeeds {
                let mutated = FuzzMutator.text(from: text, using: &rng, hotBytes: FuzzSteamVDFTests.hotBytes)
                let where_ = "seed \(seed): \(mutated.debugDescription)"
                for depth in 0...3 {
                    let pairs = vdfPairs(mutated, depth: depth)
                    XCTAssertEqual(vdfPairs(mutated, depth: depth).count, pairs.count, "not deterministic: \(where_) depth \(depth)")
                    XCTAssertLessThanOrEqual(pairs.count, pairCapacity(mutated, depth: wanted: depth), "more pairs than lines: \(where_) depth \(depth)")
                    for (key, value) in pairs {
                        assertCutFromFile(key, mutated, "\(where_) depth \(depth)")
                        assertCutFromFile(value, mutated, "\(where_) depth \(depth)")
                    }
                }
            }
        }
    }

    /// A manifest the parser hands on is fully described by the file: three
    /// non-empty fields cut from it, the installed flag the file spells, and a
    /// last-played date only where the file spells a positive stamp.
    func testMutatedManifestYieldsFieldsCutFromTheFile() {
        var rng = FuzzRandom(seed: 0x5EED_4A41)
        for seed in fuzzSeeds {
            let text = FuzzMutator.text(from: FuzzSteamVDFTests.manifestSeed, using: &rng, hotBytes: FuzzSteamVDFTests.hotBytes)
            let where_ = "seed \(seed): \(text.debugDescription)"
            guard let manifest = parseSteamAppManifest(text) else { continue }
            XCTAssertTrue(manifest.isInstalled, where_)
            for field in [manifest.appId, manifest.name, manifest.installDir] {
                XCTAssertFalse(field.isEmpty, "empty field kept: \(where_)")
                assertCutFromFile(field, text, where_)
            }
            // `Int(...) ?? 0` never traps, but the flag decides whether the
            // manifest is a game at all, so a manifest that came back has to
            // carry it.
            let flagged = vdfPairs(text, depth: 1)["StateFlags"].flatMap { Int($0) } ?? 0
            XCTAssertNotEqual(
                flagged & FuzzSteamVDFTests.installedFlag,
                0,
                "manifest without the installed bit: \(where_)"
            )
            // A last-played date is only ever set from a positive integer in
            // the file, so a file that spells none, or spells a zero or a
            // negative, must yield none.
            let playedRaw = vdfPairs(text, depth: 1)["LastPlayed"].flatMap { Int($0) } ?? 0
            if playedRaw <= 0 {
                XCTAssertNil(manifest.lastPlayed, "last played without a positive stamp: \(where_)")
            }
        }
    }

    /// Every library root is a `path` value cut from the file: non-empty,
    /// quoted in the file, and listed once however many lines spell it.
    func testMutatedLibraryFoldersYieldDistinctPathsFromTheFile() {
        var rng = FuzzRandom(seed: 0x5EED_11B7)
        for base in FuzzSteamVDFTests.librarySeeds {
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng, hotBytes: FuzzSteamVDFTests.hotBytes)
                let where_ = "base \(base.debugDescription) seed \(seed): \(text.debugDescription)"
                let paths = parseSteamLibraryFolders(text)
                XCTAssertEqual(parseSteamLibraryFolders(text), paths, "not deterministic: \(where_)")
                XCTAssertEqual(Set(paths).count, paths.count, "duplicate path: \(where_)")
                for path in paths {
                    XCTAssertFalse(path.isEmpty, "empty path kept: \(where_)")
                    assertCutFromFile(path, text, where_)
                }
            }
        }
    }

    /// The reader against text nobody mutated, so a failure above names a
    /// mutation rather than a plain parse.
    func testUnmutatedManifestAndLibraryFolders() {
        let manifest = parseSteamAppManifest(FuzzSteamVDFTests.manifestSeed)
        XCTAssertEqual(manifest?.appId, "570")
        XCTAssertEqual(manifest?.name, "Dota 2")
        XCTAssertEqual(manifest?.installDir, "dota 2 beta")
        XCTAssertTrue(manifest?.isInstalled ?? false)
        XCTAssertNil(parseSteamAppManifest("\"AppState\"\n{\n\t\"appid\"\t\t\"570\"\n}\n"), "manifest without every field")
        XCTAssertNil(
            parseSteamAppManifest("\"AppState\"\n{\n\t\"appid\"\t\"570\"\n\t\"name\"\t\"X\"\n\t\"installdir\"\t\"x\"\n\t\"StateFlags\"\t\"1026\"\n}\n"),
            "manifest without the installed bit"
        )

        XCTAssertEqual(
            parseSteamLibraryFolders(FuzzSteamVDFTests.librarySeeds[0]),
            ["/home/user/.steam/steam", "/mnt/games/SteamLibrary"]
        )
        XCTAssertEqual(parseSteamLibraryFolders(FuzzSteamVDFTests.librarySeeds[2]), ["/dupe"])
        XCTAssertEqual(parseSteamLibraryFolders(FuzzSteamVDFTests.librarySeeds[3]), [])
        XCTAssertEqual(parseSteamLibraryFolders(FuzzSteamVDFTests.librarySeeds[4]), ["/wrong/case"], "key is matched case-insensitively")
        XCTAssertEqual(parseSteamLibraryFolders(""), [])
    }
}
