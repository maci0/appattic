import Dispatch
import XCTest
@testable import AppAtticScan

/// Re-run safety of the generated scripts. The second run is the normal case,
/// not the edge one: the person who kept the file runs it again next week.
/// Under `set -e` a line that fails on an already-done target strands every
/// line below it, and a wrapper that makes a line unparseable strands the
/// whole script.
final class ScriptReRunTests: XCTestCase {
    /// Long enough for a `cxbottle` invocation, short enough that a child
    /// waiting on a tty fails the test instead of wedging the suite.
    private static let childTimeout: TimeInterval = 20

    private final class Output {
        var text = ""
    }

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

        // readDataToEndOfFile blocks until EOF with no deadline, so the read
        // runs on its own queue and the test kills the child if it overruns.
        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            drained.signal()
        }
        if drained.wait(timeout: .now() + Self.childTimeout) == .timedOut {
            process.terminate()
            XCTFail("child did not exit within \(Self.childTimeout)s: \(script)")
            _ = drained.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        return (process.terminationStatus, output.text)
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
        var markManualLines = 0
        for manager in managers {
            lines.append(packageRemoveCommand(entry("libfoo", manager)))
            if let keep = packageMarkManualCommand(entry("libfoo", manager, "orphan")) {
                markManualLines += 1
                lines.append(withRootCmd(keep))
            }
        }
        // Only the distro managers take a mark-manual command; losing one would
        // otherwise shorten the list below without failing anything.
        XCTAssertEqual(markManualLines, 5)
        let sources = ["brew-formula", "brew-cask", "flatpak", "snap", "appimage", "steam", "crossover"]
        for source in sources {
            let cmd = uninstallCommand(
                source: source, name: "App", path: "/opt/App", caskName: "app", steamAppId: "42", pkgId: "id"
            )
            // Asserted, not filtered: a source that regresses to a comment would
            // otherwise drop out of this check with nothing failing.
            XCTAssertTrue(
                scriptHasActionableCommands("#!/bin/sh\nset -e\n\(cmd)\n"),
                "\(source) produced no actionable command: \(cmd)"
            )
            lines.append(withRootCmd(cmd))
        }
        lines.append(leftoverRemoveCommand(path: "/tmp/gone", rootLabel: "Application Support"))
        lines.append(leftoverRemoveCommand(path: "/tmp/gone", rootLabel: "LaunchAgents"))
        // 14 removals, 5 mark-manual commands (pacman, apt, dpkg, dnf, zypper),
        // 7 sources, 2 leftover roots.
        XCTAssertEqual(lines.count, 28)
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

    /// The CrossOver bottle delete ran against a bottle that a previous run
    /// removed. `cxbottle --delete` exits nonzero on a bottle that is not
    /// there, and under `set -e` that ends the script before the lines after
    /// it. No `cxbottle` is needed to prove the guard: the bottle directory is
    /// already gone, so both runs must skip the delete and reach the end.
    func testCrossOverBottleDeleteOverAnAlreadyRemovedBottleIsANoOp() throws {
        // Create the bottle and delete it, so "already removed" is a state this
        // test established rather than a path nothing ever touched.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appattic-rerun-\(UUID().uuidString)")
        let missing = root.appendingPathComponent("Bottles/Gone")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: missing)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let cmd = crossoverDeleteCommand(bottleName: "Gone", bottlePath: missing.path)
        let script = "set -e\n\(cmd)\nprintf done"

        for attempt in 1...2 {
            // `cxbottle` may or may not be installed here, and its own
            // complaint is the `|| true` line's business. What matters is that
            // the script reaches its last line both times.
            let (status, text) = try run(script)
            XCTAssertEqual(status, 0, "run \(attempt): \(text)")
            XCTAssertTrue(text.hasSuffix("done"), "run \(attempt): \(text)")
        }
    }
}
