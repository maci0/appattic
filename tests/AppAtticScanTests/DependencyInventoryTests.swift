import XCTest
@testable import AppAtticScan

/// The CycloneDX file a release ships is the only place a consumer can read
/// what went into the artifact. A pin the generator drops is a dependency that
/// no scanner sees, and the pin check that should have caught it reports a
/// green run over the shorter list, so the count is asserted against
/// Package.resolved rather than against the generator's own output.
final class DependencyInventoryTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every `"identity"` SwiftPM wrote, which is every package the build
    /// resolved, declared or transitive. A line reads
    /// `      "identity" : "zlib",`, so the key is the second field of the
    /// split and the name the fourth.
    private func resolvedIdentities() throws -> [String] {
        let resolved = try String(contentsOf: root.appendingPathComponent("Package.resolved"), encoding: .utf8)
        return resolved.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[1] == "identity",
                  parts[0].trimmingCharacters(in: .whitespaces).isEmpty
            else {
                return nil
            }
            return String(parts[3])
        }
    }

    private func sbomComponents() throws -> [[String: Any]] {
        let shell = try XCTUnwrap(whichCommand("bash"), "bash is needed to run scripts/deps.sh")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-sbom-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let (rc, stdout, stderr) = runCommand(
            [shell, root.appendingPathComponent("scripts/deps.sh").path, "sbom", out.path],
            timeout: 60
        )
        XCTAssertEqual(rc, 0, "deps.sh sbom rc=\(rc) stdout=\(stdout) stderr=\(stderr)")
        let data = try Data(contentsOf: out)
        let object = try JSONSerialization.jsonObject(with: data)
        let bom = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(bom["bomFormat"] as? String, "CycloneDX")
        XCTAssertEqual(bom["specVersion"] as? String, "1.5")
        return try XCTUnwrap(bom["components"] as? [[String: Any]])
    }

    func testSBOMNamesEverySwiftPMPinWithItsVersion() throws {
        let identities = try resolvedIdentities()
        XCTAssertFalse(identities.isEmpty)
        let components = try sbomComponents()
        let purls = components.compactMap { $0["purl"] as? String }

        for identity in identities {
            let matches = purls.filter { $0.hasPrefix("pkg:swift/\(identity)@") }
            XCTAssertEqual(
                matches.count,
                1,
                "\(identity) is pinned in Package.resolved but the SBOM lists \(matches)"
            )
            guard let purl = matches.first else { continue }
            // The file's own "version" key is its format number, not a pin's.
            // A version of "3" here means the parser read the wrong line.
            XCTAssertFalse(purl.hasSuffix("@3"), "\(identity) carries the schema version: \(purl)")
        }
    }

    /// A downloaded artifact is pinned by the SHA-256 in
    /// dep-checksums.sha256 and a SwiftPM pin by the commit revision it
    /// resolved to, so the two carry digests of different lengths. Both have
    /// to be there: a component with no hash is one a consumer cannot match
    /// against the bytes it was built from.
    func testEveryComponentIsHashedAndCarriesAnExternalReference() throws {
        let components = try sbomComponents()
        XCTAssertFalse(components.isEmpty)
        for component in components {
            let name = component["name"] as? String ?? "?"
            let hashes = component["hashes"] as? [[String: String]] ?? []
            XCTAssertEqual(hashes.count, 1, "\(name) has no hash in the SBOM")
            let alg = hashes.first?["alg"] ?? ""
            let content = hashes.first?["content"] ?? ""
            switch alg {
            case "SHA-256":
                XCTAssertEqual(content.count, 64, name)
            case "SHA-1":
                XCTAssertEqual(content.count, 40, "\(name) is not pinned to a commit revision")
            default:
                XCTFail("\(name) records hash algorithm '\(alg)'")
            }
            let refs = component["externalReferences"] as? [[String: String]] ?? []
            XCTAssertTrue(refs.first?["url"]?.hasPrefix("https://") == true, "\(name) has no https source")
        }
    }

    /// Every download the packaging scripts fetch has to be a component: an
    /// artifact that ships in the binary and stays out of the inventory is the
    /// gap the SBOM exists to close.
    func testEveryPinnedDownloadIsAComponent() throws {
        let sums = try String(
            contentsOf: root.appendingPathComponent("scripts/dep-checksums.sha256"),
            encoding: .utf8
        )
        let names = sums.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0].count == 64 else { return nil }
            return String(parts[1])
        }
        XCTAssertFalse(names.isEmpty)
        let components = try sbomComponents()
        for name in names {
            XCTAssertTrue(
                components.contains { ($0["name"] as? String) == name },
                "\(name) is pinned in dep-checksums.sha256 but missing from the SBOM"
            )
        }
    }
}
