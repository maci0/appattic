import Foundation
import XCTest
@testable import AppAtticScan

final class ProcessTests: XCTestCase {
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
        XCTAssertLessThan(monotonicSeconds() - start, 3)
    }


    func testRunCommandReturnsPromptlyWhenChildExits() {
        let start = monotonicSeconds()
        // `/usr/bin/true`: macOS has no /bin/true.
        let (rc, _, err) = runCommand(["/usr/bin/true"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertLessThan(monotonicSeconds() - start, 1.5)
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
        let (rc, _, err) = runCommand(["/bin/sh", "-c", "sleep 6 & exit 0"], timeout: 5)
        XCTAssertEqual(rc, 0, err)
        XCTAssertLessThan(
            monotonicSeconds() - start,
            commandPipeDrainGrace + 1.5,
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
        _ = runCommand(["/bin/sh", "-c", "sleep 30 & exit 0"], timeout: 5)
        let after = try liveThreads()
        for _ in 0..<8 {
            _ = runCommand(["/bin/sh", "-c", "sleep 30 & exit 0"], timeout: 5)
        }
        XCTAssertLessThanOrEqual(
            try liveThreads(),
            after + 1,
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
}
