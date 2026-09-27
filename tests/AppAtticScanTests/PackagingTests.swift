import XCTest
@testable import AppAtticScan

final class PackagingTests: XCTestCase {
    /// The <string> on the line after <key>, which is how the plist spells one.
    private func plistString(_ plist: String, _ key: String) -> String {
        let lines = plist.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(where: { $0.contains("<key>\(key)</key>") }) else {
            XCTFail("no \(key) in the plist")
            return ""
        }
        let next = lines.index(after: at)
        guard next < lines.endIndex, let value = lines[next].split(separator: ">").nth(1)?
            .split(separator: "<").first else {
            XCTFail("\(key) has no <string> on the next line")
            return ""
        }
        return String(value)
    }

    func testQtBinaryShipsAManPageForEveryFlag() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manURL = root.appendingPathComponent("packaging/appattic-qt.1")
        let man = try String(contentsOf: manURL, encoding: .utf8)
        XCTAssertTrue(man.contains(".TH APPATTIC\\-QT 1"), man)
        XCTAssertTrue(man.contains(".SH NAME"), man)

        let main = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/main.cpp"),
            encoding: .utf8
        )
        // Every flag --help prints has to be in the man page, or the two
        // contradict each other.
        for flag in ["--version", "--help", "-h", "--smoke"] {
            XCTAssertTrue(man.contains(flag), "man page is missing \(flag)")
            XCTAssertTrue(main.contains(flag), "runHelp is missing \(flag)")
        }

        let cmake = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/CMakeLists.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(cmake.contains("packaging/appattic-qt.1"), cmake)
        XCTAssertTrue(cmake.contains("share/man/man1"), cmake)

        // One version declaration; the plist and the man page are copies that
        // check-version.sh compares against it.
        let checkVersion = try String(
            contentsOf: root.appendingPathComponent("scripts/check-version.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(checkVersion.contains("CFBundleShortVersionString"), checkVersion)
        XCTAssertTrue(checkVersion.contains("appattic-qt.1"), checkVersion)
    }

    /// The AppStream `<description>` is the only release note the package
    /// ships, so a `<release>` with a version and no note is a silent release.
    /// The gate that stops it lives in check-version.sh; this pins both the
    /// gate and the entry it reads, since either can drift alone.
    func testNewestAppStreamReleaseCarriesANoteAndADate() throws {
        let root = repoRoot()
        let metainfo = try String(
            contentsOf: root.appendingPathComponent("packaging/org.appattic.AppAttic.metainfo.xml"),
            encoding: .utf8
        )
        let version = try String(
            contentsOf: root.appendingPathComponent("Sources/AppAtticScan/Version.swift"),
            encoding: .utf8
        )
        let declared = capture(#"appAtticVersion = "([^"]+)""#, in: version)

        // Newest by version, not by position: an entry appended out of order
        // must not leave an older one looking like the release of record.
        let entries = metainfo.components(separatedBy: "<release ").dropFirst()
        let newest = try XCTUnwrap(
            entries
                .compactMap { chunk -> (String, String)? in
                    guard chunk.contains(#"version=""#) else { return nil }
                    return (capture(#"version="([^"]+)""#, in: chunk), chunk)
                }
                .max { lhs, rhs in
                    lhs.0.compare(rhs.0, options: .numeric) == .orderedAscending
                }
        )
        XCTAssertEqual(newest.0, declared)

        let head = newest.1.prefix { $0 != ">" }
        XCTAssertTrue(head.contains("date=\""), "the \(declared) release has no date: \(head)")
        XCTAssertTrue(
            newest.1.contains("<description>"),
            "the \(declared) release has no <description>: a release with no note is a silent release"
        )
        // Every tagged release has a note of its own, not just the newest: the
        // ones below are the notes a reader upgrading across majors reads.
        // A split on `<release ` leaves each chunk running to the end of the
        // file, so a note belonging to a *later* release would satisfy the
        // check. The chunks are cut at the next `<release ` first.
        let starts = metainfo.indices.filter { metainfo[$0...].hasPrefix("<release ") }
        XCTAssertFalse(starts.isEmpty, "no <release> entries in the metainfo")
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : metainfo.endIndex
            let own = String(metainfo[start..<end])
            XCTAssertTrue(own.contains(#"version=""#), "a <release> has no version: \(own.prefix(60))")
            let version = capture(#"version="([^"]+)""#, in: own)
            XCTAssertTrue(
                own.contains("<description>"),
                "the \(version) release has no <description> of its own"
            )
        }

        let checkVersion = try String(
            contentsOf: root.appendingPathComponent("scripts/check-version.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(checkVersion.contains("<description>"), checkVersion)
        XCTAssertTrue(checkVersion.contains("date="), checkVersion)
    }

    /// The Swift resource is a symlink to the one table the Zig core embeds,
    /// so the two cannot drift. A copy here is a second file to forget, which
    /// is how the table first got the same four names twice.
    func testSystemNamesTableIsOneSymlinkedFile() throws {
        let root = repoRoot()
        let packaged = root.appendingPathComponent("Sources/AppAtticScan/linux-system-names.txt")
        let values = try packaged.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true, packaged.path)
        XCTAssertEqual(
            try packaged.resolvingSymlinksInPath().path,
            root.appendingPathComponent("core/src/linux-system-names.txt").path,
            "the Swift resource must resolve to the table the Zig core embeds"
        )

        let core = try String(
            contentsOf: repoRoot().appendingPathComponent("core/src/linux-system-names.txt"),
            encoding: .utf8
        )
        let names = core.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let duplicates = Set(names.filter { name in
            names.firstIndex(of: name) != names.lastIndex(of: name)
        })
        XCTAssertEqual(duplicates, [], "duplicate system names: \(duplicates.sorted())")
        XCTAssertEqual(Set(names).count, names.count)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Group 1 of the first `pattern` match in `text`, or "" when there is none.
    private func capture(_ pattern: String, in text: String) -> String {
        guard let match = try? NSRegularExpression(pattern: pattern),
              let hit = match.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let group = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[group])
    }

    /// Group 1 of every `pattern` match in `text`, in order.
    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let match = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern: \(pattern)")
            return []
        }
        return match.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { hit in
                guard let group = Range(hit.range(at: 1), in: text) else { return nil }
                return String(text[group])
            }
    }

    /// Every class and every `test*` method declared under tests/AppAtticScanTests.
    /// A `class func` or `class var` member is not a class, so the pattern wants
    /// a capitalised name and a class header after it.
    private func scanTestDeclarations(root: URL) throws -> (classes: Set<String>, methods: [String: Set<String>]) {
        let dir = root.appendingPathComponent("tests/AppAtticScanTests")
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var classes = Set<String>()
        var methods: [String: Set<String>] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let here = Set(captures(#"(?:final\s+)?class\s+([A-Z][A-Za-z0-9_]*)"#, in: text))
            let tests = Set(captures(#"func\s+(test[A-Za-z0-9_]*)\s*\("#, in: text))
            guard !tests.isEmpty else { continue }
            classes.formUnion(here)
            // Every class in a file owns every test method in it, so a method
            // added by an extension is attributed to the class that names it.
            for name in here {
                methods[name, default: []].formUnion(tests)
            }
        }
        return (classes, methods)
    }

    /// The contributor docs are the only route to a one-test or one-plugin run,
    /// and a filter that matches nothing reads as a green run. Each example has
    /// to name a class, a method and a plugin file that still exist.
    func testDocumentedSingleTestExamplesStillResolve() throws {
        let root = repoRoot()
        let (classes, methods) = try scanTestDeclarations(root: root)
        XCTAssertFalse(classes.isEmpty, "no test class found under tests/AppAtticScanTests")

        // The no-filter run names the test target, which is a class of no name.
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let target = capture(#"\.testTarget\(\s*name: "([^"]+)""#, in: manifest)
        XCTAssertFalse(target.isEmpty, "Package.swift declares no testTarget name")

        let docs = [
            "README.md",
            "CONTRIBUTING.md",
            "core/README.md",
            "build.sh",
            "scripts/check.sh",
            "scripts/test.sh",
        ]
        var filters: Set<String> = []
        var plugins: Set<String> = []
        for doc in docs {
            let text = try String(contentsOf: root.appendingPathComponent(doc), encoding: .utf8)
            filters.formUnion(captures(#"scripts/test\.sh[ \t]+([A-Za-z][A-Za-z0-9_]*)"#, in: text))
            filters.formUnion(
                captures(#"([A-Z][A-Za-z0-9_]*Tests/[A-Za-z][A-Za-z0-9_]*)"#, in: text)
            )
            plugins.formUnion(captures(#"core/build\.sh test ([A-Za-z0-9_]+\.zig)"#, in: text))
        }
        XCTAssertTrue(
            filters.contains("DiskSizeTests"),
            "the docs must keep one single-class run: \(filters.sorted())"
        )
        XCTAssertTrue(
            plugins.contains("brew.zig"),
            "the docs must keep one single-plugin run: \(plugins.sorted())"
        )

        for example in filters.sorted() {
            let parts = example.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                let name = String(parts[0])
                let method = String(parts[1])
                XCTAssertTrue(
                    classes.contains(name) || name == target,
                    "no test class named \(name) for \(example)"
                )
                XCTAssertTrue(
                    methods[name]?.contains(method) ?? false,
                    "\(name) has no test named \(method), so \(example) runs nothing"
                )
            } else {
                XCTAssertTrue(
                    classes.contains(example) || example == target,
                    "no test class named \(example)"
                )
            }
        }
        for plugin in plugins.sorted() {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("core/src/\(plugin)").path),
                "no core/src/\(plugin), so `core/build.sh test \(plugin)` cannot run"
            )
        }
    }

    func testMacBundleSourcesMatchPlatformFloor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("packaging/Info.plist")
        let iconURL = root.appendingPathComponent("packaging/AppAttic.icns")
        let plist = try String(contentsOf: plistURL, encoding: .utf8)
        XCTAssertTrue(plist.contains("<key>LSMinimumSystemVersion</key>"), plist)
        XCTAssertTrue(plist.contains("<string>13.0</string>"), plist)
        XCTAssertFalse(plist.contains("<string>14.0</string>"), plist)
        XCTAssertEqual(
            plistString(plist, "CFBundleShortVersionString"),
            appAtticVersion,
            "the macOS bundle version must be the declared version; bump it in the same commit"
        )
        let buildNumber = plistString(plist, "CFBundleVersion")
        XCTAssertNotNil(
            Int(buildNumber),
            "CFBundleVersion is the build number beside the version, and it has to be an integer: \(buildNumber)"
        )
        XCTAssertGreaterThan(Int(buildNumber) ?? 0, 0, buildNumber)
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path), iconURL.path)
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("packaging/Info.plist"), build)
        XCTAssertTrue(build.contains("packaging/AppAttic.icns"), build)
        let run = try String(contentsOf: root.appendingPathComponent("run.sh"), encoding: .utf8)
        XCTAssertTrue(run.contains("best_mtime"), run)
        XCTAssertTrue(run.contains("file_mtime"), run)
        XCTAssertTrue(run.contains("AppAttic.app/Contents/MacOS/AppAttic"), run)
        let svg = try String(contentsOf: root.appendingPathComponent("packaging/appattic.svg"), encoding: .utf8)
        XCTAssertTrue(svg.contains("fill=\"#1e1e1e\""), svg)
        XCTAssertTrue(svg.contains("fill=\"#2e2e2e\""), svg)
        XCTAssertTrue(svg.contains("fill=\"#0a84ff\""), svg)
        XCTAssertTrue(svg.contains("fill=\"#30d158\""), svg)
        XCTAssertTrue(svg.contains("fill=\"#ff453a\""), svg)
        XCTAssertFalse(svg.contains("#0d1117"), svg)
        XCTAssertFalse(svg.contains("#58a6ff"), svg)
        XCTAssertFalse(svg.contains("#21262d"), svg)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("generate_icon.py").path
        ))
        let keepNames = try String(
            contentsOf: root.appendingPathComponent("core/src/linux-system-names.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(keepNames.contains("gtk-3.0"), keepNames)
        XCTAssertFalse(linuxSystemNames.isEmpty)
        XCTAssertTrue(linuxSystemNames.contains("gtk-3.0"))
    }

    func testDownloadArtifactsHavePinnedChecksums() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sumsURL = root.appendingPathComponent("scripts/dep-checksums.sha256")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sumsURL.path), sumsURL.path)
        let sums = try String(contentsOf: sumsURL, encoding: .utf8)
        // GNU sha256sum format: 64 hex digits, two spaces, the file name. A
        // name with no digest, or a truncated one, is not a pin: the download
        // would verify against nothing.
        var pinned: [String: String] = [:]
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !line.hasPrefix("#") else { continue }
            guard parts.count >= 2 else {
                XCTFail("no digest on line: \(line)")
                continue
            }
            let digest = String(parts[0])
            XCTAssertEqual(digest.count, 64, "line: \(line)")
            XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }, "line: \(line)")
            let name = parts.dropFirst(2).joined(separator: " ")
            XCTAssertFalse(name.isEmpty, "line: \(line)")
            pinned[name] = digest
        }
        XCTAssertFalse(pinned.isEmpty, sums)
        let zigNeed = try String(contentsOf: root.appendingPathComponent(".zig-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for artifact in [
            "zig-x86_64-linux-\(zigNeed).tar.xz",
            "wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz",
            "swift-5.10.1-RELEASE-ubuntu22.04.tar.gz",
            "linuxdeploy-x86_64.AppImage",
            "linuxdeploy-plugin-qt-x86_64.AppImage",
            "appimagetool-x86_64.AppImage",
        ] {
            XCTAssertNotNil(pinned[artifact], "\(artifact) is not pinned in \(sumsURL.lastPathComponent)")
        }

        let deps = try String(contentsOf: root.appendingPathComponent("scripts/linux-deps.sh"), encoding: .utf8)
        XCTAssertTrue(deps.contains("verify-sha256.sh"), deps)
        XCTAssertTrue(deps.contains("$_script_dir/verify-sha256.sh"), deps)
        XCTAssertFalse(deps.contains("$ROOT/scripts/verify-sha256.sh"), deps)
        XCTAssertTrue(deps.contains("verify_sha256"), deps)
        XCTAssertTrue(deps.contains("checksum_for"), deps)
        XCTAssertTrue(deps.contains("curl_fetch"), deps)
        XCTAssertTrue(deps.contains("DEBIAN_FRONTEND=noninteractive"), deps)
        XCTAssertTrue(deps.contains("zig-${triple}-linux-${ZIG_VER}.tar.xz"), deps)
        XCTAssertTrue(deps.contains("wasmtime-v${WASMTIME_VER}-${triple}-c-api.tar.xz"), deps)
        XCTAssertTrue(deps.contains("swift-${ver}-RELEASE-ubuntu22.04.tar.gz"), deps)
        XCTAssertFalse(deps.contains("| tar -xz"), deps)
        XCTAssertFalse(deps.contains("curl -fsSL"), deps)

        let verify = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-sha256.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(verify.contains("curl_fetch"), verify)
        XCTAssertTrue(verify.contains("--retry 5"), verify)
        XCTAssertTrue(verify.contains("--proto '=https'"), verify)
        XCTAssertTrue(verify.contains("--tlsv1.2"), verify)
        XCTAssertTrue(verify.contains("BASH_SOURCE[0]"), verify)
        XCTAssertFalse(verify.contains("$ROOT/scripts/dep-checksums.sha256"), verify)
        // shasum is the macOS spelling of the same digest. Without it neither
        // the inventory nor the pin check can run on the macOS runner.
        XCTAssertTrue(verify.contains("shasum -a 256"), verify)

        let appimage = try String(
            contentsOf: root.appendingPathComponent("scripts/linux-appimage.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(appimage.contains("verify-sha256.sh"), appimage)
        XCTAssertTrue(appimage.contains("$_script_dir/verify-sha256.sh"), appimage)
        XCTAssertFalse(appimage.contains("$ROOT/scripts/verify-sha256.sh"), appimage)
        XCTAssertTrue(appimage.contains("verify_sha256"), appimage)
        XCTAssertTrue(appimage.contains("curl_fetch"), appimage)
        XCTAssertTrue(appimage.contains("VERSION=\"${VERSION#v}\""), appimage)
        XCTAssertTrue(appimage.contains("SMOKE=ok"), appimage)
        XCTAssertFalse(appimage.contains("curl -fsSL"), appimage)
        XCTAssertFalse(appimage.contains("/continuous/"), appimage)
        XCTAssertTrue(appimage.contains("1-alpha-20251107-1"), appimage)
        XCTAssertTrue(appimage.contains("1-alpha-20250213-1"), appimage)
        XCTAssertTrue(appimage.contains("AppImage/appimagetool"), appimage)
        XCTAssertTrue(appimage.contains("APPIMAGETOOL_VER=1.9.1"), appimage)
        XCTAssertFalse(appimage.contains("AppImageKit"), appimage)

        let docker = try String(contentsOf: root.appendingPathComponent("Dockerfile"), encoding: .utf8)
        XCTAssertTrue(docker.contains("scripts/verify-sha256.sh"), docker)
        XCTAssertTrue(docker.contains("scripts/dep-checksums.sha256"), docker)
        XCTAssertTrue(docker.contains("/tmp/appattic/scripts/linux-deps.sh"), docker)

        // The Qt 6 link proof has one definition, scripts/verify-qt-link.sh.
        // CI jobs, both images, and scripts/check.sh --qt must all call it, and
        // none may go back to inlining the assertions.
        let dockerArch = try String(
            contentsOf: root.appendingPathComponent("Dockerfile.arch"),
            encoding: .utf8
        )
        let linuxYaml = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/linux.yml"),
            encoding: .utf8
        )
        let verifyQtLink = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-qt-link.sh"),
            encoding: .utf8
        )
        for source in [docker, dockerArch, linuxYaml] {
            XCTAssertTrue(source.contains("verify-qt-link.sh"), source)
            XCTAssertFalse(source.contains("LINUX_QT_LINK=ok"), source)
        }
        XCTAssertTrue(verifyQtLink.contains("LINUX_QT_LINK=ok"), verifyQtLink)
        XCTAssertTrue(verifyQtLink.contains("LINUX_QT_SMOKE=ok"), verifyQtLink)
        XCTAssertTrue(verifyQtLink.contains("plugin:path-shadow"), verifyQtLink)
        XCTAssertTrue(verifyQtLink.contains("wasm: ok"), verifyQtLink)
        XCTAssertTrue(verifyQtLink.contains("tables: ok"), verifyQtLink)

        let yaml = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/linux.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(yaml.contains("actions/checkout@11d5960a326750d5838078e36cf38b85af677262"), yaml)
        XCTAssertTrue(yaml.contains("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"), yaml)
        XCTAssertTrue(yaml.contains("actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809"), yaml)
        XCTAssertFalse(yaml.contains("actions/checkout@v4\n"), yaml)
        XCTAssertFalse(yaml.contains("setup-swift@v2\n"), yaml)
        XCTAssertFalse(yaml.contains("upload-artifact@v4\n"), yaml)
        XCTAssertFalse(yaml.contains("actions/cache@v4\n"), yaml)

        let release = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(
            release.contains("softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65"),
            release
        )
        XCTAssertFalse(release.contains("action-gh-release@v2\n"), release)
        XCTAssertTrue(release.contains("persist-credentials: false"), release)
        XCTAssertTrue(release.contains("timeout-minutes:"), release)
        XCTAssertTrue(release.contains("github.ref_name"), release)
        XCTAssertTrue(release.contains("actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809"), release)
        XCTAssertTrue(release.contains("linux-appimage.sh"), release)
        XCTAssertTrue(release.contains("fail_on_unmatched_files: true"), release)
        XCTAssertTrue(release.contains("concurrency:"), release)

        // The Info.plist copy of the version is only safe to leave ungated
        // until it is actually gated.
        let checkVersion = try String(
            contentsOf: root.appendingPathComponent("scripts/check-version.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(checkVersion.contains("CFBundleShortVersionString"), checkVersion)
        XCTAssertTrue(checkVersion.contains("CFBundleVersion"), checkVersion)
        XCTAssertTrue(checkVersion.contains("packaging/Info.plist"), checkVersion)
        let lint = try String(contentsOf: root.appendingPathComponent("scripts/lint.sh"), encoding: .utf8)
        XCTAssertTrue(lint.contains("check-version.sh"), lint)
        XCTAssertTrue(release.contains("check-version.sh --tag"), release)
    }

    func testLinuxQtLinkScriptRefusesDarwin() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/linux-qt-link.sh")
        let scriptText = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(scriptText.contains("exit 3"), scriptText)
        XCTAssertTrue(scriptText.contains("not Linux"), scriptText)
        #if os(Linux)
        // Source-level Darwin refusal only. Executing the script here would
        // compile the Qt UI, which is an environment-dependent host build.
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        let err = Pipe()
        process.standardOutput = err
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 3, text)
        XCTAssertTrue(text.lowercased().contains("not linux"), text)
        XCTAssertTrue(text.lowercased().contains("homebrew"), text)
        #endif
    }

    func testSpecsMatchShippedCoreAndCLI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let zig = try String(
            contentsOf: root.appendingPathComponent("docs/specs/2026-08-26-zig-wasm-core-design.md"),
            encoding: .utf8
        )
        XCTAssertTrue(zig.contains("Status: Accepted"), zig)
        XCTAssertTrue(zig.contains("host.exec"), zig)
        XCTAssertTrue(zig.contains("path_shadow.wasm"), zig)
        XCTAssertFalse(zig.contains("path-overlay-shadow"), zig)
        XCTAssertTrue(zig.contains("realpath"), zig)
        let coreReadme = try String(contentsOf: root.appendingPathComponent("core/README.md"), encoding: .utf8)
        XCTAssertTrue(coreReadme.contains("realpath"), coreReadme)
        XCTAssertTrue(coreReadme.contains("AppAtticScan"), coreReadme)
        XCTAssertTrue(coreReadme.contains("test brew.zig"), coreReadme)
        XCTAssertTrue(coreReadme.contains(".zig-version"), coreReadme)
        XCTAssertFalse(coreReadme.contains("Swift UI (`AppAtticScan`)"), coreReadme)
        XCTAssertTrue(zig.contains("path_user_bin.wasm"), zig)
        XCTAssertFalse(zig.contains("path_application_support.wasm"), zig)
        XCTAssertFalse(zig.contains("No live query"), zig)
        XCTAssertFalse(zig.contains("Findings WASM that exists today is canned"), zig)
        XCTAssertFalse(zig.contains("Only these WASM modules"), zig)

        let swift = try String(
            contentsOf: root.appendingPathComponent("docs/specs/archive/2026-08-17-swift-scan-port-design.md"),
            encoding: .utf8
        )
        XCTAssertTrue(swift.contains("ARCHIVED"), swift)
        XCTAssertTrue(swift.contains("AppAtticUI"), swift)
        XCTAssertTrue(swift.contains("`packages`"), swift)
        XCTAssertTrue(swift.contains("--fresh"), swift)
        XCTAssertTrue(swift.contains("Packages.swift"), swift)
        XCTAssertFalse(swift.contains("Delete the Python package when"), swift)
        XCTAssertFalse(swift.contains("| `AppAttic` | executable | `AppAtticScan`, SwiftCrossUI"), swift)

        let index = try String(
            contentsOf: root.appendingPathComponent("docs/specs/README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(index.contains("archive/2026-08-17-swift-scan-port-design.md"), index)
        XCTAssertTrue(index.contains("2026-08-26-zig-wasm-core-design.md"), index)
    }

    func testContributorScriptsHelpAndUsageExit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // `runCommand` resolves bash on PATH, drains both pipes on their own
        // threads, and bounds the child. A hand-rolled Process that waits
        // before reading deadlocks as soon as a script's output passes the pipe
        // buffer, and never returns. Every script here derives ROOT from its own
        // path, so the working directory does not need to be the checkout.
        func run(_ rel: String, _ args: [String]) throws -> (Int32, String, String) {
            let shell = try XCTUnwrap(whichCommand("bash"), "bash is needed to run the shell scripts")
            let (rc, stdout, stderr) = runCommand(
                [shell, root.appendingPathComponent(rel).path] + args,
                timeout: 60
            )
            return (rc, stdout, stderr)
        }

        let helpScripts = [
            "build.sh",
            "core/build.sh",
            "run.sh",
            "scripts/check.sh",
            "scripts/check-version.sh",
            "scripts/deps.sh",
            "scripts/lint.sh",
            "scripts/linux-deps.sh",
            "scripts/linux-qt-link.sh",
            "scripts/test.sh",
            "scripts/verify-qt-link.sh",
            "scripts/verify-reproducible.sh",
            "scripts/linux-appimage.sh",
            "scripts/linux-flatpak.sh",
        ]
        for script in helpScripts {
            let (rc, stdout, stderr) = try run(script, ["--help"])
            XCTAssertEqual(rc, 0, "\(script) --help rc=\(rc) stderr=\(stderr)")
            XCTAssertTrue(stdout.lowercased().contains("usage"), "\(script) stdout=\(stdout)")
            XCTAssertEqual(stderr, "", "\(script) --help leaked stderr: \(stderr)")
        }

        let (buildRc, _, buildErr) = try run("build.sh", ["nope"])
        XCTAssertEqual(buildRc, 2, buildErr)
        XCTAssertTrue(buildErr.contains("unknown argument"), buildErr)

        let (coreRc, _, coreErr) = try run("core/build.sh", ["nope"])
        XCTAssertEqual(coreRc, 2, coreErr)
        XCTAssertTrue(coreErr.contains("unknown argument"), coreErr)

        let (coreTestRc, _, coreTestErr) = try run("core/build.sh", ["test"])
        XCTAssertEqual(coreTestRc, 2, coreTestErr)
        XCTAssertTrue(coreTestErr.contains("missing plugin name"), coreTestErr)

        let (lintRc, _, lintErr) = try run("scripts/lint.sh", ["nope"])
        XCTAssertEqual(lintRc, 2, lintErr)

        let (appimageRc, _, appimageErr) = try run("scripts/linux-appimage.sh", ["nope"])
        XCTAssertEqual(appimageRc, 2, appimageErr)
        XCTAssertTrue(appimageErr.contains("unknown argument"), appimageErr)

        let (flatpakRc, _, flatpakErr) = try run("scripts/linux-flatpak.sh", ["nope"])
        XCTAssertEqual(flatpakRc, 2, flatpakErr)
        XCTAssertTrue(flatpakErr.contains("unknown argument"), flatpakErr)
    }
}
