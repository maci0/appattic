import Foundation
import XCTest
@testable import AppAtticScan

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

    /// Bounded output is not the same as a bounded reader: a reader that gives
    /// up only on the caller's grace period outlives the call with its
    /// descriptor open. A scan runs dozens of commands, so those accumulate
    /// for the life of the UI process.
    #if os(Linux)
    func testRunCommandLeavesNoReaderThreadBehind() throws {
        func liveThreads() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/proc/self/task").count
        }
        func batch() {
            for _ in 0..<8 {
                // The orphan only has to outlive the call's own bound, not half
                // a minute: 24 backgrounded sleeps are left on the host here.
                _ = runCommand(["/bin/sh", "-c", "sleep 8 & exit 0"], timeout: 5)
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
}
