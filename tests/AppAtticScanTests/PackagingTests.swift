import XCTest
@testable import AppAtticScan

final class PackagingTests: XCTestCase {
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
        let zigNeed = try String(contentsOf: root.appendingPathComponent(".zig-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(sums.contains("zig-x86_64-linux-\(zigNeed).tar.xz"), sums)
        XCTAssertTrue(sums.contains("wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz"), sums)
        XCTAssertTrue(sums.contains("swift-5.10.1-RELEASE-ubuntu22.04.tar.gz"), sums)
        XCTAssertTrue(sums.contains("linuxdeploy-x86_64.AppImage"), sums)
        XCTAssertTrue(sums.contains("linuxdeploy-plugin-qt-x86_64.AppImage"), sums)
        XCTAssertTrue(sums.contains("appimagetool-x86_64.AppImage"), sums)

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
            contentsOf: root.appendingPathComponent("docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md"),
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
            contentsOf: root.appendingPathComponent("docs/superpowers/specs/archive/2026-08-17-swift-scan-port-design.md"),
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
            contentsOf: root.appendingPathComponent("docs/superpowers/specs/README.md"),
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

        func run(_ rel: String, _ args: [String]) throws -> (Int32, String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.currentDirectoryURL = root
            process.arguments = [root.appendingPathComponent(rel).path] + args
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, stdout, stderr)
        }

        let helpScripts = [
            "build.sh",
            "core/build.sh",
            "run.sh",
            "scripts/check.sh",
            "scripts/lint.sh",
            "scripts/linux-deps.sh",
            "scripts/linux-qt-link.sh",
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
