import Foundation
import XCTest
@testable import AppAtticScan
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ProcessTests: XCTestCase {
    /// Slack on top of the production bound before a call counts as unbounded.
    /// Wide enough that a loaded CI runner does not trip it, narrow enough that
    /// a call which waited out its own timeout still fails.
    private static let timingSlack: TimeInterval = 5

    func testRunCommandReturnsLargeStdoutBeforeTimeout() {
        let (rc, out, err) = runCommand(
            ["/bin/sh", "-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' a"],
            timeout: 5
        )
        XCTAssertEqual(rc, 0, err)
        XCTAssertEqual(out.count, 256 * 1024)
    }


    func testRunCommandTimesOutAndKills() {
        let start = monotonicSeconds()
        let (rc, _, err) = runCommand(["/bin/sleep", "30"], timeout: 0.4)
        XCTAssertEqual(rc, 127)
        XCTAssertEqual(err, "timeout")
        XCTAssertLessThan(monotonicSeconds() - start, 0.4 + Self.timingSlack)
    }


    func testRunCommandReturnsPromptlyWhenChildExits() {
        // `/usr/bin/true`: macOS has no /bin/true.
        let (rc, _, err) = runCommand(["/usr/bin/true"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        // No wall-clock bound here: a timeout would report 127 and "timeout",
        // which the two assertions above already rule out, and an elapsed
        // measurement on a loaded runner fails without any defect.
    }


    func testRunCommandDecodesInvalidUTF8() {
        // Octal, not `\xff`: `\x` is a bash printf extension, dash prints it literally.
        let (rc, out, err) = runCommand(["/bin/sh", "-c", "printf '\\377'"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertEqual(out, "\u{FFFD}", "invalid UTF-8 must become a replacement character, not empty (brew JSON would look like a failed command)")
    }


    /// A backgrounded grandchild inherits the write end of the pipe, so
    /// `readDataToEndOfFile` stays blocked after the command itself exited.
    /// The timeout has to bound the whole call, not just the direct child.
    func testRunCommandReturnsWhenGrandchildHoldsThePipe() {
        let start = monotonicSeconds()
        let (rc, _, err) = runCommand(["/bin/sh", "-c", "sleep 8 & exit 0"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertLessThan(
            monotonicSeconds() - start,
            commandPipeDrainGrace + Self.timingSlack,
            "the pipe drain must be bounded, so a lingering grandchild cannot hang the scan"
        )
    }

    /// The window that bounds the drain is the one deadline in this file a
    /// replayed run cannot step unless it is passed in, and a closed window
    /// reports a partial listing under the command's own exit status, which no
    /// caller reads as a failure. A stepping clock closes it, so the same
    /// command whose pipe a grandchild holds open still returns: this hangs
    /// for the grandchild's 8 seconds if the window reads the host's uptime.
    func testRunCommandDrainWindowReadsTheInjectedClock() {
        var elapsed: TimeInterval = 0
        let clock: MonotonicFn = {
            elapsed += 0.5
            return elapsed
        }
        let start = monotonicSeconds()
        let (rc, _, err) = runCommand(["/bin/sh", "-c", "sleep 8 & exit 0"], timeout: 5, clock: clock)
        XCTAssertEqual(rc, 0, err)
        XCTAssertLessThan(
            monotonicSeconds() - start,
            Self.timingSlack,
            "a stepped clock has to close the drain window without the host's uptime"
        )
    }

    /// Bounded output is not the same as a bounded reader: a reader that gives
    /// up only on the caller's grace period outlives the call with its
    /// descriptor open. A scan runs dozens of commands, so those accumulate
    /// for the life of the UI process.
    #if os(Linux)
    func testRunCommandLeavesNoReaderThreadBehind() throws {
        func liveThreads() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/proc/self/task").count
        }
        // Each backgrounded sleep records its pid, so the orphans this test
        // creates are reaped in the teardown instead of living out their 8
        // seconds on a developer machine or a shared CI container.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-orphans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pids = dir.appendingPathComponent("pids")
        addTeardownBlock {
            if let text = try? String(contentsOf: pids, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
                    let killer = Process()
                    killer.executableURL = URL(fileURLWithPath: "/bin/kill")
                    killer.arguments = ["-9", String(pid)]
                    try? killer.run()
                    killer.waitUntilExit()
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        let record = "sleep 8 & echo $! >> \(shellQuote(pids.path)); exit 0"
        func batch() {
            for _ in 0..<8 {
                // The orphan only has to outlive the call's own bound, not half
                // a minute: 24 backgrounded sleeps are created here.
                _ = runCommand(["/bin/sh", "-c", record], timeout: 5)
            }
        }
        // /proc/self/task counts every thread in the process, so compare a
        // steady-state batch against the next one instead of against the first:
        // the GCD pool materializes lazily and its workers belong to whoever
        // ran first. A leaked reader adds two threads per command, so the
        // second batch's growth is where that shows up.
        batch()
        batch()
        let afterWarm = try liveThreads()
        batch()
        XCTAssertLessThanOrEqual(
            try liveThreads() - afterWarm,
            1,
            "each command must release its pipe readers; eight more commands cannot add sixteen threads"
        )
    }
    #endif

    /// The reader threads are joined, but the descriptors they read through
    /// belong to the pipes this call opened. A scan runs hundreds of commands
    /// in one process, so two descriptors left open per command is a slow
    /// exhaustion of the per-process limit, and it fails the next open rather
    /// than the one that leaked.
    #if os(Linux)
    func testRunCommandClosesBothPipeEnds() throws {
        func liveFDs() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
        }
        func batch() {
            for _ in 0..<8 {
                _ = runCommand(["/bin/echo", "piped"], timeout: 5)
            }
        }
        // Same reasoning as the thread test: the first batch also opens what
        // Foundation itself materializes lazily, so growth is measured from a
        // warmed process.
        batch()
        batch()
        let afterWarm = try liveFDs()
        batch()
        XCTAssertLessThanOrEqual(
            try liveFDs() - afterWarm,
            2,
            "each command must close both pipe ends; eight more commands cannot add sixteen descriptors"
        )
    }
    #endif

    func testPmapRunCommandKeepsStdoutWithWorker() {
        let n = 32
        let results = pmap(Array(0..<n), workers: 16) { i -> String in
            let (rc, out, err) = runCommand(["/bin/echo", "item-\(i)"], timeout: 5)
            XCTAssertEqual(rc, 0, err)
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(results.count, n)
        for i in 0..<n {
            XCTAssertEqual(results[i], "item-\(i)")
        }
    }


    private func writeTemp(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }


    func testReadCommandOutputTailReturnsShortFileWhole() throws {
        let url = try writeTemp("short.err", "line one\nline two\n")
        XCTAssertEqual(readCommandOutputTail(from: url), "line one\nline two\n")
    }


    /// The point of the cap: a transaction that printed more than the report
    /// shows must cost the report's bytes, not the run's.
    func testReadCommandOutputTailKeepsOnlyTheLastBytes() throws {
        let url = try writeTemp("big.err", String(repeating: "x", count: 10_000) + "THE END")
        let tail = readCommandOutputTail(from: url, maxBytes: 64)
        XCTAssertEqual(tail, String(repeating: "x", count: 64 - "THE END".count) + "THE END")
    }


    /// A tail that starts mid-character must not open with a replacement.
    /// Five bytes back lands on the second byte of the first `é`.
    func testReadCommandOutputTailDropsPartialLeadingCharacter() throws {
        let url = try writeTemp("utf8.err", "ok" + "\u{00e9}\u{00e9}\u{00e9}")
        let tail = readCommandOutputTail(from: url, maxBytes: 5)
        XCTAssertEqual(tail, "\u{00e9}\u{00e9}")
    }


    func testReadCommandOutputTailOfMissingFileIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-tail-absent-\(UUID().uuidString).err")
        XCTAssertEqual(readCommandOutputTail(from: missing), "")
    }

    func testRunGeneratedScriptReportsFailingLineAndCleanExit() throws {
        let run = try runGeneratedScript("exit 0\n")
        XCTAssertTrue(run.finished)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stderr, "")

        let failed = try runGeneratedScript("set -e\necho first >&2\necho second >&2\nfalse\necho third >&2\n")
        XCTAssertTrue(failed.finished)
        XCTAssertNotEqual(failed.status, 0)
        XCTAssertTrue(failed.stderr.contains("first"), failed.stderr)
        XCTAssertFalse(failed.stderr.contains("third"), "`set -e` must stop the script at the failing line")
    }

    /// A script that outruns the deadline is stopped, not reported as an
    /// ordinary nonzero exit, and the reason says the work before it stands.
    func testRunGeneratedScriptStopsAtTheDeadline() throws {
        let start = monotonicSeconds()
        let run = try runGeneratedScript("echo before-sleep >&2\nsleep 30\n", timeout: 0.5)
        XCTAssertFalse(run.finished)
        XCTAssertEqual(run.status, scriptStoppedStatus)
        XCTAssertTrue(run.stderr.contains("before-sleep"), run.stderr)
        XCTAssertTrue(run.stderr.contains(scriptStoppedNote(timeout: 0.5)), run.stderr)
        XCTAssertLessThan(monotonicSeconds() - start, 0.5 + Self.timingSlack)
    }

    /// The search list `whichCommand` walks is built from PATH and the home
    /// toolchain directories, and a long lived UI runs scans hours after it
    /// started. A list from launch resolves a tool installed since against the
    /// directories the machine had then, so the scan misses it, and the scan
    /// cache fingerprint is built from the same lookups, so nothing invalidates
    /// the snapshot either. `runFullScan` drops the list before it collects;
    /// this pins the drop.
    func testResetWhichSearchDirectoriesPicksUpAPathAddedAfterTheListWasBuilt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appattic-which-reset-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock {
            resetWhichSearchDirectories()
            try? FileManager.default.removeItem(at: root)
        }
        // A name no per-user toolchain directory holds, so the only thing that
        // can resolve it is the PATH entry the test put there.
        let early = "appattic-which-reset-early"
        let late = "appattic-which-reset-late"
        for (dir, name) in [(first, early), (second, late)] {
            let stub = dir.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        addTeardownBlock {
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }

        setenv("PATH", first.path, 1)
        resetWhichSearchDirectories()
        XCTAssertEqual(whichCommand(early), first.appendingPathComponent(early).path)
        XCTAssertNil(whichCommand(late), "the second directory is not on PATH yet")

        setenv("PATH", second.path, 1)
        resetWhichSearchDirectories()
        XCTAssertEqual(whichCommand(late), second.appendingPathComponent(late).path)
    }

    /// Every spawned process, including the generated cleanup and update
    /// scripts, runs with this PATH. The cleanup directories go first so a
    /// stale user copy cannot shadow the one the script is about to remove,
    /// and a directory already listed is not listed twice: a repeat still
    /// resolves, but it makes the script's own comment about the first match
    /// wrong.
    func testAugmentedProcessEnvironmentPutsCleanupDirsFirstWithoutDuplicates() throws {
        // `augmentedProcessEnvironment` reads the account home itself, so the
        // expected list has to be built from the same source. A hardcoded home
        // here made the test assert the runner's account name: it passed only
        // where the home happened to be the literal one.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cleanup = cleanupPathDirectories(home: home)
        let out = augmentedProcessEnvironment(env: [
            "PATH": "/opt/tools:\(cleanup[0]):/opt/tools",
            "APPATTIC_KEEP": "1",
        ])
        let path = try XCTUnwrap(out["PATH"]?.split(separator: ":", omittingEmptySubsequences: false).map(String.init))
        XCTAssertEqual(Array(path.prefix(cleanup.count)), cleanup)
        XCTAssertEqual(Set(path).count, path.count, "a directory listed twice: \(path)")
        XCTAssertEqual(path.last, "/opt/tools", "the caller's own PATH entries are kept: \(path)")
        XCTAssertEqual(out["APPATTIC_KEEP"], "1", "only PATH is rewritten")

        // An empty or absent PATH still yields the cleanup directories, so a
        // process launched from a stripped environment can still find a shell.
        for env in [["PATH": ""], [:]] as [[String: String]] {
            let stripped = augmentedProcessEnvironment(env: env)
            let dirs = try XCTUnwrap(stripped["PATH"]?.split(separator: ":", omittingEmptySubsequences: false).map(String.init))
            XCTAssertEqual(dirs, cleanup, "env=\(env)")
        }
    }
}
