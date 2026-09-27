import XCTest
@testable import AppAtticScan

/// Re-run safety of the generated scripts. The second run is the normal case,
/// not the edge one: the person who kept the file runs it again next week.
/// Under `set -e` a line that fails on an already-done target strands every
/// line below it, and a wrapper that makes a line unparseable strands the
/// whole script.
final class ScriptReRunTests: XCTestCase {
    private func run(_ script: String, _ args: [String] = []) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    private func parses(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (status, text) = try run(script, ["-n"])
        XCTAssertEqual(status, 0, text, file: file, line: line)
    }

    private func entry(_ name: String, _ manager: String, _ kind: String = "orphan") -> PackageEntry {
        PackageEntry(name: name, manager: manager, kind: kind)
    }

    private let managers = ["pacman", "aur", "apt", "dpkg", "dnf", "yum", "zypper",
                            "npm", "pnpm", "bun", "pipx", "uv", "pip", "deno"]

    /// Every package script line parses, escalated or not. `rootcmd` ahead of a
    /// guard produced `rootcmd if ...; then ...; fi`, which is not shell.
    func testPackageScriptParsesForEveryManager() throws {
        let script = packageActionScript(
            remove: managers.map { entry("libfoo", $0, $0 == "npm" || $0 == "deno" ? "global" : "orphan") },
            markManual: [entry("libkeep", "apt", "orphan")]
        )
        XCTAssertTrue(script.contains("rootcmd() {"), script)
        XCTAssertFalse(script.contains("rootcmd if"), script)
        try parses(script)
    }

    /// The update script keeps the plain prefix, and the helper is defined for
    /// the distro upgrades that need it.
    func testUpdateScriptParses() throws {
        let script = updateScript([
            OutdatedPkg(name: "firefox", manager: "pacman", currentVersion: "1", latestVersion: "2"),
            OutdatedPkg(name: "git", manager: "apt", currentVersion: "1", latestVersion: "2")
        ])
        XCTAssertTrue(script.contains("rootcmd pacman --noconfirm -S firefox"), script)
        XCTAssertTrue(script.contains("rootcmd() {"), script)
        try parses(script)
    }

    /// Each line the app can generate parses on its own, so one bad line cannot
    /// take the rest of a multi-selection script down with it.
    func testEveryRemovalAndKeepLineParsesAlone() throws {
        var lines: [String] = []
        for manager in managers {
            lines.append(packageRemoveCommand(entry("libfoo", manager)))
            if let keep = packageMarkManualCommand(entry("libfoo", manager, "orphan")) {
                lines.append(withRootCmd(keep))
            }
        }
        for source in ["brew-formula", "brew-cask", "flatpak", "snap", "appimage", "steam", "crossover"] {
            let cmd = uninstallCommand(
                source: source, name: "App", path: "/opt/App", caskName: "app", steamAppId: "42", pkgId: "id"
            )
            if scriptHasActionableCommands("#!/bin/sh\nset -e\n\(cmd)\n") {
                lines.append(withRootCmd(cmd))
            }
        }
        lines.append(leftoverRemoveCommand(path: "/tmp/gone", rootLabel: "Application Support"))
        lines.append(leftoverRemoveCommand(path: "/tmp/gone", rootLabel: "LaunchAgents"))
        for line in lines {
            try parses("set -e\n\(line)\n")
        }
    }

    /// Running a guarded removal twice leaves the same state: the second run
    /// skips a target that is already gone, exits 0, and the lines after it
    /// still run.
    func testSecondRunOfAGuardedRemovalIsANoOp() throws {
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appattic-rerun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: target)

        let line = guardedRemoveCommand(
            present: "test -e \(shellQuote(target.path))",
            remove: "rm -f \(shellQuote(target.path)); printf removed"
        )
        let script = "set -e\n\(line)\nprintf done"

        let first = try run(script)
        XCTAssertEqual(first.0, 0, first.1)
        XCTAssertEqual(first.1, "removed\ndone", first.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let second = try run(script)
        XCTAssertEqual(second.0, 0, second.1)
        XCTAssertEqual(second.1, "done", second.1)
    }
}
