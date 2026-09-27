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

    /// Every pin SwiftPM wrote, which is every package the build resolved,
    /// declared or transitive. A pin spans five lines and the keys are
    /// indented differently at the pin and at its state, so the pairs are
    /// collected by scanning for the keys: `      "identity" : "zlib",` puts
    /// the name in the fourth `"`-separated field, and the same holds for
    /// "location" and "version".
    private func resolvedPins() throws -> [(identity: String, location: String, version: String)] {
        let url = root.appendingPathComponent("Package.resolved")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Package.swift declares no package on this platform, so SwiftPM resolved none and wrote no lockfile")
        }
        let resolved = try String(contentsOf: url, encoding: .utf8)
        var pins: [(identity: String, location: String, version: String)] = []
        for line in resolved.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[0].trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let key = parts[1]
            guard key == "identity" || key == "location" || key == "version" else { continue }
            let value = String(parts[3])
            if key == "identity" {
                pins.append((identity: value, location: "", version: ""))
                continue
            }
            guard !pins.isEmpty else { continue }
            let last = pins.count - 1
            if key == "location" {
                pins[last].location = value
            } else {
                pins[last].version = value
            }
        }
        return pins
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

    /// The purl is what a consumer and a vulnerability scanner match a package
    /// by, so it has to name the source and not only the package: the identity
    /// alone is not a purl anyone can resolve, and two packages of the same
    /// name under different owners would carry the same one. The expected value
    /// is read out of the location SwiftPM pinned, so this fails if the
    /// generator stops deriving the namespace from it.
    func testSBOMNamesEverySwiftPMPinWithItsVersion() throws {
        let pins = try resolvedPins()
        XCTAssertFalse(pins.isEmpty)
        let components = try sbomComponents()
        let purls = components.compactMap { $0["purl"] as? String }

        for pin in pins {
            var namespace = pin.location
            if namespace.hasPrefix("https://") { namespace.removeFirst("https://".count) }
            if namespace.hasSuffix(".git") { namespace.removeLast(".git".count) }
            let expected = "pkg:swift/\(namespace)@\(pin.version)"
            let matches = purls.filter { $0 == expected }
            XCTAssertEqual(
                matches.count,
                1,
                "\(pin.identity) is pinned in Package.resolved at \(pin.location) but the SBOM lists \(matches)"
            )
        }
    }

    /// A downloaded artifact is pinned by the SHA-256 in
    /// dep-checksums.sha256 and a SwiftPM pin by the commit revision it
    /// resolved to, so the two carry digests of different lengths. Both have
    /// to be there: a component with no hash is one a consumer cannot match
    /// against the bytes it was built from.
    ///
    /// A Flatpak runtime is the one component that cannot: `flatpak
    /// build-bundle` puts the runtime in the bundle, and the manifest pins it
    /// to a branch, which is a name and not a digest. It carries
    /// appattic:pinned-by=branch instead, so the pin is on the component and a
    /// hash nobody can check is not invented for it. A component with neither a
    /// hash nor that property is the gap this asserts against: it reads like a
    /// downloaded artifact whose digest was forgotten.
    func testEveryComponentIsHashedAndCarriesAnExternalReference() throws {
        let components = try sbomComponents()
        XCTAssertFalse(components.isEmpty)
        for component in components {
            let name = component["name"] as? String ?? "?"
            let pinnedByBranch = (component["properties"] as? [[String: String]] ?? [])
                .contains { $0["name"] == "appattic:pinned-by" && $0["value"] == "branch" }
            let hashes = component["hashes"] as? [[String: String]] ?? []
            if pinnedByBranch {
                XCTAssertEqual(
                    hashes.count, 0,
                    "\(name) is pinned by branch; a hash beside that is a number nothing can check"
                )
            } else {
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
            }
            let refs = component["externalReferences"] as? [[String: String]] ?? []
            XCTAssertTrue(refs.first?["url"]?.hasPrefix("https://") == true, "\(name) has no https source")
        }
    }

    /// The runtime the Flatpak bundle carries is the largest third-party thing
    /// in that artifact, and the bundle ships an SBOM beside it, so a consumer
    /// reading only the inventory has to find it there. The expected value is
    /// read out of the manifest, so this fails if the generator stops carrying
    /// the runtime, and also if it names a branch the manifest does not.
    func testEveryFlatpakRuntimeIsAComponent() throws {
        let dir = root.appendingPathComponent("packaging/flatpak")
        let manifests = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".yml") }
            .sorted()
        XCTAssertFalse(manifests.isEmpty, "no Flatpak manifest to inventory a runtime from")
        let components = try sbomComponents()
        for name in manifests {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            func value(_ key: String) -> String? {
                for line in text.split(separator: "\n") where line.hasPrefix("\(key):") {
                    return line
                        .dropFirst(key.count + 1)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                return nil
            }
            let runtime = try XCTUnwrap(value("runtime"), "\(name) names no runtime")
            let branch = try XCTUnwrap(value("runtime-version"), "\(name) names no runtime-version")
            let matches = components.filter { $0["name"] as? String == runtime }
            XCTAssertEqual(matches.count, 1, "\(runtime) is named in \(name) but the SBOM lists \(matches.count) component(s) for it")
            XCTAssertEqual(
                matches.first?["version"] as? String, branch,
                "\(name) pins \(runtime) to \(branch), the SBOM says \(matches.first?["version"] as? String ?? "nothing")"
            )
        }
    }

    /// A purl is the key a consumer and a vulnerability scanner match a
    /// component by, so two components carrying one purl means the second is
    /// invisible to anything that looks the first up: the two architecture
    /// builds of a downloaded artifact, or two packages of the same name under
    /// different owners, differ in the qualifiers and the namespace, not in
    /// the version.
    func testSBOMPurlsAreUnique() throws {
        let components = try sbomComponents()
        var seen: [String: [String]] = [:]
        for component in components {
            let name = component["name"] as? String ?? "?"
            guard let purl = component["purl"] as? String else {
                XCTFail("\(name) has no purl in the SBOM")
                continue
            }
            seen[purl, default: []].append(name)
        }
        for (purl, names) in seen where names.count > 1 {
            XCTFail("\(names.joined(separator: ", ")) all carry the purl \(purl)")
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
