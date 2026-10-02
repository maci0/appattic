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
    /// How long a terminated child is given to go away before it is killed.
    private static let terminateGrace: TimeInterval = 5

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
            // `waitUntilExit` has no deadline, so a child that ignores
            // SIGTERM would wedge the whole suite instead of failing this
            // test. Escalate, then give up on the reaped status: the
            // assertion above already failed.
            stopChild(process)
        } else {
            process.waitUntilExit()
        }
        return (process.terminationStatus, output.text)
    }

    /// Bounded reap: SIGTERM, then SIGKILL, then move on.
    private func stopChild(_ process: Process) {
        let deadline = Date().addingTimeInterval(Self.terminateGrace)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        guard process.isRunning else { return }
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/kill")
        killer.arguments = ["-9", String(process.processIdentifier)]
        try? killer.run()
        killer.waitUntilExit()
        let hard = Date().addingTimeInterval(Self.terminateGrace)
        while process.isRunning && Date() < hard {
            usleep(50_000)
        }
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

    /// The pacman upgrade is guarded, because `pacman -S` on a package that is
    /// already at the newest version is a reinstall: the download, the install
    /// scripts, and the database entry happen again. The stub answers `-Qu`
    /// the way pacman does, exiting 0 only while the package is still behind,
    /// so the first run upgrades and the second has to skip the line.
    func testSecondRunOfAPacmanUpgradeDoesNotReinstall() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appattic-rerun-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let installed = root.appendingPathComponent("installed")
        let upgrades = root.appendingPathComponent("upgrades")
        // The row `pacman -Q vim` prints: name and version, one per line.
        try "vim 9.0-1\n".write(to: installed, atomically: true, encoding: .utf8)
        try "".write(to: upgrades, atomically: true, encoding: .utf8)
        let stub = bin.appendingPathComponent("pacman")
        let stubBody = """
        #!/bin/sh
        if [ "$1" = "-Qu" ]; then
          if grep -q 'vim 9.1-1' "\(installed.path)"; then exit 1; fi
          exit 0
        fi
        if [ "$1" = "--noconfirm" ] && [ "$2" = "-S" ]; then
          printf 'upgraded %s\\n' "$3" >> "\(upgrades.path)"
          printf 'vim 9.1-1\\n' > "\(installed.path)"
          exit 0
        fi
        printf 'unexpected pacman %s\\n' "$*" >&2
        exit 1
        """
        try stubBody.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        addTeardownBlock {
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }
        setenv("PATH", "\(bin.path):\(savedPath ?? "")", 1)

        let pkg = OutdatedPkg(name: "vim", manager: "pacman", currentVersion: "9.0-1", latestVersion: "9.1-1")
        let line = try XCTUnwrap(updateCommand(pkg), "a pacman row always has an upgrade command")
        let script = "set -e\n\(line)\nprintf done"

        let first = try run(script)
        XCTAssertEqual(first.0, 0, first.1)
        XCTAssertEqual(first.1, "done", first.1)
        XCTAssertEqual(try String(contentsOf: upgrades, encoding: .utf8), "upgraded vim\n")

        let second = try run(script)
        XCTAssertEqual(second.0, 0, second.1)
        XCTAssertEqual(second.1, "done", second.1)
        XCTAssertEqual(
            try String(contentsOf: upgrades, encoding: .utf8),
            "upgraded vim\n",
            "the second run reinstalled a package the first run had already upgraded"
        )
    }

    /// The mark-manual line, run twice, over a package the first run's removal
    /// purged. These rows are the `orphan` rows, which is exactly what a remove
    /// line purges, and both lists are generated from one snapshot into one
    /// script file, so a re-run reaches a mark-manual line for a package that
    /// is gone. Every manager answers that with a nonzero exit, and under
    /// `set -e` that stops the script before the lines below it, so a run that
    /// changed nothing ends on a status that reads like a failure.
    ///
    /// The stub stands in for the manager: it answers the presence query the
    /// way `dpkg -s` does, so a line that lost its guard strands the script
    /// here instead of passing quietly.
    func testSecondRunOfAMarkManualOverAPurgedPackageIsANoOp() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appattic-rerun-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // A file stands for the package in the database: `dpkg -s` answers 0
        // while it is there, and the mark is recorded by appending to it. The
        // first run marks the package; removing that file is what the same
        // script's remove line would have done.
        let marked = root.appendingPathComponent("marked")
        try Data().write(to: marked)
        let dpkg = bin.appendingPathComponent("dpkg")
        try "#!/bin/sh\ntest -e \(shellQuote(marked.path))\n".write(to: dpkg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dpkg.path)
        // `apt-mark manual` cannot find a package dpkg does not know, so it
        // fails when the mark file is gone and a bare call strands the script.
        let aptMark = bin.appendingPathComponent("apt-mark")
        try """
        #!/bin/sh
        test -e \(shellQuote(marked.path)) || exit 1
        printf 'marked\\n' >> \(shellQuote(marked.path))
        """.write(to: aptMark, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: aptMark.path)

        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        addTeardownBlock {
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }
        setenv("PATH", "\(bin.path):\(savedPath ?? "")", 1)

        let cmd = try XCTUnwrap(
            packageMarkManualCommand(entry("libfoo", "apt", "orphan")),
            "an apt orphan takes a mark-manual command"
        )
        let guarded = try XCTUnwrap(parseGuardedRemove(cmd), "untrapped mark: \(cmd)")
        XCTAssertEqual(guarded.present, "dpkg -s libfoo", cmd)
        XCTAssertEqual(guarded.action, "apt-mark manual libfoo", cmd)

        let script = "set -e\n\(cmd)\nprintf done"
        let first = try run(script)
        XCTAssertEqual(first.0, 0, first.1)
        XCTAssertEqual(first.1, "done", first.1)
        XCTAssertEqual(
            try String(contentsOf: marked, encoding: .utf8),
            "marked\n",
            "a mark that is already set is not a second mark"
        )

        // The package is gone now, the way a remove line in the same script
        // would have left it.
        try FileManager.default.removeItem(at: marked)

        let second = try run(script)
        XCTAssertEqual(second.0, 0, "the second run aborted on a package the first removed: \(second.1)")
        XCTAssertEqual(second.1, "done", "set -e stranded the lines below the mark: \(second.1)")
    }

    /// Each line the app can generate parses on its own, so one bad line cannot
    /// take the rest of a multi-selection script down with it. The mark-manual
    /// lines are in the same list and carry the same guard the removals do, so
    /// a line that lost it is caught here rather than by a re-run.
    func testEveryRemovalAndKeepLineParsesAlone() throws {
        var lines: [String] = []
        var markManualLines = 0
        for manager in managers {
            lines.append(packageRemoveCommand(entry("libfoo", manager)))
            if let keep = packageMarkManualCommand(entry("libfoo", manager, "orphan")) {
                markManualLines += 1
                XCTAssertNotNil(
                    parseGuardedRemove(keep),
                    "a mark for a package an earlier run removed is unguarded: \(keep)"
                )
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
            remove: "rm -f \(shellQuote(target.path)); printf 'removed\\n'"
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

    /// The Steam handoff, run twice, on a machine with no Steam client.
    /// `steam` and `open` both exit nonzero when there is nothing to hand the
    /// URI to, and under `set -e` that ends the script before the removals
    /// below it. The client does the uninstalling, so its status says nothing
    /// about what was removed, and a second run has to reach the same lines
    /// the first one did.
    func testSteamHandoffTwiceWithoutAClientDoesNotStrandTheScript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appattic-rerun-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let cmd = uninstallCommand(
            source: "steam",
            name: "Game",
            path: "/home/u/.steam/steam/steamapps/common/Game",
            caskName: nil,
            steamAppId: "42"
        )
        XCTAssertTrue(cmd.contains("steam://uninstall/42"), cmd)
        XCTAssertTrue(cmd.hasSuffix("|| true"), "an untrapped handoff strands the script: \(cmd)")

        // The stub is named for the binary the line runs, which is the client
        // on Linux and `open` on macOS, and fails the way neither is found.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let name = try XCTUnwrap(cmd.split(separator: " ").first.map(String.init), cmd)
        let stub = bin.appendingPathComponent(name)
        try "#!/bin/sh\nexit 127\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        addTeardownBlock {
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }
        setenv("PATH", "\(bin.path):\(savedPath ?? "")", 1)

        let script = "set -e\n\(cmd)\nprintf done"
        for attempt in 1...2 {
            let (status, text) = try run(script)
            XCTAssertEqual(status, 0, "run \(attempt): \(text)")
            XCTAssertEqual(text, "done", "run \(attempt): \(text)")
        }
    }

    /// The CrossOver bottle delete ran against a bottle that a previous run
    /// removed. `cxbottle --delete` exits nonzero on a bottle that is not
    /// there, and under `set -e` that ends the script before the lines after
    /// it. The stub below fails every invocation the way the real tool does on
    /// a missing bottle, so a delete that is not skipped strands the script
    /// instead of quietly passing.
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

        // A stub on PATH, so the test does not depend on whether CrossOver is
        // installed here. `whichCommand` caches its search list for the
        // process, so a real `cxbottle` found first by an earlier test still
        // wins; the guard assertions below hold either way, and the stub only
        // makes the "delete never ran" half unconditional.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("cxbottle")
        try "#!/bin/sh\nprintf 'cxbottle %s\\n' \"$*\" >&2\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        addTeardownBlock {
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }
        setenv("PATH", "\(bin.path):\(savedPath ?? "")", 1)

        let cmd = crossoverDeleteCommand(bottleName: "Gone", bottlePath: missing.path)
        let lines = cmd.split(separator: "\n").map(String.init)
        let delete = try XCTUnwrap(lines.last, "the delete must be the last line")
        let guardLine = try XCTUnwrap(parseGuardedRemove(delete), "untrapped delete: \(delete)")
        XCTAssertEqual(guardLine.present, "test -d \(shellQuote(missing.path))", delete)
        XCTAssertTrue(guardLine.action.contains("--delete"), delete)

        let script = "set -e\n\(cmd)\nprintf done"
        for attempt in 1...2 {
            // The uninstall line is `|| true`, so the stub's complaint is that
            // line's business. The delete line is not: it has to be skipped, or
            // `set -e` stops the script before `printf done`.
            let (status, text) = try run(script)
            XCTAssertEqual(status, 0, "run \(attempt): \(text)")
            XCTAssertTrue(text.hasSuffix("done"), "run \(attempt): \(text)")
            XCTAssertFalse(text.contains("--delete"), "delete ran on a removed bottle, run \(attempt): \(text)")
        }
    }
}
