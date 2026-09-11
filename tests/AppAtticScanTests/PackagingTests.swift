import XCTest
@testable import AppAtticScan

func linuxQtSources(_ root: URL) throws -> String {
    let dir = root.appendingPathComponent("ui/linux-qt")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".cpp") || $0.hasSuffix(".h") }
        .sorted()
    return try names.map {
        try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)
    }.joined(separator: "\n")
}

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

    func testLinuxBuildUsesQtNotGtk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("Qt6Widgets"), build)
        XCTAssertTrue(build.contains("linux-qt-link.sh"), build)
        XCTAssertTrue(build.contains("qt6-base-dev"), build)
        XCTAssertFalse(build.contains("gtk4"), build)
        XCTAssertFalse(build.contains("libgtk-4-dev"), build)
        let pkg = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(pkg.contains("swift-cross-ui"), pkg)
        XCTAssertTrue(pkg.contains(".exact(\"0.2.1\")"), pkg)
        XCTAssertTrue(pkg.contains("DefaultBackend"), pkg)
        XCTAssertTrue(pkg.contains("os(Linux)"), pkg)
        XCTAssertTrue(pkg.contains("ui/linux-qt"), pkg)
        let design = try String(contentsOf: root.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        XCTAssertTrue(design.contains("Qt 6"), design)
        XCTAssertTrue(design.contains("ui/linux-qt"), design)
        XCTAssertTrue(design.contains("tmog"), design.lowercased())
        XCTAssertFalse(design.contains("Linux UI stays Gtk"), design)
        let workflow = root.appendingPathComponent(".github/workflows/linux.yml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workflow.path), workflow.path)
        let yaml = try String(contentsOf: workflow, encoding: .utf8)
        XCTAssertTrue(yaml.contains("ubuntu"), yaml)
        XCTAssertTrue(yaml.contains("linux-deps.sh --install"), yaml)
        XCTAssertTrue(yaml.contains("AppAtticScanTests"), yaml)
        XCTAssertFalse(yaml.contains("libgtk-4-dev"), yaml)
        XCTAssertFalse(yaml.contains("linux-gtk-link.sh"), yaml)
        let docker = try String(contentsOf: root.appendingPathComponent("Dockerfile"), encoding: .utf8)
        XCTAssertTrue(docker.contains("linux-deps.sh --install"), docker)
        XCTAssertTrue(docker.contains("scripts/verify-sha256.sh"), docker)
        XCTAssertTrue(docker.contains("scripts/dep-checksums.sha256"), docker)
        XCTAssertTrue(docker.contains("/tmp/appattic/scripts/linux-deps.sh"), docker)
        XCTAssertFalse(docker.contains("COPY scripts/linux-deps.sh /tmp/linux-deps.sh"), docker)
        XCTAssertFalse(docker.contains("apt-get install") && docker.contains("zig"), docker)
        XCTAssertTrue(docker.contains("linux-qt-link.sh"), docker)
        XCTAssertTrue(docker.lowercased().contains("qt6"), docker)
        XCTAssertFalse(docker.contains("libgtk-4-dev"), docker)
        XCTAssertFalse(docker.contains("linux-gtk-link.sh"), docker)
        let deps = try String(contentsOf: root.appendingPathComponent("scripts/linux-deps.sh"), encoding: .utf8)
        XCTAssertTrue(deps.contains("pacman"), deps)
        XCTAssertTrue(deps.contains("dnf"), deps)
        XCTAssertTrue(deps.contains("zypper"), deps)
        XCTAssertTrue(deps.contains("qt6"), deps.lowercased())
        XCTAssertTrue(deps.contains("wasmtime"), deps.lowercased())
        XCTAssertTrue(deps.contains("ca-certificates"), deps)
        XCTAssertTrue(deps.contains("debian_enable_universe"), deps)
        XCTAssertTrue(deps.contains("universe"), deps.lowercased())
        XCTAssertTrue(deps.contains("install_zig_tarball"), deps)
        XCTAssertTrue(deps.contains("ziglang.org"), deps)
        XCTAssertTrue(deps.contains(".zig-version"), deps)
        XCTAssertTrue(deps.contains(".deps/swift"), deps)
        XCTAssertTrue(deps.contains("no apt zig"), deps.lowercased())
        XCTAssertTrue(deps.contains("emit_ci_path"), deps)
        XCTAssertTrue(deps.contains("GITHUB_PATH"), deps)
        XCTAssertFalse(deps.contains("gtk4"), deps)
        XCTAssertFalse(deps.contains("libgtk-4-dev"), deps)
        XCTAssertTrue(deps.contains("swiftly") || deps.contains("swift-bin"), deps)
        XCTAssertTrue(deps.contains("5.10"), deps)
        XCTAssertTrue(deps.contains("swift:5.10.1-jammy"), deps)
        XCTAssertFalse(deps.contains("swift:5.10-jammy"), deps)
        XCTAssertTrue(yaml.contains("Put zig on PATH"), yaml)
        XCTAssertTrue(yaml.contains("GITHUB_PATH"), yaml)
        XCTAssertTrue(yaml.contains("ca-certificates"), yaml)
        XCTAssertTrue(yaml.contains("archlinux"), yaml)
        XCTAssertTrue(yaml.contains("permissions:"), yaml)
        XCTAssertTrue(yaml.contains("contents: read"), yaml)
        XCTAssertTrue(yaml.contains("persist-credentials: false"), yaml)
        XCTAssertTrue(yaml.contains("timeout-minutes:"), yaml)
        XCTAssertTrue(yaml.contains("success() || failure()"), yaml)
        XCTAssertTrue(yaml.contains("linux-deps.sh --install"), yaml)
        let archDocker = try String(contentsOf: root.appendingPathComponent("Dockerfile.arch"), encoding: .utf8)
        XCTAssertTrue(archDocker.contains("archlinux"), archDocker)
        XCTAssertTrue(archDocker.contains("qt6-base"), archDocker)
        XCTAssertTrue(archDocker.contains("scripts/verify-sha256.sh"), archDocker)
        XCTAssertTrue(archDocker.contains("scripts/dep-checksums.sha256"), archDocker)
        XCTAssertTrue(archDocker.contains("/tmp/appattic/scripts/linux-deps.sh"), archDocker)
        XCTAssertFalse(archDocker.contains("COPY scripts/linux-deps.sh /tmp/linux-deps.sh"), archDocker)
        XCTAssertTrue(archDocker.contains("linux-qt-link.sh"), archDocker)
        XCTAssertFalse(archDocker.contains("--install-swift"), archDocker)
        XCTAssertFalse(archDocker.contains("swift test"), archDocker)
        XCTAssertFalse(archDocker.contains("swift build"), archDocker)
        XCTAssertTrue(docker.contains("LINUX_QT_LINK=ok"), docker)
        XCTAssertTrue(archDocker.contains("LINUX_QT_LINK=ok"), archDocker)
        XCTAssertTrue(archDocker.contains("clang"), archDocker)
        XCTAssertFalse(archDocker.contains("gtk4"), archDocker)
        XCTAssertFalse(archDocker.contains("linux-gtk-link.sh"), archDocker)
        XCTAssertTrue(docker.contains("--install-wasmtime"), docker)
        XCTAssertTrue(yaml.contains("clang"), yaml)
        XCTAssertTrue(yaml.contains("linux-qt-link.sh"), yaml)
        XCTAssertTrue(yaml.contains("LINUX_QT_LINK=ok"), yaml)
        XCTAssertTrue(yaml.contains("upload-artifact"), yaml)
        XCTAssertTrue(yaml.contains("linux-qt-link-"), yaml)
        XCTAssertTrue(deps.contains("clang"), deps)
        let gtkLink = root.appendingPathComponent("scripts/linux-gtk-link.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gtkLink.path), gtkLink.path)
        let link = root.appendingPathComponent("scripts/linux-qt-link.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path), link.path)
        let linkText = try String(contentsOf: link, encoding: .utf8)
        XCTAssertTrue(linkText.contains("Qt6Widgets"), linkText)
        XCTAssertTrue(linkText.contains("appattic-qt"), linkText)
        XCTAssertTrue(linkText.contains("libQt6Widgets"), linkText)
        XCTAssertTrue(linkText.contains("LINUX_QT_LINK=ok"), linkText)
        XCTAssertTrue(linkText.contains("libgtk-"), linkText)
        XCTAssertFalse(linkText.contains("pkg-config --exists gtk4"), linkText)
        let qtMain = try linuxQtSources(root)
        XCTAssertTrue(qtMain.contains("QMainWindow"), qtMain)
        XCTAssertTrue(qtMain.contains("appattic_wasm_run"), qtMain)
        XCTAssertTrue(qtMain.contains("QTreeWidget"), qtMain)
        XCTAssertTrue(qtMain.contains("QListWidget"), qtMain)
        XCTAssertTrue(qtMain.contains("Include in cleanup"), qtMain)
        XCTAssertTrue(qtMain.contains("Ignore leftover"), qtMain)
        XCTAssertTrue(qtMain.contains("Could not read settings"), qtMain)
        XCTAssertTrue(qtMain.contains("Not scanned"), qtMain)
        XCTAssertTrue(qtMain.contains("Copied"), qtMain)
        XCTAssertTrue(qtMain.contains("Try Again"), qtMain)
        XCTAssertFalse(qtMain.contains("cannot read settings %1"), qtMain)
        XCTAssertTrue(qtMain.contains("settings.json"), qtMain)
        XCTAssertTrue(qtMain.contains("ignoredLeftoverPaths"), qtMain)
        XCTAssertTrue(qtMain.contains("parseSettingsJson"), qtMain)
        XCTAssertTrue(qtMain.contains("settingsFilePath"), qtMain)
        XCTAssertTrue(qtMain.contains("migrateLegacyQSettings"), qtMain)
        XCTAssertFalse(qtMain.contains("s.setValue(QStringLiteral(\"confirmDelete\")"), qtMain)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("settings.json"), readme)
        XCTAssertTrue(readme.contains("APPATTIC_CORE_OUT"), readme)
        XCTAssertTrue(readme.contains("ignoredLeftoverPaths"), readme)
        XCTAssertTrue(readme.contains("./run.sh packages"), readme)
        XCTAssertTrue(readme.contains("`packages` reuse the last scan"), readme)
        XCTAssertTrue(qtMain.contains("Review Script"), qtMain)
        XCTAssertTrue(qtMain.contains("apt-mark manual"), qtMain)
        XCTAssertTrue(qtMain.contains("PaletteChange"), qtMain)
        XCTAssertTrue(qtMain.contains("currentVersion") || qtMain.contains("current_version"), qtMain)
        XCTAssertTrue(qtMain.contains("lastUsed") || qtMain.contains("last_used"), qtMain)
        XCTAssertTrue(qtMain.contains("parseIsoInstant"), qtMain)
        XCTAssertTrue(qtMain.contains("Qt::ISODate"), qtMain)
        XCTAssertTrue(qtMain.contains("toLocalTime"), qtMain)
        XCTAssertTrue(qtMain.contains("daysTo"), qtMain)
        XCTAssertTrue(qtMain.contains("Location"), qtMain)
        XCTAssertTrue(qtMain.contains("Last used"), qtMain)
        XCTAssertTrue(qtMain.contains("QThread"), qtMain)
        XCTAssertTrue(qtMain.contains("m_scanThread->wait(8000)"), qtMain)
        XCTAssertFalse(qtMain.contains("wait(3000)"), qtMain)
        XCTAssertFalse(qtMain.contains("gtk.h"), qtMain)
        XCTAssertFalse(qtMain.contains("Gtk"), qtMain)
        XCTAssertFalse(qtMain.lowercased().contains("phosphor"), qtMain)
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/AppAttic/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(ui.contains("case packages = \"Packages\""), ui)
        XCTAssertTrue(ui.contains("settingsLoadFailed"), ui)
        XCTAssertTrue(qtMain.contains("if (m_settingsError) return;"), qtMain)
        XCTAssertTrue(ui.contains("Open Packages"), ui)
        XCTAssertTrue(ui.contains("settingsErrorUserMessage"), ui)
        XCTAssertTrue(ui.contains("holdsSettingsError"), ui)
        XCTAssertTrue(ui.contains("/usr/bin/pbcopy"), ui)
        XCTAssertFalse(qtMain.contains("0x1e, 0x1e, 0x1e"), qtMain)
        XCTAssertTrue(qtMain.contains("pluginWasmFiles"), qtMain)
        XCTAssertTrue(qtMain.contains("taggedPluginSpecs"), qtMain)
        XCTAssertTrue(qtMain.contains("runCoreWasm"), qtMain)
        XCTAssertFalse(qtMain.contains("collectCoreWasm"), qtMain)
        let mainCpp = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/main.cpp"), encoding: .utf8)
        XCTAssertFalse(mainCpp.contains("#include \"embed.h\""), mainCpp)
        XCTAssertFalse(mainCpp.contains("appattic_wasm_run"), mainCpp)
        let smokeCpp = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/smoke.cpp"), encoding: .utf8)
        XCTAssertFalse(smokeCpp.contains("#include \"embed.h\""), smokeCpp)
        XCTAssertFalse(smokeCpp.contains("appattic_wasm_run"), smokeCpp)
        let hostCpp = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/corehost.cpp"), encoding: .utf8)
        XCTAssertTrue(hostCpp.contains("#include \"embed.h\""), hostCpp)
        XCTAssertTrue(hostCpp.contains("appattic_wasm_run"), hostCpp)
        XCTAssertTrue(hostCpp.contains("onProgress"), hostCpp)
        XCTAssertTrue(qtMain.contains("pluginScanLabel"), qtMain)
        XCTAssertTrue(qtMain.contains("scanProgress"), qtMain)
        XCTAssertTrue(qtMain.contains("QProgressBar"), qtMain)
        XCTAssertTrue(qtMain.contains("setDesktopFileName"), qtMain)
        XCTAssertTrue(qtMain.contains("setWindowIcon"), qtMain)
        XCTAssertTrue(qtMain.contains(":/icons/appattic.png"), qtMain)
        XCTAssertTrue(qtMain.contains("org.appattic.AppAttic"), qtMain)
        let cmakeIcon = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/CMakeLists.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(cmakeIcon.contains("appattic.qrc"), cmakeIcon)
        XCTAssertTrue(cmakeIcon.contains("CMAKE_AUTORCC ON") || cmakeIcon.contains("AUTORCC"), cmakeIcon)
        XCTAssertTrue(cmakeIcon.contains("hicolor/128x128/apps"), cmakeIcon)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("packaging/appattic.png").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("ui/linux-qt/appattic.qrc").path
            )
        )
        XCTAssertFalse(hostCpp.contains("stem == QLatin1String(\"path_containers\")"), hostCpp)
        XCTAssertFalse(hostCpp.contains("stem.contains("), hostCpp)
        XCTAssertTrue(hostCpp.contains("hostHasExecutable"), hostCpp)
        XCTAssertTrue(hostCpp.contains("/run/host/usr/bin"), hostCpp)
        XCTAssertTrue(hostCpp.contains("FLATPAK_ID"), hostCpp)
        XCTAssertTrue(qtMain.contains("bodyFont"), qtMain)
        XCTAssertTrue(qtMain.contains("isShadowFinding"), qtMain)
        XCTAssertTrue(qtMain.contains("leftoverCleanupCommand"), qtMain)
        XCTAssertTrue(qtMain.contains("isProtectedPackagedPath"), qtMain)
        XCTAssertTrue(qtMain.contains("addFact(QStringLiteral(\"Shadows\")"), qtMain)
        XCTAssertTrue(qtMain.contains("path_shadow.wasm"), qtMain)
        XCTAssertFalse(qtMain.contains("addFact(QStringLiteral(\"Hides\")"), qtMain)
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

    func testLinuxAppImageAndFlatpakPackaging() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let desktop = try String(
            contentsOf: root.appendingPathComponent("packaging/appattic.desktop"),
            encoding: .utf8
        )
        XCTAssertTrue(desktop.contains("Exec=appattic-qt"), desktop)
        XCTAssertTrue(desktop.contains("Icon=appattic"), desktop)
        XCTAssertTrue(desktop.contains("StartupWMClass=appattic-qt"), desktop)
        XCTAssertTrue(desktop.contains("Keywords="), desktop)

        let meta = try String(
            contentsOf: root.appendingPathComponent("packaging/org.appattic.AppAttic.metainfo.xml"),
            encoding: .utf8
        )
        XCTAssertTrue(meta.contains("<id>org.appattic.AppAttic</id>"), meta)
        XCTAssertTrue(meta.contains("org.appattic.AppAttic.desktop"), meta)
        XCTAssertTrue(meta.contains("<binary>appattic-qt</binary>"), meta)

        let yml = try String(
            contentsOf: root.appendingPathComponent("packaging/flatpak/org.appattic.AppAttic.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(yml.contains("app-id: org.appattic.AppAttic"), yml)
        XCTAssertTrue(yml.contains("org.kde.Platform"), yml)
        XCTAssertTrue(yml.contains("runtime-version: \"6.10\""), yml)
        XCTAssertTrue(yml.contains("command: appattic-qt"), yml)
        XCTAssertTrue(yml.contains("--filesystem=host"), yml)
        XCTAssertTrue(yml.contains("--talk-name=org.freedesktop.Flatpak"), yml)
        XCTAssertTrue(yml.contains("wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz"), yml)
        XCTAssertTrue(yml.contains("23f282f333f07ec82a838928cbc86355cc4978c3618080d1a2e5714fec8411bf"), yml)
        XCTAssertTrue(yml.contains("zig-x86_64-linux-0.16.0.tar.xz"), yml)
        XCTAssertTrue(yml.contains("70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"), yml)
        XCTAssertTrue(yml.contains("WASMTIME_ROOT="), yml)

        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/linux-flatpak.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("flatpak-builder"), script)
        XCTAssertTrue(script.contains("SMOKE=ok"), script)
        XCTAssertTrue(script.contains("org.appattic.AppAttic"), script)
        XCTAssertTrue(script.contains("AppAttic.flatpak"), script)
        XCTAssertTrue(script.contains("--extra-sources"), script)
        XCTAssertTrue(script.contains("curl_fetch"), script)
        XCTAssertFalse(script.contains("curl -fsSL"), script)

        let cmake = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/CMakeLists.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(cmake.contains("$ORIGIN/../lib"), cmake)
        XCTAssertTrue(cmake.contains("org.appattic.AppAttic.metainfo.xml"), cmake)
        XCTAssertTrue(cmake.contains("share/metainfo"), cmake)

        let host = try String(
            contentsOf: root.appendingPathComponent("core/host/hostexec.c"),
            encoding: .utf8
        )
        XCTAssertTrue(host.contains("flatpak-spawn"), host)
        XCTAssertTrue(host.contains("appattic_host_in_flatpak"), host)
        XCTAssertTrue(host.contains("--host"), host)
        let embed = try String(
            contentsOf: root.appendingPathComponent("core/host/embed.h"),
            encoding: .utf8
        )
        XCTAssertTrue(embed.contains("appattic_progress_fn"), embed)
        XCTAssertTrue(embed.contains("on_progress"), embed)
        let hostCpp = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/corehost.cpp"),
            encoding: .utf8
        )
        XCTAssertTrue(hostCpp.contains("/run/host/usr/bin"), hostCpp)
        XCTAssertTrue(hostCpp.contains("FLATPAK_ID"), hostCpp)
        let smoke = try String(
            contentsOf: root.appendingPathComponent("ui/linux-qt/smoke.cpp"),
            encoding: .utf8
        )
        XCTAssertTrue(smoke.contains("Flatpak host has"), smoke)
        XCTAssertTrue(smoke.contains("/run/host/usr/bin/"), smoke)

        let appimage = try String(
            contentsOf: root.appendingPathComponent("scripts/linux-appimage.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(appimage.contains("dist/AppAttic-${APPIMAGE_ARCH}.AppImage") ||
            appimage.contains("AppAttic-${APPIMAGE_ARCH}.AppImage"), appimage)
        XCTAssertTrue(appimage.contains("usr/share/appattic"), appimage)
        XCTAssertTrue(appimage.contains("libwasmtime.so"), appimage)
    }

    func testLinuxLeftoverPathPluginsHaveWasm() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let needed = [
            "path-xdg-config": "path_xdg_config.wasm",
            "path-xdg-data": "path_xdg_data.wasm",
            "path-xdg-cache": "path_xdg_cache.wasm",
            "path-xdg-state": "path_xdg_state.wasm",
            "path-xdg-lib": "path_xdg_lib.wasm",
            "path-var-app": "path_var_app.wasm",
            "path-shadow": "path_shadow.wasm",
        ]
        let build = try String(contentsOf: root.appendingPathComponent("core/build.sh"), encoding: .utf8)
        let qtMain = try linuxQtSources(root)
        for (id, wasm) in needed {
            let manifestURL = root.appendingPathComponent("core/plugins/\(id)/manifest.json")
            let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            XCTAssertTrue(manifest.contains("\"url\": \"\(wasm)\""), manifest)
            XCTAssertTrue(build.contains(wasm), "build.sh missing \(wasm)")
            XCTAssertTrue(qtMain.contains(wasm), "linux-qt missing \(wasm)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("core/plugins/path-overlay-shadow/manifest.json").path
        ))
        XCTAssertFalse(qtMain.contains("chocolatey"), qtMain)
        XCTAssertFalse(qtMain.contains("nuget"), qtMain)
        XCTAssertFalse(qtMain.contains("appstore.wasm"), qtMain)
        XCTAssertFalse(qtMain.contains("steam.wasm"), qtMain)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("core/plugins/chocolatey/manifest.json").path
        ))
    }

    func testHostExecFixtureEnvPropagatedInCI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let linkText = try String(
            contentsOf: root.appendingPathComponent("scripts/linux-qt-link.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(linkText.contains("export APPATTIC_HOST_EXEC_FIXTURE=1"), linkText)
        let exit3 = try XCTUnwrap(linkText.range(of: "exit 3"))
        let exportFixture = try XCTUnwrap(linkText.range(of: "export APPATTIC_HOST_EXEC_FIXTURE=1"))
        XCTAssertLessThan(exit3.lowerBound, exportFixture.lowerBound)

        let coreBuild = try String(contentsOf: root.appendingPathComponent("core/build.sh"), encoding: .utf8)
        XCTAssertTrue(coreBuild.contains("Linux) export APPATTIC_HOST_EXEC_FIXTURE=1"), coreBuild)

        let qtMain = try linuxQtSources(root)
        XCTAssertTrue(qtMain.contains("int runSmoke"), qtMain)
        let runSmokeBody = qtMain.components(separatedBy: "int runSmoke(").dropFirst().first ?? ""
        XCTAssertTrue(
            runSmokeBody.contains("qputenv(\"APPATTIC_HOST_EXEC_FIXTURE\", \"1\")"),
            qtMain
        )

        let hostexec = try String(
            contentsOf: root.appendingPathComponent("core/host/hostexec.c"),
            encoding: .utf8
        )
        XCTAssertTrue(hostexec.contains("HOST_EXEC_TIMEOUT_MS"), hostexec)
        XCTAssertTrue(hostexec.contains("poll("), hostexec)
        XCTAssertTrue(hostexec.contains("reap_child"), hostexec)
        let hostexecH = try String(
            contentsOf: root.appendingPathComponent("core/host/hostexec.h"),
            encoding: .utf8
        )
        XCTAssertTrue(hostexecH.contains("capped at 60s"), hostexecH)
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
            contentsOf: root.appendingPathComponent("docs/superpowers/specs/2026-08-17-swift-scan-port-design.md"),
            encoding: .utf8
        )
        XCTAssertTrue(swift.contains("Status: Implemented"), swift)
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
        XCTAssertTrue(index.contains("2026-08-17-swift-scan-port-design.md"), index)
        XCTAssertTrue(index.contains("2026-08-26-zig-wasm-core-design.md"), index)
    }

    func testBuildPinsToolchainAndHardening() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmake = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/CMakeLists.txt"), encoding: .utf8)
        XCTAssertTrue(cmake.contains("-fstack-protector-strong"), cmake)
        XCTAssertTrue(cmake.contains("_FORTIFY_SOURCE=2"), cmake)
        XCTAssertTrue(cmake.contains("-Wl,-z,relro,-z,now"), cmake)
        XCTAssertTrue(cmake.contains("-Wl,-z,noexecstack"), cmake)
        XCTAssertTrue(cmake.contains("POSITION_INDEPENDENT_CODE"), cmake)
        XCTAssertTrue(cmake.contains("-ffile-prefix-map="), cmake)
        XCTAssertTrue(cmake.contains("-fmacro-prefix-map="), cmake)
        XCTAssertTrue(cmake.contains("CMAKE_BINARY_DIR"), cmake)
        XCTAssertTrue(cmake.contains("-fstack-clash-protection"), cmake)
        XCTAssertTrue(cmake.contains("PATTERN \"*.wasm\""), cmake)
        XCTAssertTrue(cmake.contains("finding.cpp"), cmake)
        XCTAssertTrue(cmake.contains("settings.cpp"), cmake)
        XCTAssertTrue(cmake.contains("corehost.cpp"), cmake)
        XCTAssertTrue(cmake.contains("smoke.cpp"), cmake)
        XCTAssertFalse(cmake.contains("APPATTIC_CORE_OUT=\"${APPATTIC_ROOT}/core/out\""), cmake)

        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("--disable-automatic-resolution"), build)
        XCTAssertTrue(build.contains("SOURCE_DATE_EPOCH"), build)
        XCTAssertTrue(build.contains("LC_ALL=C"), build)
        XCTAssertTrue(build.contains("appattic_require_swift"), build)
        XCTAssertTrue(build.contains("scripts/find-swift.sh"), build)
        XCTAssertTrue(build.contains("scripts/check.sh"), build)

        let run = try String(contentsOf: root.appendingPathComponent("run.sh"), encoding: .utf8)
        XCTAssertTrue(run.contains("APPATTIC_CORE_OUT"), run)

        let core = try String(contentsOf: root.appendingPathComponent("core/build.sh"), encoding: .utf8)
        XCTAssertTrue(core.contains("set -euo pipefail"), core)
        XCTAssertTrue(core.contains("-fstack-protector-strong"), core)
        XCTAssertTrue(core.contains("-ffile-prefix-map="), core)
        XCTAssertTrue(core.contains("Linux) export APPATTIC_HOST_EXEC_FIXTURE=1"), core)
        XCTAssertTrue(core.contains(".zig-version"), core)
        XCTAssertTrue(core.contains("test <name.zig>"), core)

        let appimage = try String(contentsOf: root.appendingPathComponent("scripts/linux-appimage.sh"), encoding: .utf8)
        XCTAssertTrue(appimage.contains("SOURCE_DATE_EPOCH"), appimage)
        XCTAssertTrue(appimage.contains("LC_ALL=C"), appimage)
        XCTAssertTrue(appimage.contains("touch -h -d"), appimage)
        XCTAssertTrue(appimage.contains("cmake --install"), appimage)
        XCTAssertTrue(appimage.contains("--strip"), appimage)
        XCTAssertTrue(appimage.contains("appattic-buildinfo/1"), appimage)

        // The generated AppRun sources third-party linuxdeploy hooks that read
        // unset vars such as XDG_CURRENT_DESKTOP. nounset there aborts startup
        // on any session that leaves them unset.
        let heredocStart = try XCTUnwrap(appimage.range(of: "cat > \"$apprun\" <<'EOF'\n"))
        let afterStart = appimage[heredocStart.upperBound...]
        let heredocEnd = try XCTUnwrap(afterStart.range(of: "\nEOF\n"))
        let appRun = String(afterStart[..<heredocEnd.lowerBound])
        XCTAssertTrue(appRun.contains("set -eo pipefail"), appRun)
        XCTAssertFalse(appRun.contains("set -euo pipefail"), appRun)
        XCTAssertTrue(appRun.contains("apprun-hooks"), appRun)
        XCTAssertFalse(appRun.contains("&& source"), appRun)
        XCTAssertTrue(appRun.contains("|| continue"), appRun)

        // linuxdeploy's qt plugin ships only libqxcb.so by default; --smoke is
        // headless and needs the offscreen platform plugin in the AppImage.
        XCTAssertTrue(appimage.contains("EXTRA_PLATFORM_PLUGINS=libqoffscreen.so"), appimage)
        XCTAssertTrue(appimage.contains("usr/plugins/platforms/libqoffscreen.so"), appimage)

        let swiftVersion = try String(contentsOf: root.appendingPathComponent(".swift-version"), encoding: .utf8)
        XCTAssertTrue(swiftVersion.contains("5.10.1"), swiftVersion)
        let zigVersion = try String(contentsOf: root.appendingPathComponent(".zig-version"), encoding: .utf8)
        let zigNeed = zigVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(zigNeed, "0.16.0")

        let check = try String(contentsOf: root.appendingPathComponent("scripts/check.sh"), encoding: .utf8)
        XCTAssertTrue(check.contains("--disable-automatic-resolution"), check)
        XCTAssertTrue(check.contains("scripts/lint.sh"), check)
        XCTAssertTrue(check.contains("AppAtticScanTests"), check)
        XCTAssertTrue(check.contains("find-swift.sh"), check)

        let findSwift = try String(contentsOf: root.appendingPathComponent("scripts/find-swift.sh"), encoding: .utf8)
        XCTAssertTrue(findSwift.contains(".deps/swift/usr/bin"), findSwift)
        XCTAssertTrue(findSwift.contains("/opt/swift/usr/bin"), findSwift)
        XCTAssertTrue(findSwift.contains("swift missing"), findSwift)

        let contributing = try String(contentsOf: root.appendingPathComponent("CONTRIBUTING.md"), encoding: .utf8)
        XCTAssertTrue(contributing.contains("scripts/check.sh"), contributing)
        XCTAssertTrue(contributing.contains("--disable-automatic-resolution"), contributing)

        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("--disable-automatic-resolution"), readme)
        XCTAssertTrue(readme.contains("scripts/check.sh"), readme)
        XCTAssertTrue(readme.contains(".swift-version"), readme)
        XCTAssertTrue(readme.contains("./core/build.sh test brew.zig"), readme)

        let dockerignore = try String(contentsOf: root.appendingPathComponent(".dockerignore"), encoding: .utf8)
        XCTAssertTrue(dockerignore.contains("core/out"), dockerignore)
        XCTAssertTrue(dockerignore.contains("ui/linux-qt/build"), dockerignore)
        XCTAssertTrue(dockerignore.contains(".deps"), dockerignore)

        let lint = try String(contentsOf: root.appendingPathComponent("scripts/lint.sh"), encoding: .utf8)
        XCTAssertTrue(lint.contains("set -euo pipefail"), lint)
        XCTAssertTrue(lint.contains("-P SCRIPTDIR"), lint)

        let yaml = try String(contentsOf: root.appendingPathComponent(".github/workflows/linux.yml"), encoding: .utf8)
        XCTAssertFalse(yaml.contains("continue-on-error: true"), yaml)
        XCTAssertTrue(yaml.contains("5.10.1"), yaml)
        XCTAssertTrue(yaml.contains("--disable-automatic-resolution"), yaml)
        XCTAssertTrue(yaml.contains("contents: read"), yaml)
        XCTAssertTrue(yaml.contains("timeout-minutes:"), yaml)

        XCTAssertTrue(appimage.contains("SMOKE=ok"), appimage)
        XCTAssertTrue(appimage.contains("VERSION=\"${VERSION#v}\""), appimage)

        let docker = try String(contentsOf: root.appendingPathComponent("Dockerfile"), encoding: .utf8)
        XCTAssertTrue(docker.contains("swift:5.10.1-jammy"), docker)
        XCTAssertTrue(docker.contains("LC_ALL=C"), docker)
        XCTAssertTrue(docker.contains("SOURCE_DATE_EPOCH"), docker)
        XCTAssertTrue(docker.contains("--disable-automatic-resolution"), docker)

        let qtMain = try linuxQtSources(root)
        XCTAssertTrue(qtMain.contains("applicationDirPath"), qtMain)
        XCTAssertTrue(qtMain.contains("../share/appattic"), qtMain)
        XCTAssertTrue(qtMain.contains("runHelp"), qtMain)
        XCTAssertTrue(qtMain.contains("--help") && qtMain.contains("-h"), qtMain)
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
