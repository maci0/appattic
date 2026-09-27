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
        let serve = parseCLIArguments(["serve"])
        XCTAssertEqual(serve.parseError, .unknownCommand("serve"))
        XCTAssertEqual(
            serve.error,
            "unknown command: serve; try one of: config, disk, leftovers, outdated, packages, report, stale, update"
        )
        let leaves = parseCLIArguments(["brew-leaves"])
        XCTAssertEqual(leaves.parseError, .unknownCommand("brew-leaves"))
        XCTAssertTrue(leaves.error?.hasPrefix("unknown command: brew-leaves") == true, leaves.error ?? "")
    }

    func testMisspelledCommandSuggestsTheNearestOne() {
        XCTAssertEqual(
            parseCLIArguments(["updat"]).error,
            "unknown command: updat (did you mean 'update'?)"
        )
        XCTAssertEqual(
            parseCLIArguments(["dusk"]).error,
            "unknown command: dusk (did you mean 'disk'?)"
        )
        XCTAssertNil(nearestCLICommand("serve"))
    }

    func testConfigCommandTakesNoPositionalArgument() {
        XCTAssertEqual(parseCLIArguments(["config"]).command, "config")
        XCTAssertNil(parseCLIArguments(["config"]).error)
        XCTAssertTrue(cliHelpText.contains("appattic config"), cliHelpText)
        XCTAssertEqual(
            parseCLIArguments(["config", "extra"]).parseError,
            .unexpectedArgument("extra")
        )
    }

    func testUpdateCommand() {
        XCTAssertEqual(parseCLIArguments(["update"]).command, "update")
        XCTAssertTrue(parseCLIArguments(["update", "--dry-run"]).dryRun)
        XCTAssertTrue(cliHelpText.contains("prompts on a TTY"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--dry-run"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("--help"), cliHelpText)
    }

    func testYesSkipsTheUpdatePrompt() {
        XCTAssertTrue(parseCLIArguments(["update", "--yes"]).yes)
        XCTAssertTrue(parseCLIArguments(["update", "-y"]).yes)
        XCTAssertNil(parseCLIArguments(["update", "--yes"]).error)
        XCTAssertFalse(parseCLIArguments(["update"]).yes)
        XCTAssertTrue(cliHelpText.contains("--yes, -y"), cliHelpText)
    }

    func testYesIsRejectedOnEveryOtherCommand() {
        for args in [["--yes"], ["report", "--yes"], ["leftovers", "-y"], ["disk", "/var", "--yes"]] {
            XCTAssertEqual(parseCLIArguments(args).parseError, .yesNeedsUpdateCommand, args.joined(separator: " "))
            XCTAssertEqual(
                parseCLIArguments(args).error,
                "--yes only applies to the update command",
                args.joined(separator: " ")
            )
        }
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

    func testCategoryTakesOneValueAndRepeats() {
        let opts = parseCLIArguments(["leftovers", "--category", "caches", "--category", "browser"])
        XCTAssertEqual(opts.category, ["caches", "browser"])
        XCTAssertNil(opts.error)
        // A command after the value is the command, not another category.
        let trailing = parseCLIArguments(["--category", "caches", "stale"])
        XCTAssertEqual(trailing.command, "stale")
        XCTAssertEqual(trailing.category, ["caches"])
        XCTAssertNil(trailing.error)
        XCTAssertEqual(parseCLIArguments(["--category", "-x"]).parseError, .categoryRequiresValue)
    }

    func testJsonEqualsForm() {
        let opts = parseCLIArguments(["report", "--json=/tmp/out.json"])
        XCTAssertEqual(opts.json, "/tmp/out.json")
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["report", "--json="]).error, "--json requires a file path")
    }

    func testHelpAndVersionAreStillParsedAfterAParseError() {
        let help = parseCLIArguments(["--nope", "--help"])
        XCTAssertTrue(help.help)
        XCTAssertEqual(help.parseError, .unknownOption("--nope"))
        XCTAssertTrue(parseCLIArguments(["--top", "--help"]).help)
        XCTAssertTrue(parseCLIArguments(["disk", "/a", "/b", "-h"]).help)
        XCTAssertTrue(parseCLIArguments(["--nope", "-v"]).version)
    }

    func testTheFirstErrorWins() {
        XCTAssertEqual(parseCLIArguments(["--nope", "serve"]).error, "unknown option: --nope")
    }

    func testDiskOnlyOptionsAreRejectedElsewhere() {
        for args in [["report", "--allocated"], ["stale", "--allocated"], ["--allocated"]] {
            XCTAssertEqual(
                parseCLIArguments(args).error,
                "--allocated only applies to the disk command",
                args.joined(separator: " ")
            )
        }
        XCTAssertEqual(
            parseCLIArguments(["report", "--all-file-systems"]).error,
            "--all-file-systems only applies to the disk command"
        )
        XCTAssertNil(parseCLIArguments(["disk", "/var", "--allocated"]).error)
        XCTAssertNil(parseCLIArguments(["disk", "--all-file-systems"]).error)
    }

    func testReportOnlyOptionsAreRejectedElsewhere() {
        for option in ["--leftovers-only", "--stale-only"] {
            XCTAssertEqual(
                parseCLIArguments(["disk", option]).error,
                "\(option) only applies to the report command",
                option
            )
            XCTAssertEqual(
                parseCLIArguments(["update", option]).error,
                "\(option) only applies to the report command",
                option
            )
            XCTAssertNil(parseCLIArguments([option]).error, option)
        }
    }

    func testConflictingFiltersStillWinOverPerCommandOptions() {
        XCTAssertEqual(parseCLIArguments(["disk", "--leftovers-only", "--stale-only"]).error, "--leftovers-only and --stale-only cannot be combined")
        XCTAssertEqual(parseCLIArguments(["report", "--yes", "--allocated"]).error, "--yes only applies to the update command")
    }

    func testHelpDocumentsThePerCommandOptionRule() {
        XCTAssertTrue(cliHelpText.contains("usage error on every other command"), cliHelpText)
    }

    func testHelpDocumentsExitCodesExamplesAndDiskPath() {
        XCTAssertTrue(cliHelpText.contains("exit codes:"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("usage error"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("examples:"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("appattic update --yes"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("disk [PATH]"), cliHelpText)
    }
}

final class CLIToneTests: XCTestCase {
    /// The three status roles are the remove, review, and keep colors the two
    /// windows use, so a report in a terminal and the same row in a window
    /// carry the same meaning.
    func testToneMatchesTheWindowStatusColors() {
        XCTAssertEqual(CliTone.light.forRole(.remove), "38;2;192;28;40")
        XCTAssertEqual(CliTone.light.forRole(.review), "38;2;158;102;0")
        XCTAssertEqual(CliTone.light.forRole(.keep), "38;2;36;138;61")
        XCTAssertEqual(CliTone.dark.forRole(.remove), "38;2;255;69;58")
        XCTAssertEqual(CliTone.dark.forRole(.review), "38;2;255;214;10")
        XCTAssertEqual(CliTone.dark.forRole(.keep), "38;2;48;209;88")
    }

    func testToneFollowsColorFgbg() {
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15;0"]), .dark)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15;6"]), .dark)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15;49"]), .dark)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "0;93"]), .light)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "0;100"]), .light)
    }

    /// 7 is "white" as an xterm palette index and "7 percent" as a
    /// percentage, and a malformed value says nothing, so all of them fall
    /// back to the pair that stays readable on a light background.
    func testToneFallsBackToLightWhenTheBackgroundIsUnknown() {
        XCTAssertEqual(cliTone(env: [:]), .light)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": ""]), .light)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15"]), .light)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15;0;0"]), .light)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15;7"]), .light)
        XCTAssertEqual(cliTone(env: ["COLORFGBG": "15;dark"]), .light)
    }
}
