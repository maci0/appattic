import Foundation

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
    public var version: Bool
    public var help: Bool
    public var error: String?

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
        version: Bool = false,
        help: Bool = false,
        error: String? = nil
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
        self.version = version
        self.help = help
        self.error = error
    }
}

let cliCommands: Set<String> = ["report", "leftovers", "stale", "outdated", "packages", "update"]

public let cliHelpText = """
usage: appattic [--version] [--help] [command] [options]

Find leftover data from uninstalled apps, unused installed software, and outdated packages.

commands:
  report      full report: leftovers + stale + outdated (default)
  leftovers   only orphaned data from uninstalled apps
  stale       unused installed software (review and remove)
  outdated    installed packages with a newer version available
  packages    distro orphans and language globals
  update      upgrade outdated Homebrew formulas/casks and Flatpak apps

options:
  --json FILE         also write full results as JSON to FILE
  --include-system    include OS system apps in the stale list
  --fresh             ignore the last-scan cache and scan now
  --dry-run           print a shell script for this command without running it
  --top N             show only the N largest leftovers
  --category CAT      filter leftovers by category (substring match)
  --leftovers-only    on report, skip stale and outdated
  --stale-only        on report, skip leftovers and outdated
  --version           print version and exit
"""

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
            guard i < args.count else {
                opts.error = "--json requires a file path"
                return opts
            }
            opts.json = args[i]
            i += 1
            continue
        }
        if a.hasPrefix("--json=") {
            let value = String(a.dropFirst("--json=".count))
            if value.isEmpty {
                opts.error = "--json requires a file path"
                return opts
            }
            opts.json = value
            i += 1
            continue
        }
        if a == "--top" {
            i += 1
            guard i < args.count, let n = Int(args[i]), n >= 0 else {
                opts.error = "--top requires a non-negative integer"
                return opts
            }
            opts.top = n
            i += 1
            continue
        }
        if a.hasPrefix("--top=") {
            guard let n = Int(a.dropFirst("--top=".count)), n >= 0 else {
                opts.error = "--top requires a non-negative integer"
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
                opts.error = "--category requires a value"
                return opts
            }
            opts.category.append(contentsOf: cats)
            continue
        }
        if a.hasPrefix("--category=") {
            let value = String(a.dropFirst("--category=".count))
            if value.isEmpty {
                opts.error = "--category requires a value"
                return opts
            }
            opts.category.append(value)
            i += 1
            continue
        }
        if a.hasPrefix("--") {
            opts.error = "unknown option: \(a)"
            return opts
        }
        positional.append(a)
        i += 1
    }
    if let first = positional.first {
        if cliCommands.contains(first) {
            opts.command = first
            if positional.count > 1 {
                opts.error = "unexpected argument: \(positional[1])"
            }
        } else {
            opts.error = "unknown command: \(first)"
        }
    }
    if opts.leftoversOnly && opts.staleOnly && opts.error == nil {
        opts.error = "--leftovers-only and --stale-only cannot be combined"
    }
    return opts
}
