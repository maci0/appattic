import Foundation

public enum CLIParseError: Error, Equatable, LocalizedError, Sendable, CustomStringConvertible {
    case jsonRequiresPath
    case topRequiresNonNegativeInteger
    case categoryRequiresValue
    case unknownOption(String)
    case unknownCommand(String)
    case unexpectedArgument(String)
    case conflictingFilters

    public var description: String {
        switch self {
        case .jsonRequiresPath:
            return "--json requires a file path"
        case .topRequiresNonNegativeInteger:
            return "--top requires a non-negative integer"
        case .categoryRequiresValue:
            return "--category requires a value"
        case .unknownOption(let option):
            return "unknown option: \(option)"
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .unexpectedArgument(let argument):
            return "unexpected argument: \(argument)"
        case .conflictingFilters:
            return "--leftovers-only and --stale-only cannot be combined"
        }
    }

    public var errorDescription: String? { description }
}

public struct CLIOptions {
    public var command: String
    public var json: String?
    public var includeSystem: Bool
    public var dryRun: Bool
    public var top: Int?
    public var category: [String]
    public var leftoversOnly: Bool
    public var staleOnly: Bool
    public var fresh: Bool
    public var noColor: Bool
    public var version: Bool
    public var help: Bool
    public var parseError: CLIParseError?
    public var error: String? { parseError?.description }

    public init(
        command: String = "report",
        json: String? = nil,
        includeSystem: Bool = false,
        dryRun: Bool = false,
        top: Int? = nil,
        category: [String] = [],
        leftoversOnly: Bool = false,
        staleOnly: Bool = false,
        fresh: Bool = false,
        noColor: Bool = false,
        version: Bool = false,
        help: Bool = false,
        parseError: CLIParseError? = nil
    ) {
        self.command = command
        self.json = json
        self.includeSystem = includeSystem
        self.dryRun = dryRun
        self.top = top
        self.category = category
        self.leftoversOnly = leftoversOnly
        self.staleOnly = staleOnly
        self.fresh = fresh
        self.noColor = noColor
        self.version = version
        self.help = help
        self.parseError = parseError
    }
}

let cliCommands: Set<String> = ["report", "leftovers", "stale", "outdated", "packages", "update"]

public let cliHelpText = """
usage: appattic [--version] [--help] [command] [options]

Find leftover data from uninstalled apps, unused installed software, unused distro/language packages, and outdated packages.

commands:
  report      full report: leftovers + stale + outdated + packages (default)
  leftovers   only orphaned data and PATH overlays from uninstalled apps
  stale       unused installed software (review and remove)
  outdated    installed packages with a newer version available
  packages    distro orphans and language globals
  update      run Homebrew/Flatpak upgrades (prompts on a TTY; --dry-run prints the script)

options:
  --json FILE         also write full results as JSON to FILE
  --include-system    include OS system apps in the stale list
  --fresh             ignore the last-scan cache and scan now
  --dry-run           print a shell script for this command without running it
  --top N             show only the N largest leftovers
  --category CAT      filter leftovers by category (substring match)
  --leftovers-only    on report, skip stale, outdated, and packages
  --stale-only        on report, skip leftovers, outdated, and packages
  --no-color          disable ANSI color (also NO_COLOR or TERM=dumb)
  --version, -v       print version and exit
  --help, -h          print this help and exit

Progress and status go to stderr. Reports and --dry-run scripts go to stdout.

settings.json (includeSystem, confirmDelete, ignored leftover paths):
  Linux: $XDG_DATA_HOME/appattic/settings.json
  macOS: ~/Library/Application Support/AppAttic/settings.json
  Missing file uses defaults (includeSystem false, confirmDelete true).
  A malformed file is an error. --include-system turns includeSystem on for this run.
  It cannot turn includeSystem off when the file already has true.
"""

public let cliUsageHint = "Try 'appattic --help' for more information."

/// Color on a tty unless `--no-color`, a non-empty `NO_COLOR`, or `TERM=dumb`.
public func cliColorEnabled(
    stdoutIsTTY: Bool,
    env: [String: String],
    noColorFlag: Bool = false
) -> Bool {
    if noColorFlag { return false }
    if let noColor = env["NO_COLOR"], !noColor.isEmpty { return false }
    if env["TERM"] == "dumb" { return false }
    return stdoutIsTTY
}

public func parseCLIArguments(_ args: [String]) -> CLIOptions {
    var opts = CLIOptions()
    var i = 0
    var positional: [String] = []
    while i < args.count {
        let a = args[i]
        if a == "--version" || a == "-v" {
            opts.version = true
            i += 1
            continue
        }
        if a == "--help" || a == "-h" {
            opts.help = true
            i += 1
            continue
        }
        if a == "--include-system" {
            opts.includeSystem = true
            i += 1
            continue
        }
        if a == "--fresh" {
            opts.fresh = true
            i += 1
            continue
        }
        if a == "--no-color" {
            opts.noColor = true
            i += 1
            continue
        }
        if a == "--dry-run" {
            opts.dryRun = true
            i += 1
            continue
        }
        if a == "--leftovers-only" {
            opts.leftoversOnly = true
            i += 1
            continue
        }
        if a == "--stale-only" {
            opts.staleOnly = true
            i += 1
            continue
        }
        if a == "--json" {
            i += 1
            guard i < args.count, !args[i].hasPrefix("-") else {
                opts.parseError = .jsonRequiresPath
                return opts
            }
            opts.json = args[i]
            i += 1
            continue
        }
        if a.hasPrefix("--json=") {
            let value = String(a.dropFirst("--json=".count))
            if value.isEmpty || value.hasPrefix("-") {
                opts.parseError = .jsonRequiresPath
                return opts
            }
            opts.json = value
            i += 1
            continue
        }
        if a == "--top" {
            i += 1
            guard i < args.count, let n = Int(args[i]), n >= 0 else {
                opts.parseError = .topRequiresNonNegativeInteger
                return opts
            }
            opts.top = n
            i += 1
            continue
        }
        if a.hasPrefix("--top=") {
            guard let n = Int(a.dropFirst("--top=".count)), n >= 0 else {
                opts.parseError = .topRequiresNonNegativeInteger
                return opts
            }
            opts.top = n
            i += 1
            continue
        }
        if a == "--category" {
            i += 1
            var cats: [String] = []
            while i < args.count, !args[i].hasPrefix("-") {
                cats.append(args[i])
                i += 1
            }
            if cats.isEmpty {
                opts.parseError = .categoryRequiresValue
                return opts
            }
            opts.category.append(contentsOf: cats)
            continue
        }
        if a.hasPrefix("--category=") {
            let value = String(a.dropFirst("--category=".count))
            if value.isEmpty {
                opts.parseError = .categoryRequiresValue
                return opts
            }
            opts.category.append(value)
            i += 1
            continue
        }
        if a.hasPrefix("-") {
            opts.parseError = .unknownOption(a)
            return opts
        }
        positional.append(a)
        i += 1
    }
    if let first = positional.first {
        if cliCommands.contains(first) {
            opts.command = first
            if positional.count > 1 {
                opts.parseError = .unexpectedArgument(positional[1])
            }
        } else {
            opts.parseError = .unknownCommand(first)
        }
    }
    if opts.leftoversOnly && opts.staleOnly && opts.parseError == nil {
        opts.parseError = .conflictingFilters
    }
    return opts
}
