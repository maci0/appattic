import XCTest
@testable import AppAtticScan

/// Fuzzes the two XML readers that walk files other programs write:
/// `recently-used.xbel` and GNOME Shell's `application_state`. Both feed
/// every `application` attribute through a URL, a date parser and a key
/// normalizer, so the harness asserts what comes out of the walk: a key is
/// always lowercased, never empty, always cut from the file, never dated
/// after the scan, and the same on every read of the same bytes.
final class FuzzXMLUsageTests: XCTestCase {
    /// Every seed carries timestamps well before the fixed `now` below, so a
    /// date that parses is a date the readers must keep.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let xbelSeeds = [
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop/bookmark">
          <bookmark href="file:///tmp/doc.pdf" modified="2026-05-02T18:00:00Z">
            <info>
              <metadata>
                <bookmark:applications>
                  <application name="org.mozilla.firefox" exec="/usr/lib/firefox/firefox" modified="2026-05-02T18:00:01Z" count="3"/>
                  <application name="Text Editor" exec="/usr/bin/gedit" modified="2026-05-01T09:00:00Z"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        </xbel>
        """,
        """
        <xbel><bookmark visited="2026-04-30T12:00:00Z">
          <info><metadata><bookmark:applications>
            <application name="OnlyVisited" exec="env FOO=bar /opt/app/bin/app --flag"/>
          </bookmark:applications></metadata></info>
        </bookmark></xbel>
        """,
        """
        <x:application xmlns:x="http://www.freedesktop.org/standards/desktop/bookmark"
           name="n:firefox" exec="NoSlash" modified="2026-05-02T18:00:01Z"/>
        <application name="   Padded   " exec="  /usr/bin/pad  " visited="2026-03-03T03:03:03Z"/>
        <application name="NoDate" exec="/usr/bin/nodate"/>
        <application exec="/usr/bin/empty"/>
        """,
        "<xbel></xbel>",
        "",
        "not xml at all",
        "<application",
        "<application name=",
    ]

    private static let stateSeeds = [
        """
        <?xml version="1.0"?>
        <application-state>
          <application id="org.mozilla.firefox.desktop" score="12.0" last-seen="1717200000"/>
          <application id="Text Editor" score="1.0" last-seen="1717200005.5"/>
        </application-state>
        """,
        """
        <application-state>
          <application id="org.example.nan.desktop" last-seen="nan"/>
          <application id="org.example.infinity.desktop" last-seen="inf"/>
          <application id="org.example.negative.desktop" last-seen="-1"/>
          <application id="org.example.empty.desktop" last-seen=""/>
          <application id="" last-seen="1717200000"/>
          <application last-seen="1717200000"/>
        </application-state>
        """,
        """
        <application-state>
          <application id="/usr/share/applications/gedit.desktop" last-seen="1717200000"/>
          <application id="chrome.desktop" last-seen="1717200000"/>
          <application id="proc.desktop" last-seen="1717200000"/>
          <application id="a.b" last-seen="1717200000"/>
        </application-state>
        """,
        """
        <application-state>
          <application id="dup.desktop" last-seen="1717200000"/>
          <application id="dup.desktop" last-seen="1717200001"/>
        </application-state>
        """,
        "<application-state/>",
        "",
        "<application",
    ]

    private func scratchPath(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-fuzz-xml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name).path
    }

    /// The text an attribute value can carry, folded the way the XML parser is
    /// required to fold it: attribute-value normalization turns every tab, CR
    /// and LF inside an attribute into a single space before the document
    /// reaches a delegate, so `id="ged\tit"` is handed over as `ged it`. Every
    /// key here is cut from an attribute value, so this is the text to look the
    /// key up in; against the raw bytes the check would fail on documents that
    /// are perfectly well formed.
    private static func attributeNormalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// What both readers must hold for any document: a key is lowercased and
    /// trimmed, appears in the bytes the parser was handed, and is dated no
    /// later than the scan plus the clock-skew allowance.
    private func assertWellFormed(
        _ hits: [String: Date],
        in text: String,
        where_: String
    ) {
        let lowercased = posixLowercased(FuzzXMLUsageTests.attributeNormalized(text))
        for (key, date) in hits {
            XCTAssertFalse(key.isEmpty, "empty key \(where_)")
            XCTAssertEqual(key, posixLowercased(key), "not lowercased: \(key.debugDescription) \(where_)")
            XCTAssertEqual(
                key.trimmingCharacters(in: .whitespaces),
                key,
                "not trimmed: \(key.debugDescription) \(where_)"
            )
            XCTAssertTrue(
                lowercased.contains(key),
                "key not in the file: \(key.debugDescription) \(where_)"
            )
            XCTAssertLessThanOrEqual(
                date.timeIntervalSince1970,
                FuzzXMLUsageTests.now.addingTimeInterval(launchTimestampFutureTolerance).timeIntervalSince1970,
                "dated in the future: \(key.debugDescription) \(where_)"
            )
        }
    }

    /// The same mutated document read through both XML readers, twice each:
    /// the walk must be deterministic, and whatever it indexed must be
    /// well-formed against the bytes that produced it.
    func testMutatedUsageXMLYieldsKeysCutFromTheFile() throws {
        var rng = FuzzRandom(seed: 0x5EED_58EE)
        let path = try scratchPath("usage.xml")
        let url = URL(fileURLWithPath: path)
        let readers: [(String, (String) -> [String: Date])] = [
            ("xbel", { parseRecentlyUsedXbel($0, now: FuzzXMLUsageTests.now) }),
            ("gnome-state", { parseGnomeApplicationState($0, now: FuzzXMLUsageTests.now) }),
        ]
        for (label, seeds) in [("xbel", FuzzXMLUsageTests.xbelSeeds), ("state", FuzzXMLUsageTests.stateSeeds)] {
            for base in seeds {
                for seed in fuzzSeeds {
                    let text = FuzzMutator.text(from: base, using: &rng)
                    let where_ = "\(label) seed \(seed): \(text.debugDescription)"
                    try Data(text.utf8).write(to: url)

                    for (name, read) in readers {
                        let first = read(path)
                        XCTAssertEqual(read(path), first, "\(name) not deterministic: \(where_)")
                        assertWellFormed(first, in: text, where_: "\(name) \(where_)")
                    }
                }
            }
        }
    }

    /// A key is derived from an attribute, so a document with no `application`
    /// element anywhere in it indexes nothing. The mutation is checked against
    /// the tag spelling the sinks look for, prefix included, so a document that
    /// never opens one cannot produce a hit.
    ///
    /// No seed carries a DTD: an internal entity expands into a key that is no
    /// longer a substring of the file, which the well-formedness check in
    /// `testMutatedUsageXMLYieldsKeysCutFromTheFile` would read as a bug. The
    /// entity behaviour has its own test below.
    func testDocumentWithoutAnApplicationElementIndexesNothing() throws {
        var rng = FuzzRandom(seed: 0x5EED_0FF1)
        let path = try scratchPath("no-app.xml")
        let bases = [
            "<?xml version=\"1.0\"?>\n<application-state><bookmark id=\"x\" last-seen=\"1717200000\"/></application-state>",
            "<xbel><bookmark href=\"file:///tmp/a\" modified=\"2026-05-02T18:00:00Z\"><info/></bookmark></xbel>",
        ]
        for base in bases {
            for seed in fuzzSeeds {
                let text = FuzzMutator.text(from: base, using: &rng)
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
                let where_ = "seed \(seed): \(text.debugDescription)"
                guard !FuzzXMLUsageTests.opensApplicationElement(text) else { continue }
                XCTAssertTrue(
                    parseGnomeApplicationState(path, now: FuzzXMLUsageTests.now).isEmpty,
                    "gnome-state indexed with no application element: \(where_)"
                )
                XCTAssertTrue(
                    parseRecentlyUsedXbel(path, now: FuzzXMLUsageTests.now).isEmpty,
                    "xbel indexed with no application element: \(where_)"
                )
            }
        }
    }

    /// True where the text opens an element whose tag is `application`, with or
    /// without a namespace prefix. `<application-state` and `<applications>`
    /// are different tags and do not count.
    private static func opensApplicationElement(_ text: String) -> Bool {
        let name = "application"
        let prefixable: Set<Character> = ["-", ".", "_"]
        let delimiters: Set<Character> = [" ", "\t", "\n", "\r", ">", "/", "="]
        var search = text.startIndex
        while let hit = text.range(of: name, range: search..<text.endIndex) {
            search = hit.upperBound
            guard let open = text[text.startIndex..<hit.lowerBound].lastIndex(of: "<"),
                  hit.lowerBound > open else { continue }
            let prefix = text[text.index(after: open)..<hit.lowerBound]
            let prefixIsName = prefix.isEmpty
                || prefix.allSatisfy { $0.isLetter || $0.isNumber || prefixable.contains($0) }
            if prefixIsName, hit.upperBound < text.endIndex, delimiters.contains(text[hit.upperBound]) {
                return true
            }
        }
        return false
    }

    /// The DTD is attacker-shaped: a general entity that expands to the
    /// contents of a file the parser must not read. Both readers resolve
    /// external entities off, so the sentinel never reaches a key, and the
    /// parser stops at the entity rather than reporting it as content.
    func testExternalEntityIsNotResolved() throws {
        let dir = try scratchPath("secret")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let secret = (dir as NSString).appendingPathComponent("secret.txt")
        try Data("SENTINEL-ENTITY-CONTENT".utf8).write(to: URL(fileURLWithPath: secret))

        let docs = [
            """
            <?xml version="1.0"?>
            <!DOCTYPE application-state [ <!ENTITY xxe SYSTEM "file://\(secret)"> ]>
            <application-state><application id="&xxe;" last-seen="1717200000"/></application-state>
            """,
            """
            <?xml version="1.0"?>
            <!DOCTYPE xbel [ <!ENTITY xxe SYSTEM "file://\(secret)"> ]>
            <xbel><bookmark modified="2026-05-02T18:00:00Z">
              <application name="&xxe;" exec="/usr/bin/&xxe;" modified="2026-05-02T18:00:01Z"/>
            </bookmark></xbel>
            """,
        ]
        for (index, doc) in docs.enumerated() {
            let path = try scratchPath("xxe-\(index).xml")
            try Data(doc.utf8).write(to: URL(fileURLWithPath: path))
            let state = parseGnomeApplicationState(path, now: FuzzXMLUsageTests.now)
            let xbel = parseRecentlyUsedXbel(path, now: FuzzXMLUsageTests.now)
            for (key, _) in state {
                XCTAssertFalse(key.contains("SENTINEL"), "external entity resolved into a state key: \(key.debugDescription)")
            }
            for (key, _) in xbel {
                XCTAssertFalse(key.contains("SENTINEL"), "external entity resolved into an xbel key: \(key.debugDescription)")
            }
        }
    }

    /// A document that nests the tag a hundred times is well within what a
    /// generator can emit, and the walk has to bottom out rather than blow the
    /// stack. A real file never nests this deep, so the reader is allowed to
    /// index nothing; what it is not allowed to do is trap.
    func testDeeplyNestedDocumentDoesNotTrap() throws {
        let path = try scratchPath("deep.xml")
        let depth = 200
        let xbel = (0..<depth).map { "  <bookmark href=\"file:///tmp/\($0)\">" }.joined(separator: "\n")
            + "\n" + String(repeating: "<application name=\"deep\" exec=\"/usr/bin/deep\" modified=\"2026-05-02T18:00:01Z\">", count: depth)
            + "\n" + String(repeating: "</application>", count: depth) + "\n"
            + String(repeating: "</bookmark>\n", count: depth)
        try Data(xbel.utf8).write(to: URL(fileURLWithPath: path))
        let hits = parseRecentlyUsedXbel(path, now: FuzzXMLUsageTests.now)
        assertWellFormed(hits, in: xbel, where_: "deep xbel")

        let state = String(repeating: "<application-state><application id=\"deep.desktop\" last-seen=\"1717200000\">", count: depth)
            + String(repeating: "</application></application-state>", count: depth)
        try Data(state.utf8).write(to: URL(fileURLWithPath: path))
        assertWellFormed(parseGnomeApplicationState(path, now: FuzzXMLUsageTests.now), in: state, where_: "deep state")
    }
}
