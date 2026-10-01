import XCTest
@testable import AppAtticScan

/// Fuzzes the parsers that read text nobody on this machine wrote: package
/// manager output, `settings.json`, and ISO timestamps from filesystems. Each
/// one is hand-rolled byte indexing, so the harness checks the values that
/// come out, not just that nothing crashed.
final class FuzzManagerOutputTests: XCTestCase {
    private struct Target {
        let label: String
        let seed: String
        /// One row per input line, for the listing parsers.
        let onePerLine: Bool
        /// Names are cut from the input rather than decoded from a key.
        let namesFromInput: Bool
        /// A token parser stops at whitespace, so a name never carries any. A
        /// table cell is a span between pipes and may.
        var whitespaceFreeNames: Bool = true
        let names: (String) -> [String]
    }

    private static let targets: [Target] = [
        Target(
            label: "pacman-orphans",
            seed: "libreoffice-fresh 7.6.5-1\nfirefox 128.0-2\nerror: could not open\nwarning: cache\n",
            onePerLine: true, namesFromInput: true, names: { parsePacmanOrphans($0).map(\.name) }
        ),
        Target(
            label: "dpkg-rc",
            seed: "rc  libfoo 1.2.3-1\nrc  libbar\nrc\tlibbaz\t9.9\n",
            onePerLine: true, namesFromInput: true, names: { parseDpkgRc($0).map(\.name) }
        ),
        Target(
            label: "apt-autoremove",
            seed: "Remv libfoo [1.2.3-1]\nRemv libbar [0.1]\nRemv libfoo [1.2.3-1]\n",
            onePerLine: true, namesFromInput: true, names: { parseAptAutoremove($0).map(\.name) }
        ),
        Target(
            label: "dnf-unneeded",
            seed: "libfoo.x86_64\nlibbar.x86_64\nLast metadata expired check.\n",
            onePerLine: true, namesFromInput: true, names: { parseDnfUnneeded($0).map(\.name) }
        ),
        Target(
            label: "zypper-unneeded",
            seed: "S | Repository | Name | Version | Arch\n--+------------+------+----------+-------\n-- |        oss | libfoo | 1.2.3   | x86_64\n",
            onePerLine: true, namesFromInput: true, whitespaceFreeNames: false,
            names: { parseZypperUnneeded($0).map(\.name) }
        ),
        Target(
            label: "bun-global",
            seed: "/usr/lib/node_modules\n├── typescript@5.5.4\n├── @scope/pkg@1.0.0\n",
            onePerLine: true, namesFromInput: true, names: { parseBunGlobalList($0).map(\.name) }
        ),
        Target(
            label: "pipx-line",
            seed: "package ruff 0.5.0, installed using Python 3.12\npackage black 24.4.0, installed using Python 3.12\n",
            onePerLine: true, namesFromInput: true, names: { parsePipxList($0).map(\.name) }
        ),
        Target(
            label: "uv-tool-list",
            seed: "ruff v0.5.0\nhttpx v0.27.0\nbroken v\n",
            onePerLine: true, namesFromInput: true, names: { parseUvToolList($0).map(\.name) }
        ),
        Target(
            label: "apt-upgradable",
            seed: "libfoo/bookworm-security 1.2.4 amd64 [upgradable from: 1.2.3]\n",
            onePerLine: true, namesFromInput: true, names: { parseAptUpgradable($0).map(\.name) }
        ),
        Target(
            label: "pacman-qu",
            seed: "libfoo 1.2.3-1 -> 1.2.4-1\nlibbar 0.1-1 -> 0.2-1 [ignored]\n",
            onePerLine: true, namesFromInput: true, names: { parsePacmanQu($0).map(\.name) }
        ),
        Target(
            label: "dnf-upgrades",
            seed: "libfoo.x86_64    1.2.4-1.fc39      updates\nLast metadata expired.\n",
            onePerLine: true, namesFromInput: true, names: { parseDnfUpgrades($0).map(\.name) }
        ),
        Target(
            label: "zypper-list-updates",
            seed: "S | Repository | Name | Current Version | Available Version | Arch\n--+------------+------+-----------------+--------------------+-------\nv |      repo-oss | libfoo | 1.2.3 | 1.2.4 | x86_64\n",
            onePerLine: true, namesFromInput: true, whitespaceFreeNames: false,
            names: { parseZypperListUpdates($0).map(\.name) }
        ),
        Target(
            label: "mas-outdated",
            seed: "497799835 Xcode 14.3 (14.3 -> 15.0)\n",
            onePerLine: true, namesFromInput: true, names: { parseMasOutdated($0).map(\.name) }
        ),
        Target(
            label: "flatpak-updates",
            seed: "org.gimp.GIMP\t2.10.36\tGNU Image Manipulation Program\n",
            onePerLine: true, namesFromInput: true,
            names: { parseFlatpakUpdates($0, installedText: "org.gimp.GIMP\t2.10.34\n").map(\.name) }
        ),
        Target(
            label: "snap-refresh",
            seed: "Name  Version  Rev  Tracking  Publisher  Notes\ncore22  20231123  1234  latest/stable  canonical  base\n",
            onePerLine: true, namesFromInput: true,
            names: { parseSnapRefreshList($0, installedText: $0).map(\.name) }
        ),
        Target(
            label: "npm-global",
            seed: #"{"dependencies":{"typescript":{"version":"5.5.4"},"@scope/pkg":"1.0.0"}}"#,
            onePerLine: false, namesFromInput: false, names: { parseNpmGlobalList($0).map(\.name) }
        ),
        Target(
            label: "pnpm-global",
            seed: #"{"dependencies":{"eslint":"9.8.0"}}"#,
            onePerLine: false, namesFromInput: false, names: { parsePnpmGlobalList($0).map(\.name) }
        ),
        Target(
            label: "pipx-json",
            seed: #"{"venvs":{"ruff":{"metadata":{"main_package":{"package":"ruff","package_version":"0.5.0"}}}}}"#,
            onePerLine: false, namesFromInput: false, names: { parsePipxList($0).map(\.name) }
        ),
        Target(
            label: "brew-outdated",
            seed: #"{"formulae":[{"name":"wget","installed_versions":["1.21.4"],"current_version":"1.24.5"}],"casks":[]}"#,
            onePerLine: false, namesFromInput: false, names: { parseBrewOutdatedJSON($0).map(\.name) }
        ),
    ]

    private func nonEmptyLineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    /// The invariants a listing parser must hold whatever it is handed: a row
    /// per input line and never more, every name cut from the input with no
    /// whitespace or control byte around it, and the same answer twice.
    func testMutatedManagerOutputYieldsRowsCutFromTheInput() {
        for target in FuzzManagerOutputTests.targets {
            var rng = FuzzRandom(seed: 0x5EED_0C70 &+ UInt64(target.label.utf8.count))
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: target.seed, using: &rng)
                let names = target.names(text)
                let where_ = "\(target.label), seed \(seed): \(text.debugDescription)"

                for name in names {
                    XCTAssertFalse(name.isEmpty, where_)
                    if target.namesFromInput {
                        XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines), where_)
                        // A token is cut at whitespace, so a name that carries
                        // one came from a bad byte offset.
                        if target.whitespaceFreeNames {
                            XCTAssertFalse(name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " }), where_)
                        }
                        XCTAssertTrue(text.contains(name), "name not in input: \(where_)")
                    }
                }
                if target.onePerLine {
                    XCTAssertLessThanOrEqual(names.count, nonEmptyLineCount(text), where_)
                }
                XCTAssertEqual(target.names(text), names, "not deterministic: \(where_)")
            }
        }
    }

    /// A parser handed nothing but whitespace yields no rows, whatever shape
    /// the whitespace takes.
    func testWhitespaceOnlyInputYieldsNoRows() {
        let blank = ["", " ", "\n", "\r\n", "\n\n\n", "\t", "   \t \n "]
        for target in FuzzManagerOutputTests.targets {
            for text in blank {
                XCTAssertTrue(target.names(text).isEmpty, "\(target.label): \(text.debugDescription)")
            }
        }
    }

    /// Parsers that build a map deduplicate by name, and the JSON ones sort by
    /// it, because a Swift dictionary reseeds its iteration per process.
    func testDuplicateAndOrderStability() {
        let dup = "Remv libfoo [1.0]\nRemv libfoo [1.0]\nRemv libbar [2.0]\n"
        XCTAssertEqual(parseAptAutoremove(dup).map(\.name), ["libfoo", "libbar"])

        let flatpak = "b.App\t1.0\n\na.App\t2.0\n"
        XCTAssertEqual(parseFlatpakUpdates(flatpak).map(\.name), ["a.App", "b.App"])

        let json = #"{"dependencies":{"z":{"version":"1"},"a":{"version":"2"},"m":"3"}}"#
        XCTAssertEqual(parseNpmGlobalList(json).map(\.name), ["a", "m", "z"])
        XCTAssertEqual(parsePipxList(#"{"venvs":{"z":{"metadata":{}},"a":{"metadata":{}}}}"#).map(\.name), ["a", "z"])
    }

    /// `uv tool list` versions are digits and dots, and the leading `v` is not
    /// part of the value; a row that keeps its shape keeps that too.
    func testUvVersionsAreDigitsAndDots() {
        for row in ["ruff v0.5.0", "httpx v1.2.3", "  ruff   v1.2.3  "] {
            let entry = parseUvToolList(row)
            XCTAssertEqual(entry.count, 1, row)
            let version = entry.first?.version
            XCTAssertNotNil(version, row)
            XCTAssertTrue(version.map { $0.allSatisfy { $0.isNumber || $0 == "." } } == true, row)
        }
        for row in ["ruff v", "ruff v1.2.3 extra", "ruff 1.2.3", "v1.2.3"] {
            XCTAssertTrue(parseUvToolList(row).isEmpty, row.debugDescription)
        }
    }

    /// Truncated and overlong versions are refused rather than half-read.
    func testBunTreeRowsSplitOnTheLastAt() {
        let good = parseBunGlobalList("├── @scope/pkg@1.0.0\n├── pkg@2.0.0-rc.1\n").map { [$0.name, $0.version ?? ""] }
        XCTAssertEqual(good, [["@scope/pkg", "1.0.0"], ["pkg", "2.0.0-rc.1"]])
        for row in ["├── @scope@1.0.0", "├── pkg@", "├── pkg 1.0.0", "├── node_modules", ""] {
            XCTAssertTrue(parseBunGlobalList(row).isEmpty, row.debugDescription)
        }
    }
}

/// Fuzzes the two remaining text boundaries: the config file the user can
/// edit by hand, and the ISO timestamps that come out of the filesystem.
final class FuzzSettingsAndDateTests: XCTestCase {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static let settingsSeeds = [
        #"{"includeSystem": true, "confirmDelete": false}"#,
        #"{"ignoredLeftoverPaths": ["/a", "/b", "/a", ""]}"#,
        #"{"includeSystem": 1}"#,
        #"{"unknownKey": 1}"#,
        #"[]"#,
        #"null"#,
        "",
        "  ",
        "\u{FEFF}{}",
        #"{"ignoredLeftoverPaths": [1, 2]}"#,
    ]

    /// A settings file is either defaults, a valid object, or an error that
    /// names the file. Whatever comes back, the value is already normalized:
    /// the ignore list has no empty or duplicate entry, and normalizing again
    /// changes nothing.
    func testMutatedSettingsFileIsValidOrASettingsError() throws {
        let dir = try scratchDir()
        let url = dir.appendingPathComponent("settings.json")
        var rng = FuzzRandom(seed: 0x5EED_5E77)
        for base in FuzzSettingsAndDateTests.settingsSeeds {
            for seed in fuzzSeeds {
                let raw = FuzzMutator.text(from: base, using: &rng)
                let bytes = Data(raw.utf8)
                try bytes.write(to: url)
                do {
                    let settings = try loadSettings(from: url)
                    XCTAssertEqual(settings.normalized(), settings, "\(base.debugDescription) seed \(seed): \(raw.debugDescription)")
                    XCTAssertEqual(
                        Set(settings.ignoredLeftoverPaths).count,
                        settings.ignoredLeftoverPaths.count,
                        "\(base.debugDescription) seed \(seed): \(raw.debugDescription)"
                    )
                    for path in settings.ignoredLeftoverPaths {
                        XCTAssertFalse(path.isEmpty, "\(base.debugDescription) seed \(seed): \(raw.debugDescription)")
                        // Everything that loads has to be usable: an ignore
                        // entry that is not the reported path hides nothing.
                        XCTAssertTrue(
                            path.hasPrefix("/"),
                            "\(base.debugDescription) seed \(seed): \(raw.debugDescription)"
                        )
                    }
                } catch let error as SettingsError {
                    XCTAssertFalse(error.description.isEmpty, "\(base.debugDescription) seed \(seed): \(raw.debugDescription)")
                    XCTAssertEqual(error.errorDescription, error.description, "seed \(seed)")
                } catch {
                    XCTFail("\(base.debugDescription) seed \(seed): \(raw.debugDescription): unexpected \(error)")
                }
            }
        }
    }

    /// The write side of the same file: anything that loads goes back out
    /// through `saveSettings` and comes back identical, and what comes back is
    /// byte-for-byte what a second save would write.
    func testSettingsRoundTripThroughTheFile() throws {
        let dir = try scratchDir()
        let url = dir.appendingPathComponent("round-trip.json")
        let values: [AppAtticSettings] = [
            .default,
            AppAtticSettings(includeSystem: true, confirmDelete: false, ignoredLeftoverPaths: ["/a", "/b", "/a", ""]),
            AppAtticSettings(ignoredLeftoverPaths: ["/x y", "/ünïcode", "/a/../b", String(repeating: "/deep", count: 64)]),
        ]
        for value in values {
            try saveSettings(value, to: url)
            let loaded = try loadSettings(from: url)
            XCTAssertEqual(loaded, value.normalized())
            let first = try Data(contentsOf: url)
            try saveSettings(loaded, to: url)
            XCTAssertEqual(try Data(contentsOf: url), first)
        }
    }

    private static let dateSeeds = [
        "2026-08-17T12:30:00Z",
        "2026-08-17T12:30:00.123Z",
        "2026-08-17T12:30:00+05:30",
        "2026-08-17T12:30:00-14:00",
        "2026-08-17T12:30:00",
        "20260217T123000Z",
        "2026-02-30T00:00:00Z",
        "2026-13-01T00:00:00Z",
        "2026-08-17t12:30:00z",
        "2026-08-17 12:30:00 +0000",
        "2026-08-17",
        "2024-02-29",
        "0001-01-01T00:00:00Z",
        "9999-12-31T23:59:59Z",
    ]

    /// A timestamp that parses prints back as one our own parser reads again,
    /// and both land on the same instant. Anything else is a value, not a
    /// crash, so the rest of the space only has to survive.
    func testMutatedISODatesEitherFailOrRoundTrip() {
        let epochFloor: Double = 0
        let epochCeiling: Double = 4_102_444_800  // 2100-01-01
        XCTAssertNil(parseISODate(nil))
        var rng = FuzzRandom(seed: 0x5EED_D47E)
        for seed in fuzzSeeds {
            for base in FuzzSettingsAndDateTests.dateSeeds {
                let raw = FuzzMutator.text(from: base, using: &rng)
                guard let date = parseISODate(raw) else { continue }
                let printed = isoString(date)
                XCTAssertNotNil(printed, "seed \(seed): \(raw.debugDescription)")
                guard let printed else { continue }
                // Inside the range the formatter and the parsers agree on, a
                // timestamp that parsed must print back to the same instant.
                // Outside it the year is not a four-digit ISO year, so the
                // round trip says nothing about this code.
                let instant = date.timeIntervalSince1970
                guard instant >= epochFloor, instant < epochCeiling else { continue }
                guard let back = parseISODate(printed) else {
                    XCTFail("seed \(seed): \(printed) from \(raw.debugDescription) did not parse back")
                    continue
                }
                // The printed form is whole seconds; the parse may carry
                // milliseconds, so a sub-second gap is the whole tolerance.
                XCTAssertEqual(back.timeIntervalSince1970, instant, accuracy: 1.0, "seed \(seed): \(raw.debugDescription)")
            }
        }
    }
}

/// Fuzzes the `/etc/os-release` keyfile reader, a hand-rolled byte scan over
/// a file the distribution package wrote. The invariants are the ones the
/// scan promises: a field per line and never more, a key cut at the first `=`
/// with no `=` of its own, and both halves of every field spelled out in the
/// text the scan was handed.
final class FuzzOsReleaseTests: XCTestCase {
    private static let seeds = [
        """
        NAME="Ubuntu"
        VERSION="22.04.3 LTS (Jammy Jellyfish)"
        ID=ubuntu
        ID_LIKE=debian
        PRETTY_NAME="Ubuntu 22.04.3 LTS"
        # a comment
        BUILD_ID=1
        """,
        "ID=arch\nNAME='Arch Linux'\nPRETTY_NAME=Arch Linux\n",
        "ID=fedora\r\nVERSION_ID=39\r\n",
        "ID=slackware\nVERSION_ID=15.0\nID=slackware\nVERSION_ID=15.0\n",
        "ID\n=novalue\n=  \n   =x\n#\n#ID=commented\n",
        "  ID  =  spaced  \n",
        "ID=\"unbalanced\nVERSION='mixed\"\n",
        "ID=\nEMPTY=\n",
        "",
        "\n\n\n",
        "   \n\t\n",
        "\u{FEFF}ID=bom\n",
    ]

    /// The bytes the reader trims from both ends of a key or a value.
    private static let edgeTrim = CharacterSet(charactersIn: " \t")

    /// The number of lines the reader can emit a field for: one per run of LF or
    /// CR bytes whose line holds something other than the padding it trims.
    ///
    /// Counted over the bytes, not with `split` on the characters: "\r\n" is a
    /// single Character in Swift, so a split on "\n" or "\r" never sees it and a
    /// CRLF document reads as one line where the byte scan reads every one of
    /// them.
    private func candidateLineCount(_ text: String) -> Int {
        var lines = 0
        var inLine = false
        for byte in text.utf8 {
            if byte == 0x0A || byte == 0x0D {
                if inLine {
                    lines += 1
                    inLine = false
                }
            } else if byte != 0x20, byte != 0x09 {
                inLine = true
            }
        }
        return inLine ? lines + 1 : lines
    }

    func testMutatedOsReleaseYieldsFieldsCutFromTheText() {
        var rng = FuzzRandom(seed: 0x5EED_0F5E)
        for base in FuzzOsReleaseTests.seeds {
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng)
                let fields = parseOsRelease(text)
                let where_ = "seed \(seed): \(text.debugDescription)"

                XCTAssertEqual(parseOsRelease(text), fields, "not deterministic: \(where_)")
                XCTAssertLessThanOrEqual(fields.count, candidateLineCount(text), where_)
                for (key, value) in fields {
                    XCTAssertFalse(key.isEmpty, "empty key: \(where_)")
                    XCTAssertFalse(key.contains("="), "key carries a delimiter: \(key.debugDescription) \(where_)")
                    XCTAssertFalse(key.hasPrefix("#"), "comment read as a field: \(key.debugDescription) \(where_)")
                    XCTAssertFalse(
                        key.contains("\n") || key.contains("\r"),
                        "key spans lines: \(key.debugDescription) \(where_)"
                    )
                    XCTAssertEqual(
                        key.trimmingCharacters(in: FuzzOsReleaseTests.edgeTrim),
                        key,
                        "key padded: \(key.debugDescription) \(where_)"
                    )
                    // Quote stripping removes the outer pair, so what is left
                    // is still spelled out in the text. An empty half is
                    // spelled out by nothing, and `String.contains("")` is
                    // false for every text, so the check only applies to a
                    // value that has characters: `ID=` is a field with an
                    // empty value and the duplicate-key test below pins it as
                    // one, which is what makes it legitimate rather than lost.
                    XCTAssertTrue(text.contains(key), "key not in the text: \(key.debugDescription) \(where_)")
                    XCTAssertTrue(
                        value.isEmpty || text.contains(value),
                        "value not in the text: \(value.debugDescription) \(where_)"
                    )
                }
            }
        }
    }

    /// A key the reader saw twice keeps the last value, and a run of lines
    /// with no `=` on it is not a field at all.
    func testDuplicateKeysAndLinesWithoutASeparator() {
        XCTAssertEqual(parseOsRelease("ID=first\nID=second\n"), ["ID": "second"])
        XCTAssertEqual(parseOsRelease("ID\nNAME=x\n"), ["NAME": "x"])
        XCTAssertTrue(parseOsRelease("#ID=x\n").isEmpty)
        XCTAssertTrue(parseOsRelease("=x\n").isEmpty)
        XCTAssertEqual(parseOsRelease("ID=x\r\nNAME=y\n"), ["ID": "x", "NAME": "y"])
        XCTAssertEqual(parseOsRelease("ID = x "), ["ID": "x"])
        XCTAssertEqual(parseOsRelease("ID=\"x y\""), ["ID": "x y"])
        XCTAssertEqual(parseOsRelease("ID='x'"), ["ID": "x"])
        XCTAssertEqual(parseOsRelease("ID="), ["ID": ""])
        for blank in ["", " ", "\t", "\n", "\r\n", "   \t \n "] {
            XCTAssertTrue(parseOsRelease(blank).isEmpty, blank.debugDescription)
        }
    }
}
