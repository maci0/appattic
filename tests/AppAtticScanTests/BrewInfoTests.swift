import XCTest
@testable import AppAtticScan

final class BrewInfoTests: XCTestCase {
    func testRefusedCaskToken() {
        let err = "Error: Refusing to load cask dail8859/notepadnext/notepadnext from untrusted tap dail8859/notepadnext.\n"
        XCTAssertEqual(refusedCaskToken(err), "notepadnext")
        XCTAssertNil(refusedCaskToken("some other error"))
    }

    func testFetchInfoJSONUsesInstalledFlags() {
        var calls: [[String]] = []
        let data = fetchInfoJSON(brew: "/opt/homebrew/bin/brew") { cmd, _ in
            calls.append(cmd)
            if cmd.contains("--formula") {
                return (0, #"{"formulae":[{"name":"wget","desc":"Internet file retriever"}],"casks":[]}"#, "")
            }
            if cmd.contains("--cask") {
                return (0, #"{"formulae":[],"casks":[{"token":"iterm2","desc":"Terminal emulator"}]}"#, "")
            }
            return (1, "", "unexpected")
        }
        XCTAssertEqual((data["formulae"] as? [[String: Any]])?[0]["desc"] as? String, "Internet file retriever")
        XCTAssertEqual((data["casks"] as? [[String: Any]])?[0]["token"] as? String, "iterm2")
        XCTAssertTrue(calls.contains { $0.contains("--formula") && $0.contains("--installed") })
        XCTAssertTrue(calls.contains { $0.contains("--cask") && $0.contains("--installed") })
        // The whole point of `--installed`: names are never passed as arguments.
        for cmd in calls {
            XCTAssertFalse(cmd.contains("notepadnext"), cmd.joined(separator: " "))
            XCTAssertFalse(cmd.contains("wget"), cmd.joined(separator: " "))
        }
    }

    func testInfoJSONForNamesDropsUntrustedCask() {
        var calls: [[String]] = []
        let data = infoJSONForNames(brew: "/opt/homebrew/bin/brew", names: ["iterm2", "notepadnext"]) { cmd, _ in
            calls.append(cmd)
            if cmd.contains("notepadnext") {
                return (1, "", "Error: Refusing to load cask dail8859/notepadnext/notepadnext from untrusted tap dail8859/notepadnext.\n")
            }
            return (0, #"{"formulae":[],"casks":[{"token":"iterm2","desc":"Terminal emulator"}]}"#, "")
        }
        XCTAssertEqual((data["casks"] as? [[String: Any]])?[0]["desc"] as? String, "Terminal emulator")
        XCTAssertTrue(calls.contains { $0.contains("notepadnext") })
        XCTAssertTrue(calls.contains { $0.contains("info") && !$0.contains("notepadnext") })
    }

    func testCaskArtifactDictYieldsAppName() {
        XCTAssertEqual(caskArtifactAppNames(["Firefox.app"]), ["Firefox.app"])
        XCTAssertEqual(caskArtifactAppNames([["Source.app": "Firefox.app"]]), ["Firefox.app"])
        XCTAssertEqual(
            caskArtifactAppNames([["ZeroTier One.app": ["target": "ZeroTier.app"]]]),
            ["ZeroTier.app"]
        )
        XCTAssertEqual(
            caskArtifactAppNames([["app": "Wrapped.app"]]),
            ["Wrapped.app"]
        )
        XCTAssertEqual(
            caskArtifactAppNames(fromArtifacts: [
                ["app": ["Firefox.app"]],
                "Bare.app",
                ["app": "StringApp.app"],
            ]),
            ["Firefox.app", "Bare.app", "StringApp.app"]
        )
        XCTAssertEqual(
            caskArtifactAppNames(fromArtifacts: [["BBEdit.app"], ["LibreOffice.app"]]),
            ["BBEdit.app", "LibreOffice.app"]
        )
    }

    /// A cask can ship several artifacts under one dict. The name has to be the
    /// same on every run: Dictionary order is hash-seeded per process.
    func testCaskArtifactDictNameIsDeterministic() {
        let artifacts: [Any] = [[
            "args": ["--no-quarantine"],
            "target": "ZeroTier.app",
            "zap": true,
        ]]
        for _ in 0..<32 {
            XCTAssertEqual(caskArtifactAppNames(artifacts), ["ZeroTier.app"])
        }
        // Sorted key order picks "Bin" over "Doc", and only every run, not once.
        XCTAssertEqual(
            caskArtifactAppNames([["Bin": ["target": "Tool.app"], "Doc": ["target": "Guide.app"]]]),
            ["Tool.app"]
        )
    }

    func testRefusedCasksParseTap() {
        let err = "Error: Refusing to load cask dail8859/notepadnext/notepadnext from untrusted tap dail8859/notepadnext.\n"
        let hits = refusedCasks(from: err)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].name, "notepadnext")
        XCTAssertEqual(hits[0].tap, "dail8859/notepadnext")
    }

    func testCollectBrewMarksOutdatedFailedOnError() {
        let snap = collectBrew(which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil }) { cmd, _ in
            if cmd.contains("outdated") { return (1, "", "failed to fetch") }
            if cmd.contains("list") && cmd.contains("--formula") { return (0, "", "") }
            if cmd.contains("list") && cmd.contains("--cask") { return (0, "", "") }
            if cmd.contains("leaves") { return (0, "", "") }
            if cmd.contains("info") { return (0, #"{"formulae":[],"casks":[]}"#, "") }
            if cmd.contains("services") { return (0, "Name State\n", "") }
            return (0, "", "")
        }
        XCTAssertTrue(snap.outdatedFailed)
        XCTAssertTrue(snap.outdated.isEmpty)
    }

    /// A success status carrying a payload that is not JSON is a broken answer,
    /// not the answer "nothing is outdated". The empty list it would leave
    /// behind is what the report prints and the scan cache keeps for a day.
    func testBrewOutdatedUnparsablePayloadIsAFailedCheck() {
        let result = queryBrewStatus("/opt/homebrew/bin/brew", run: { _, _ in (0, "Error: unknown option", "") })
        XCTAssertTrue(result.pkgs.isEmpty)
        XCTAssertTrue(result.failed)
    }

    /// The same rule for the installed list. A `brew list` that failed leaves
    /// the whole Homebrew category reading as empty software, so it is a
    /// recorded check failure and the scan stays out of the cache.
    func testCollectBrewRecordsAFailedInstalledListing() {
        resetScanCheckFailures()
        defer { resetScanCheckFailures() }
        let snap = collectBrew(which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil }) { cmd, _ in
            if cmd.contains("outdated") { return (0, #"{"formulae":[],"casks":[]}"#, "") }
            if cmd.contains("list") { return (1, "", "Error: broken install") }
            return (0, "", "")
        }
        XCTAssertTrue(snap.formulas.isEmpty)
        XCTAssertTrue(snap.casks.isEmpty)
        XCTAssertEqual(scanCheckFailures(), ["brew-cask-list", "brew-formula-list"])
    }

    /// A successful outdated answer has to reach the snapshot, or the report
    /// prints "nothing is outdated" for a machine with an outdated formula.
    /// The summary comes from the same `brew info` call the software list uses,
    /// so an empty outdated list would hide that path too.
    func testCollectBrewOutdatedSuccessIsComplete() {
        let snap = collectBrew(which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil }) { cmd, _ in
            if cmd.contains("outdated") {
                return (0, #"{"formulae":[{"name":"wget","installed_versions":["1.20.3"],"current_version":"1.24.5"}],"casks":[]}"#, "")
            }
            if cmd.contains("list") && cmd.contains("--formula") { return (0, "wget\n", "") }
            if cmd.contains("list") && cmd.contains("--cask") { return (0, "", "") }
            if cmd.contains("leaves") { return (0, "", "") }
            if cmd.contains("info") {
                return (0, #"{"formulae":[{"name":"wget","desc":"Internet file retriever"}],"casks":[]}"#, "")
            }
            if cmd.contains("services") { return (0, "Name State\n", "") }
            return (0, "", "")
        }
        XCTAssertFalse(snap.outdatedFailed)
        XCTAssertEqual(snap.outdated.map(\.name), ["wget"])
        XCTAssertEqual(snap.outdated.map(\.manager), ["brew-formula"])
        XCTAssertEqual(snap.outdated.map(\.currentVersion), ["1.20.3"])
        XCTAssertEqual(snap.outdated.map(\.latestVersion), ["1.24.5"])
        XCTAssertEqual(snap.outdated.map(\.summary), ["Internet file retriever"])
    }

    func testCollectBrewDoesNotListEachFormula() {
        var calls: [[String]] = []
        let snap = collectBrew(which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil }) { cmd, _ in
            calls.append(cmd)
            if cmd.contains("list") && cmd.contains("--formula") { return (0, "jq\n", "") }
            if cmd.contains("list") && cmd.contains("--cask") { return (0, "", "") }
            if cmd.contains("leaves") { return (0, "jq\n", "") }
            if cmd.contains("info") && cmd.contains("--formula") {
                return (0, #"{"formulae":[{"name":"jq","desc":"JSON processor"}],"casks":[]}"#, "")
            }
            if cmd.contains("info") { return (0, #"{"formulae":[],"casks":[]}"#, "") }
            if cmd.contains("services") { return (0, "Name State\n", "") }
            if cmd.contains("outdated") { return (0, #"{"formulae":[],"casks":[]}"#, "") }
            return (0, "", "")
        }
        XCTAssertTrue(snap.available)
        XCTAssertEqual(snap.formulas.map(\.name), ["jq"])
        XCTAssertFalse(
            calls.contains { cmd in
                guard let i = cmd.firstIndex(of: "list") else { return false }
                let rest = cmd.suffix(from: cmd.index(after: i))
                return rest.contains { !$0.hasPrefix("-") }
            },
            "collectBrew must not call `brew list <formula>` (Homebrew lock + empty bins)"
        )
    }

    func testFormulaBinsReadsOptBinDir() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("appattic-opt-\(UUID().uuidString)")
        let bin = prefix.appendingPathComponent("opt/rg/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        FileManager.default.createFile(atPath: bin.appendingPathComponent("rg").path, contents: Data())
        FileManager.default.createFile(atPath: bin.appendingPathComponent("skip.dylib").path, contents: Data())
        XCTAssertEqual(formulaBins(prefix: prefix.path, name: "rg"), ["rg"])
        XCTAssertEqual(formulaBins(prefix: prefix.path, name: "missing"), [])
    }

    func testCollectBrewKeepsUntrustedCask() {
        let err = "Error: Refusing to load cask dail8859/notepadnext/notepadnext from untrusted tap dail8859/notepadnext.\n"
        let snap = collectBrew(which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil }) { cmd, _ in
            if cmd.contains("list") && cmd.contains("--formula") { return (0, "", "") }
            if cmd.contains("list") && cmd.contains("--cask") { return (0, "notepadnext\n", "") }
            if cmd.contains("leaves") { return (0, "", "") }
            if cmd.contains("info") && cmd.contains("--formula") && cmd.contains("--installed") {
                return (0, #"{"formulae":[],"casks":[]}"#, "")
            }
            if cmd.contains("info") {
                return (1, "", err)
            }
            if cmd.contains("services") { return (0, "Name State\n", "") }
            if cmd.contains("outdated") { return (0, #"{"formulae":[],"casks":[]}"#, "") }
            return (0, "", "")
        }
        XCTAssertEqual(snap.casks.map(\.name), ["notepadnext"])
        XCTAssertEqual(snap.untrustedCasks.map(\.name), ["notepadnext"])
        XCTAssertEqual(snap.casks.first?.untrustedTap, "dail8859/notepadnext")
    }

    func testCollectBrewRetriesCaskOmittedFromInstalledJSON() {
        let err = "Error: Refusing to load cask dail8859/notepadnext/notepadnext from untrusted tap dail8859/notepadnext.\n"
        var infoCalls: [[String]] = []
        let snap = collectBrew(which: { $0 == "brew" ? "/opt/homebrew/bin/brew" : nil }) { cmd, _ in
            if cmd.contains("info") { infoCalls.append(cmd) }
            if cmd.contains("list") && cmd.contains("--formula") { return (0, "", "") }
            if cmd.contains("list") && cmd.contains("--cask") { return (0, "iterm2\nnotepadnext\n", "") }
            if cmd.contains("leaves") { return (0, "", "") }
            if cmd.contains("info") && cmd.contains("--cask") && cmd.contains("--installed") {
                return (0, #"{"formulae":[],"casks":[{"token":"iterm2","desc":"Terminal emulator"}]}"#, "")
            }
            if cmd.contains("info") && cmd.contains("--formula") && cmd.contains("--installed") {
                return (0, #"{"formulae":[],"casks":[]}"#, "")
            }
            if cmd.contains("info") && cmd.contains("notepadnext") {
                return (1, "", err)
            }
            if cmd.contains("info") && cmd.contains("iterm2") && !cmd.contains("--installed") {
                return (0, #"{"formulae":[],"casks":[{"token":"iterm2","desc":"Terminal emulator"}]}"#, "")
            }
            if cmd.contains("info") {
                return (1, "", err)
            }
            if cmd.contains("services") { return (0, "Name State\n", "") }
            if cmd.contains("outdated") { return (0, #"{"formulae":[],"casks":[]}"#, "") }
            return (0, "", "")
        }
        XCTAssertTrue(
            infoCalls.contains { $0.contains("notepadnext") && !$0.contains("--installed") },
            infoCalls.map { $0.joined(separator: " ") }.joined(separator: " | ")
        )
        XCTAssertEqual(snap.untrustedCasks.map(\.name), ["notepadnext"])
        XCTAssertEqual(Set(snap.casks.map(\.name)), Set(["iterm2", "notepadnext"]))
    }
}
