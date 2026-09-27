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
