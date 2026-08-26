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
        let iconGen = try String(contentsOf: root.appendingPathComponent("generate_icon.py"), encoding: .utf8)
        XCTAssertTrue(iconGen.contains("AppAttic.icns"), iconGen)
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
        XCTAssertTrue(deps.contains("no apt zig"), deps.lowercased())
        XCTAssertTrue(deps.contains("emit_ci_path"), deps)
        XCTAssertTrue(deps.contains("GITHUB_PATH"), deps)
        XCTAssertFalse(deps.contains("gtk4"), deps)
        XCTAssertFalse(deps.contains("libgtk-4-dev"), deps)
        XCTAssertTrue(deps.contains("swiftly") || deps.contains("swift-bin"), deps)
        XCTAssertTrue(deps.contains("5.10"), deps)
        XCTAssertTrue(yaml.contains("Put zig on PATH"), yaml)
        XCTAssertTrue(yaml.contains("GITHUB_PATH"), yaml)
        XCTAssertTrue(yaml.contains("ca-certificates"), yaml)
        XCTAssertTrue(yaml.contains("archlinux"), yaml)
        let archDocker = try String(contentsOf: root.appendingPathComponent("Dockerfile.arch"), encoding: .utf8)
        XCTAssertTrue(archDocker.contains("archlinux"), archDocker)
        XCTAssertTrue(archDocker.contains("qt6-base"), archDocker)
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
        let qtMain = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/main.cpp"), encoding: .utf8)
        XCTAssertTrue(qtMain.contains("QMainWindow"), qtMain)
        XCTAssertTrue(qtMain.contains("appattic_wasm_run"), qtMain)
        XCTAssertTrue(qtMain.contains("QTreeWidget"), qtMain)
        XCTAssertTrue(qtMain.contains("QListWidget"), qtMain)
        XCTAssertTrue(qtMain.contains("Include in cleanup"), qtMain)
        XCTAssertTrue(qtMain.contains("Ignore leftover"), qtMain)
        XCTAssertTrue(qtMain.contains("Review Script"), qtMain)
        XCTAssertTrue(qtMain.contains("apt-mark manual"), qtMain)
        XCTAssertTrue(qtMain.contains("PaletteChange"), qtMain)
        XCTAssertTrue(qtMain.contains("currentVersion") || qtMain.contains("current_version"), qtMain)
        XCTAssertTrue(qtMain.contains("lastUsed") || qtMain.contains("last_used"), qtMain)
        XCTAssertTrue(qtMain.contains("Location"), qtMain)
        XCTAssertTrue(qtMain.contains("Last used"), qtMain)
        XCTAssertTrue(qtMain.contains("QThread"), qtMain)
        XCTAssertFalse(qtMain.contains("gtk.h"), qtMain)
        XCTAssertFalse(qtMain.contains("Gtk"), qtMain)
        XCTAssertFalse(qtMain.lowercased().contains("phosphor"), qtMain)
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/AppAttic/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(ui.contains("case packages = \"Packages\""), ui)
        XCTAssertFalse(qtMain.contains("0x1e, 0x1e, 0x1e"), qtMain)
        XCTAssertTrue(qtMain.contains("pluginWasmFiles"), qtMain)
        XCTAssertTrue(qtMain.contains("bodyFont"), qtMain)
        XCTAssertTrue(qtMain.contains("isShadowFinding"), qtMain)
        XCTAssertTrue(qtMain.contains("leftoverCleanupCommand"), qtMain)
        XCTAssertTrue(qtMain.contains("isProtectedPackagedPath"), qtMain)
        XCTAssertTrue(qtMain.contains("addFact(QStringLiteral(\"Shadows\")"), qtMain)
        XCTAssertTrue(qtMain.contains("path_shadow.wasm"), qtMain)
        XCTAssertFalse(qtMain.contains("addFact(QStringLiteral(\"Hides\")"), qtMain)
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
        let qtMain = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/main.cpp"), encoding: .utf8)
        for (id, wasm) in needed {
            let manifestURL = root.appendingPathComponent("core/plugins/\(id)/manifest.json")
            let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            XCTAssertTrue(manifest.contains("\"url\": \"\(wasm)\""), manifest)
            XCTAssertTrue(build.contains(wasm), "build.sh missing \(wasm)")
            XCTAssertTrue(qtMain.contains(wasm), "main.cpp missing \(wasm)")
        }
        let overlay = try String(
            contentsOf: root.appendingPathComponent("core/plugins/path-overlay-shadow/manifest.json"),
            encoding: .utf8
        )
        XCTAssertTrue(overlay.contains("\"url\": null"), overlay)
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

        let qtMain = try String(contentsOf: root.appendingPathComponent("ui/linux-qt/main.cpp"), encoding: .utf8)
        XCTAssertTrue(qtMain.contains("static int runSmoke"), qtMain)
        let runSmokeBody = qtMain.components(separatedBy: "static int runSmoke").dropFirst().first ?? ""
        XCTAssertTrue(
            runSmokeBody.contains("qputenv(\"APPATTIC_HOST_EXEC_FIXTURE\", \"1\")"),
            qtMain
        )
    }

    func testLinuxQtLinkScriptRefusesDarwin() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/linux-qt-link.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        let err = Pipe()
        process.standardOutput = err
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #if os(Linux)
        XCTAssertNotEqual(process.terminationStatus, 3, text)
        #else
        XCTAssertEqual(process.terminationStatus, 3, text)
        XCTAssertTrue(text.lowercased().contains("not linux"), text)
        XCTAssertTrue(text.lowercased().contains("homebrew"), text)
        #endif
    }
}
