import XCTest
@testable import AppAtticScan

/// Fuzzes the shell history reader. One file goes through two independent
/// implementations, the byte scan and the regex scan, picked by whether the
/// bytes carry a high bit, so the harness mutates ASCII and holds the two to
/// the same answer: a history file must not index a different set of commands
/// because of which scanner read it.
final class FuzzHistoryTests: XCTestCase {
    /// The most epoch a scanner can record: 11 digits is the widest run either
    /// scanner accepts, and `dateFromUnixEpoch` passes a value that small
    /// through unchanged.
    private static let epochCeiling: TimeInterval = 100_000_000_000

    /// The ASCII half of the mutation set, less CR. The two scanners only have
    /// to agree where the regex path's `\w`, `\s` and `\d` are the ASCII
    /// classes, so a byte above 0x7F is out of scope. CR is out too, for a
    /// different reason: ICU reads a CR as a line terminator, so the `(.*)$` in
    /// `tsRE` and `fishCmdRE` stops at one, and a timestamp line carrying a CR
    /// in the middle of the command matches neither pattern and indexes
    /// nothing, where the byte scanner splits the command on it and indexes
    /// the first token. That is a difference between the two implementations'
    /// grammars, so the mutation does not build it. CR at the end of a line is
    /// the shape a real file has, and `testStrayCarriageReturnStillIndexesTheCommand`
    /// pins that both scanners read it.
    private static let historyHotBytes: [UInt8] = FuzzMutator.asciiHotBytes.filter { $0 != 0x0D }

    private static let historySeeds = [
        ": 1717200000:0;jq .\n: 1717200000:5;git status\n: 1717200000:0;FOO=bar curl example.com\n",
        ": 1717200000:0;jq .\r\n: 1717200000:5;git status\r\n",
        "jq\n#comment\n\nFOO=bar jq .\n/usr/bin/jq --version\n",
        ": 1717200000:0;\n:1717200000:0;jq\n:  1717200000:0;  jq  \n: 171720000:0;short\n",
        ": 171720000000:0;long\n: 1717200000:;nodur\n: 1717200000:0nosemi\n  : 1717200000:0;indented\n",
        ": 9999999999:0;far-future\n: 99999999999:0;edge\n: 1000000000:0;early\n",
        ": 1717200000:0;crlftool\r\r\n: 1717200001:0;jq .\r\n",
    ]

    private static let fishSeeds = [
        "- cmd: jq .\n  when: 1717200000\n- cmd: git status\n  when: 1717200005\n",
        "- cmd: jq .\r\n  when: 1717200000\r\n",
        "- cmd:\n- cmd:  spaced  \n  when:   1717200001\nwhen: 1717200002\n  when:1717200003\n",
        "- cmd: /usr/bin/jq --version\n  when: 1717200008\nunrelated line\n\n",
        "- cmd: FOO=bar jq .\n  when: 1717200009\n- cmd: no-when\n- cmd: a//b arg\n",
    ]

    private func scratchPath(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-fuzz-hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name).path
    }

    /// What both scanners must hold for any input: only whole command tokens
    /// reach the index, and they reach it lowercased. A token carrying a space,
    /// a slash or a byte the token grammar rejects came from a bad offset in
    /// the scan. With a `keep` filter, an indexed token is one whose spelling
    /// was in the filter, so it is in the filter lowercased.
    private func assertWellFormed(_ index: HistoryIndex, keep: Set<String>?, _ where_: String) {
        let keepLowercased = keep.map { Set($0.map(posixLowercased)) }
        for token in index.everUsed {
            XCTAssertEqual(token, posixLowercased(token), "not lowercased: \(where_)")
            XCTAssertTrue(fullMatch(cmdTokenRE, token), "not a command token: \(token.debugDescription) \(where_)")
            if let keepLowercased {
                XCTAssertTrue(keepLowercased.contains(token), "index holds \(token.debugDescription) past the filter \(where_)")
            }
        }
        for (token, date) in index.lastSeen {
            XCTAssertTrue(index.everUsed.contains(token), "\(token.debugDescription) has a time but was never used \(where_)")
            let epoch = date.timeIntervalSince1970
            XCTAssertTrue(epoch >= 0 && epoch < FuzzHistoryTests.epochCeiling, "\(token.debugDescription) at \(epoch) \(where_)")
            if let oldest = index.oldestSeen {
                XCTAssertLessThanOrEqual(oldest.timeIntervalSince1970, epoch, "\(token.debugDescription) predates oldestSeen \(where_)")
            }
        }
    }

    /// The two scanners index the same commands, at the same times, from the
    /// same ASCII text, with and without a `keep` filter.
    func testMutatedHistoryAgreesAcrossBothScanPaths() {
        var rng = FuzzRandom(seed: 0x5EED_1157)
        for keep in [nil, Set(["Jq", "git"])] as [Set<String>?] {
            for base in FuzzHistoryTests.historySeeds + FuzzHistoryTests.fishSeeds {
                for seed in fuzzSeeds {
                    let text = FuzzMutator.text(from: base, using: &rng, hotBytes: FuzzHistoryTests.historyHotBytes)
                    let where_ = "seed \(seed) keep \(keep?.sorted() ?? ["all"]): \(text.debugDescription)"
                    let fish = base.hasPrefix("- cmd")

                    var fast = HistoryIndex()
                    var slow = HistoryIndex()
                    if fish {
                        parseFishHistoryASCII(Array(text.utf8), index: &fast, keep: keep)
                        parseFishHistoryRegex(text, index: &slow, keep: keep)
                    } else {
                        parseHistoryASCII(Array(text.utf8), index: &fast, keep: keep)
                        parseHistoryFileRegex(text, index: &slow, keep: keep)
                    }
                    XCTAssertEqual(fast.everUsed, slow.everUsed, where_)
                    XCTAssertEqual(fast.lastSeen, slow.lastSeen, where_)
                    XCTAssertEqual(fast.oldestSeen, slow.oldestSeen, where_)
                    assertWellFormed(fast, keep: keep, where_)
                    assertWellFormed(slow, keep: keep, where_)
                }
            }
        }
    }

    /// The same text through the file the scanner actually opens, which is the
    /// only path production takes: read the bytes back, index them, get what
    /// the in-process scan got, and get it again on a second read. The
    /// mutation stays ASCII so the file holds exactly the bytes the harness
    /// wrote: `decodeUTF8` drops a BOM and nothing here can carry one.
    func testMutatedHistoryFileRoundTripsThroughTheFile() throws {
        var rng = FuzzRandom(seed: 0x5EED_F11E)
        for base in FuzzHistoryTests.historySeeds + FuzzHistoryTests.fishSeeds {
            let fish = base.hasPrefix("- cmd")
            let path = try scratchPath(fish ? "fish_history" : ".zsh_history")
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng, hotBytes: FuzzHistoryTests.historyHotBytes)
                let where_ = "seed \(seed): \(text.debugDescription)"
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))

                var fromFile = HistoryIndex()
                var second = HistoryIndex()
                var direct = HistoryIndex()
                if fish {
                    parseFishHistory(path, index: &fromFile, keep: nil)
                    parseFishHistory(path, index: &second, keep: nil)
                    parseFishHistoryASCII(Array(text.utf8), index: &direct, keep: nil)
                } else {
                    parseHistoryFile(path, index: &fromFile, keep: nil)
                    parseHistoryFile(path, index: &second, keep: nil)
                    parseHistoryASCII(Array(text.utf8), index: &direct, keep: nil)
                }

                XCTAssertEqual(fromFile.everUsed, second.everUsed, "not deterministic: \(where_)")
                XCTAssertEqual(fromFile.lastSeen, second.lastSeen, "not deterministic: \(where_)")
                XCTAssertEqual(fromFile.everUsed, direct.everUsed, where_)
                XCTAssertEqual(fromFile.lastSeen, direct.lastSeen, where_)
                XCTAssertEqual(fromFile.oldestSeen, direct.oldestSeen, where_)
                assertWellFormed(fromFile, keep: nil, where_)
            }
        }
    }

    /// CRs that did not all land in the terminator: the regex path normalizes
    /// the CRLF away and reads the command, so the byte path has to read it
    /// too rather than carry the leftover CR on the token and drop the line.
    func testStrayCarriageReturnStillIndexesTheCommand() {
        for text in [
            ": 1717200000:0;crlftool\r\r\n",
            ": 1717200000:0;crlftool\r\r",
            ": 1717200000:0;crlftool\r",
        ] {
            var fast = HistoryIndex()
            var slow = HistoryIndex()
            parseHistoryASCII(Array(text.utf8), index: &fast, keep: nil)
            parseHistoryFileRegex(text, index: &slow, keep: nil)
            XCTAssertTrue(fast.everUsed.contains("crlftool"), "\(text.debugDescription) -> \(fast.everUsed)")
            XCTAssertEqual(fast.everUsed, slow.everUsed, text.debugDescription)
            XCTAssertEqual(fast.lastSeen, slow.lastSeen, text.debugDescription)
        }
        let fish = "- cmd: fishtool\r\r\n  when: 1717200000\r\r\n"
        var fastFish = HistoryIndex()
        var slowFish = HistoryIndex()
        parseFishHistoryASCII(Array(fish.utf8), index: &fastFish, keep: nil)
        parseFishHistoryRegex(fish, index: &slowFish, keep: nil)
        XCTAssertTrue(fastFish.everUsed.contains("fishtool"), "\(fish.debugDescription) -> \(fastFish.everUsed)")
        XCTAssertEqual(fastFish.everUsed, slowFish.everUsed, fish.debugDescription)
        XCTAssertEqual(fastFish.lastSeen, slowFish.lastSeen, fish.debugDescription)
    }

    /// A history file of blank lines, comments, and an epoch with no command
    /// behind it indexes nothing, in either format, through either scanner.
    func testHistoryWithNoCommandIndexesNothing() {
        for text in ["", "\n", "\r\n", "   \n\t\n", "#only comments\n#\n", ": 1717200000:0;\n", ": 1717200000:0\n"] {
            for fish in [false, true] {
                for asciiPath in [false, true] {
                    var index = HistoryIndex()
                    if fish {
                        if asciiPath {
                            parseFishHistoryASCII(Array(text.utf8), index: &index, keep: nil)
                        } else {
                            parseFishHistoryRegex(text, index: &index, keep: nil)
                        }
                    } else if asciiPath {
                        parseHistoryASCII(Array(text.utf8), index: &index, keep: nil)
                    } else {
                        parseHistoryFileRegex(text, index: &index, keep: nil)
                    }
                    XCTAssertTrue(index.everUsed.isEmpty, "\(text.debugDescription) fish \(fish) ascii \(asciiPath)")
                    XCTAssertTrue(index.lastSeen.isEmpty, "\(text.debugDescription) fish \(fish) ascii \(asciiPath)")
                    XCTAssertNil(index.oldestSeen, "\(text.debugDescription) fish \(fish) ascii \(asciiPath)")
                }
            }
        }
    }
}

/// Fuzzes the `.desktop` keyfile reader, a byte scanner over a file this
/// process did not write, and the `Exec` tokenizer that reads its command.
final class FuzzDesktopEntryTests: XCTestCase {
    /// The bytes `readDesktop` trims from both ends of a line, and no others.
    private static let lineTrim = CharacterSet(charactersIn: " \t\r")

    private static let desktopSeeds = [
        """
        [Desktop Entry]
        Type=Application
        Name=Text Editor
        Exec=/usr/bin/gedit %U
        Comment=Edit text
        """,
        """
        # a comment
        [Desktop Entry]
        Type=Application
        Name=App
        Exec=env FOO=bar /opt/app/bin/app --flag "two words"
        NoDisplay=false
        """,
        """
        [Desktop Entry]
        Name=Dupe
        Name=Second
        Exec=/bin/sh -c "echo hi"
        """,
        """
        [Desktop Action New]
        Name=New
        Exec=/usr/bin/app --new

        [Desktop Entry]
        Type=Application
        Name=App\\sName
        Exec=env A=1 B=2 /usr/bin/app
        """,
        "[Desktop Entry]\nType=Link\nName=Only\n",
        "",
        "\n\n#\n",
    ]

    private func scratchDesktop() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-fuzz-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("app.desktop").path
    }

    /// A key the scanner cut is the text between the start of a line and its
    /// first `=`, trimmed: it carries no `=` of its own, no line break, and
    /// nothing padded against either end. A dict is never larger than the lines
    /// it could have come from, only a trimmed line spelling the group header
    /// opens the entry, and the same file read twice reads the same.
    func testMutatedDesktopEntryYieldsTrimmedKeysFromTheFile() throws {
        var rng = FuzzRandom(seed: 0x5EED_0E57)
        let path = try scratchDesktop()
        for base in FuzzDesktopEntryTests.desktopSeeds {
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng)
                let where_ = "seed \(seed): \(text.debugDescription)"
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))

                let first = readDesktop(path)
                XCTAssertEqual(readDesktop(path), first, "not deterministic: \(where_)")

                var candidateLines = 0
                var hasEntryHeader = false
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: FuzzDesktopEntryTests.lineTrim)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    candidateLines += 1
                    if trimmed == "[Desktop Entry]" { hasEntryHeader = true }
                }
                XCTAssertLessThanOrEqual(first.count, candidateLines, where_)
                if !hasEntryHeader {
                    XCTAssertTrue(first.isEmpty, "keys read with no [Desktop Entry] header: \(where_)")
                }
                for (key, _) in first {
                    XCTAssertFalse(key.contains("="), "key carries a delimiter: \(key.debugDescription) \(where_)")
                    XCTAssertFalse(key.contains("\n"), "key spans lines: \(key.debugDescription) \(where_)")
                    XCTAssertEqual(
                        key.trimmingCharacters(in: FuzzDesktopEntryTests.lineTrim),
                        key,
                        "key padded: \(key.debugDescription) \(where_)"
                    )
                }
            }
        }
    }

    /// A duplicate key keeps its first value, and the env assignments in front
    /// of a command are dropped, but only the ones that lead: the scan stops at
    /// the first token that is not a `NAME=` pair.
    func testDesktopEntryKeepsFirstValueAndSplitsPlainExecLines() throws {
        let dup = try readDesktopContent("[Desktop Entry]\nName=First\nName=Second\n")
        XCTAssertEqual(dup["Name"], "First")
        XCTAssertEqual(dup.count, 1)

        XCTAssertEqual(execTokens("/usr/bin/gedit %U"), ["/usr/bin/gedit", "%U"])
        XCTAssertEqual(execTokens("FOO=bar /usr/bin/app --flag"), ["/usr/bin/app", "--flag"])
        XCTAssertEqual(execTokens("  /usr/bin/app  "), ["/usr/bin/app"])
        XCTAssertEqual(execTokens("FOO=1 BAR=2 app"), ["app"])
        XCTAssertEqual(execTokens("FOO=1"), [])
        XCTAssertEqual(execTokens("env FOO=bar"), ["env", "FOO=bar"])
        XCTAssertEqual(execTokens("\"two words\" tail"), ["two words", "tail"])
    }

    /// `Exec` tokenization under mutation: a quoted span and a backslash escape
    /// both fold into the token they appear in, no token comes out holding a
    /// quote, and every character that is neither quote, backslash nor
    /// whitespace still appears in the tokens, in the order it was written. The
    /// env assignments in front are the only tokens dropped, so the order is
    /// checked as a subsequence.
    func testMutatedExecLinesKeepTheirTextInOrder() {
        let execSeeds = [
            "/usr/bin/gedit %U",
            "env FOO=bar /opt/app/bin/app --flag \"two words\"",
            "/bin/sh -c \"echo hi\"",
            "flatpak run org.gimp.GIMP",
            "FOO=1 BAR=2 app --a \"b c\" d",
        ]
        var rng = FuzzRandom(seed: 0x5EED_E4EC)
        for base in execSeeds {
            for seed in fuzzSeeds {
                let exec = FuzzMutator.text(from: base, using: &rng)
                let tokens = execTokens(exec)
                let where_ = "seed \(seed): \(exec.debugDescription) -> \(tokens)"
                for token in tokens {
                    XCTAssertFalse(token.contains("\""), "quote left in token: \(where_)")
                }
                let expected = exec.filter { $0 != "\"" && $0 != "\\" && !$0.isWhitespace }
                let actual = tokens.joined().filter { $0 != "\"" && $0 != "\\" }
                var cursor = actual.makeIterator()
                XCTAssertTrue(
                    expected.allSatisfy { char in cursor.next() == char },
                    "text lost or reordered: \(where_)"
                )
            }
        }
    }

    /// The reader behind `parseDesktopFile`, from text rather than from a path
    /// the caller already has.
    private func readDesktopContent(_ text: String) throws -> [String: String] {
        let path = try scratchDesktop()
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return readDesktop(path)
    }
}
