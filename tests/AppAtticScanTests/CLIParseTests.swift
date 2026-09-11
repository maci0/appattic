import XCTest
@testable import AppAtticScan

final class CLIFlagTests: XCTestCase {
    func testParseErrorsUseSwiftErrorHandling() {
        let error: Error = CLIParseError.unknownOption("--wat")
        XCTAssertEqual(error.localizedDescription, "unknown option: --wat")
    }

    func testDefaultCommandIsReport() {
        XCTAssertEqual(parseCLIArguments([]).command, "report")
    }

    func testVersionFlag() {
        XCTAssertTrue(parseCLIArguments(["--version"]).version)
        XCTAssertTrue(parseCLIArguments(["report", "--version"]).version)
    }

    func testCommandsAndFlags() {
        let opts = parseCLIArguments(["leftovers", "--json", "/tmp/out.json", "--include-system", "--dry-run", "--top", "5", "--category", "caches"])
        XCTAssertEqual(opts.command, "leftovers")
        XCTAssertEqual(opts.json, "/tmp/out.json")
        XCTAssertTrue(opts.includeSystem)
        XCTAssertTrue(opts.dryRun)
        XCTAssertEqual(opts.top, 5)
        XCTAssertEqual(opts.category, ["caches"])
        XCTAssertNil(opts.error)
    }

    func testUnknownCommand() {
        XCTAssertEqual(parseCLIArguments(["serve"]).error, "unknown command: serve")
        XCTAssertEqual(parseCLIArguments(["serve"]).parseError, .unknownCommand("serve"))
        XCTAssertEqual(parseCLIArguments(["brew-leaves"]).error, "unknown command: brew-leaves")
        XCTAssertEqual(parseCLIArguments(["brew-leaves"]).parseError, .unknownCommand("brew-leaves"))
    }

    func testUpdateCommand() {
        XCTAssertEqual(parseCLIArguments(["update"]).command, "update")
        XCTAssertTrue(parseCLIArguments(["update", "--dry-run"]).dryRun)
        XCTAssertTrue(cliHelpText.contains("prompts on a TTY"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--dry-run"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--help"), cliHelpText)
    }

    func testDiskCommand() {
        XCTAssertEqual(parseCLIArguments(["disk"]).command, "disk")
        let opts = parseCLIArguments(["disk", "/var", "--allocated", "--all-file-systems", "--top", "5"])
        XCTAssertEqual(opts.command, "disk")
        XCTAssertEqual(opts.diskPath, "/var")
        XCTAssertTrue(opts.allocated)
        XCTAssertTrue(opts.allFileSystems)
        XCTAssertEqual(opts.top, 5)
        XCTAssertNil(opts.error)
        XCTAssertTrue(cliHelpText.contains("disk"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--all-file-systems"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--allocated"), cliHelpText)
        XCTAssertEqual(parseCLIArguments(["disk", "/a", "/b"]).error, "unexpected argument: /b")
    }

    func testPackagesCommand() {
        XCTAssertEqual(parseCLIArguments(["packages"]).command, "packages")
        XCTAssertTrue(cliHelpText.contains("packages"))
        XCTAssertTrue(cliHelpText.contains("leftovers + stale + outdated + packages"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("skip stale, outdated, and packages"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("skip leftovers, outdated, and packages"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("cannot turn includeSystem off"), cliHelpText)
    }

    func testHelpMentionsSettingsFile() {
        XCTAssertTrue(cliHelpText.contains("settings.json"))
        XCTAssertTrue(cliHelpText.contains("XDG_DATA_HOME"))
        XCTAssertTrue(cliHelpText.contains("ignored leftover"))
        XCTAssertTrue(cliHelpText.contains("malformed"))
    }

    func testReportOnlyFlags() {
        let leftovers = parseCLIArguments(["--leftovers-only"])
        XCTAssertTrue(leftovers.leftoversOnly)
        XCTAssertNil(leftovers.error)
        let stale = parseCLIArguments(["--stale-only"])
        XCTAssertTrue(stale.staleOnly)
        XCTAssertNil(stale.error)
        let both = parseCLIArguments(["--leftovers-only", "--stale-only"])
        XCTAssertEqual(both.error, "--leftovers-only and --stale-only cannot be combined")
        XCTAssertEqual(both.parseError, .conflictingFilters)
    }

    func testUnknownOptionAndUnexpectedArgument() {
        XCTAssertEqual(parseCLIArguments(["--nope"]).error, "unknown option: --nope")
        XCTAssertEqual(parseCLIArguments(["--nope"]).parseError, .unknownOption("--nope"))
        XCTAssertEqual(parseCLIArguments(["report", "extra"]).error, "unexpected argument: extra")
        XCTAssertEqual(parseCLIArguments(["report", "extra"]).parseError, .unexpectedArgument("extra"))
    }

    func testHelpAndShortFlags() {
        XCTAssertTrue(parseCLIArguments(["--help"]).help)
        XCTAssertTrue(parseCLIArguments(["-h"]).help)
        XCTAssertTrue(parseCLIArguments(["-v"]).version)
        XCTAssertNil(parseCLIArguments(["-h"]).error)
    }

    func testMissingOptionValues() {
        XCTAssertEqual(parseCLIArguments(["--json"]).error, "--json requires a file path")
        XCTAssertEqual(parseCLIArguments(["--json"]).parseError, .jsonRequiresPath)
        XCTAssertEqual(parseCLIArguments(["--top"]).error, "--top requires a non-negative integer")
        XCTAssertEqual(parseCLIArguments(["--top"]).parseError, .topRequiresNonNegativeInteger)
        XCTAssertEqual(parseCLIArguments(["--top=abc"]).error, "--top requires a non-negative integer")
        XCTAssertEqual(parseCLIArguments(["--category"]).error, "--category requires a value")
        XCTAssertEqual(parseCLIArguments(["--category"]).parseError, .categoryRequiresValue)
        XCTAssertEqual(parseCLIArguments(["--top=5"]).top, 5)
    }

    func testTopRejectsNegative() {
        XCTAssertEqual(parseCLIArguments(["--top", "-1"]).error, "--top requires a non-negative integer")
        XCTAssertEqual(parseCLIArguments(["--top", "-1"]).parseError, .topRequiresNonNegativeInteger)
        XCTAssertEqual(parseCLIArguments(["--top=-2"]).error, "--top requires a non-negative integer")
        XCTAssertEqual(parseCLIArguments(["--top", "3"]).top, 3)
    }

    func testFreshFlag() {
        XCTAssertFalse(parseCLIArguments(["report"]).fresh)
        let opts = parseCLIArguments(["report", "--fresh"])
        XCTAssertTrue(opts.fresh)
        XCTAssertNil(opts.error)
        XCTAssertTrue(cliHelpText.contains("--fresh"))
    }

    func testCategoryEqualsForm() {
        let opts = parseCLIArguments(["leftovers", "--category=caches"])
        XCTAssertEqual(opts.category, ["caches"])
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["leftovers", "--category="]).error, "--category requires a value")
    }

    func testJsonEqualsForm() {
        let opts = parseCLIArguments(["report", "--json=/tmp/out.json"])
        XCTAssertEqual(opts.json, "/tmp/out.json")
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["report", "--json="]).error, "--json requires a file path")
    }
}
