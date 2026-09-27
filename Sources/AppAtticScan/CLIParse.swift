import Foundation

public enum CLIParseError: Error, Equatable, LocalizedError, Sendable, CustomStringConvertible {
    case jsonRequiresPath
    case topRequiresNonNegativeInteger
    case categoryRequiresValue
    case unknownOption(String)
    case unknownCommand(String)
    case unexpectedArgument(String)
    case conflictingFilters
    case yesNeedsUpdateCommand

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
            if let guess = nearestCLICommand(command) {
                return "unknown command: \(command) (did you mean '\(guess)'?)"
            }
            return "unknown command: \(command); try one of: \(cliCommandList())"
        case .unexpectedArgument(let argument):
            return "unexpected argument: \(argument)"
        case .conflictingFilters:
            return "--leftovers-only and --stale-only cannot be combined"
        case .yesNeedsUpdateCommand:
            return "--yes only applies to the update command"
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
    public var diskPath: String?
    public var allFileSystems: Bool
    public var allocated: Bool
    public var yes: Bool
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
        diskPath: String? = nil,
        allFileSystems: Bool = false,
        allocated: Bool = false,
        yes: Bool = false,
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
        self.diskPath = diskPath
        self.allFileSystems = allFileSystems
        self.allocated = allocated
        self.yes = yes
        self.parseError = parseError
    }
}

let cliCommands: Set<String> = ["report", "leftovers", "stale", "outdated", "packages", "update", "disk"]

/// Options that stand alone: the flag name and the field it sets. `cliHelpText`
/// lists these; `parseCLIArguments` walks the table.
let cliBooleanFlags: [(name: String, key: WritableKeyPath<CLIOptions, Bool>)] = [
    ("--version", \.version), ("-v", \.version),
    ("--help", \.help), ("-h", \.help),
    ("--include-system", \.includeSystem),
    ("--fresh", \.fresh),
    ("--no-color", \.noColor),
    ("--all-file-systems", \.allFileSystems),
    ("--allocated", \.allocated),
    ("--dry-run", \.dryRun),
    ("--yes", \.yes), ("-y", \.yes),
    ("--leftovers-only", \.leftoversOnly),
    ("--stale-only", \.staleOnly),
]

func cliCommandList() -> String {
    cliCommands.sorted().joined(separator: ", ")
}

/// Closest command within `cliSuggestionDistance` edits, for a typo like `updat`.
func nearestCLICommand(_ typed: String) -> String? {
    let cliSuggestionDistance = 2
    let input = Array(typed.lowercased())
    var best: (command: String, distance: Int)?
    for command in cliCommands.sorted() {
        let distance = cliEditDistance(input, Array(command))
        if let best, distance >= best.distance { continue }
        best = (command, distance)
    }
    guard let best, best.distance <= cliSuggestionDistance else { return nil }
    return best.command
}

func cliEditDistance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

public let cliHelpText = """
usage: appattic [--version] [--help] [command] [options]

Find leftover data from uninstalled apps, unused installed software, unused distro/language packages, outdated packages, and disk usage.

commands:
  report        full report: leftovers + stale + outdated + packages (default)
  leftovers     only orphaned data and PATH overlays from uninstalled apps
  stale         unused installed software (review and remove)
  outdated      installed packages with a newer version available
  packages      distro orphans and language globals
  disk [PATH]   folder sizes (like Disk Usage Analyzer). Optional PATH, default home
  update        named package upgrades (prompts on a TTY; --dry-run prints the script). Not a full distro upgrade

options:
  --json FILE         also write full results as JSON to FILE
  --include-system    include OS system apps in the stale list
  --fresh             ignore the last-scan cache and scan now
  --dry-run           print a shell script for this command without running it
  --top N             leftovers: only the N largest. disk: N largest entries per folder
  --category CAT      filter leftovers by category (substring match, repeatable)
  --leftovers-only    on report, skip stale, outdated, and packages
  --stale-only        on report, skip leftovers, outdated, and packages
  --no-color          disable ANSI color (also NO_COLOR or TERM=dumb)
  --all-file-systems  on disk, descend into other mounted devices
  --allocated         on disk, print allocated blocks instead of apparent size
  --yes, -y           on update, skip the prompt (required without a TTY)
  --version, -v       print version and exit
  --help, -h          print this help and exit

Progress and status go to stderr. Reports and --dry-run scripts go to stdout.

exit codes:
  0  success
  1  the run failed, or an update was cancelled
  2  usage error (bad command, option, or value)

examples:
  appattic leftovers --top 10
  appattic report --json /tmp/appattic.json
  appattic disk /var --top 5 --allocated
  appattic leftovers --category caches --category browser
  appattic update --dry-run
  appattic update --yes

settings.json (includeSystem, confirmDelete, ignored leftover paths):
  Linux: $XDG_DATA_HOME/appattic/settings.json
  macOS: ~/Library/Application Support/AppAttic/settings.json
  Missing file uses defaults (includeSystem false, confirmDelete true).
  A malformed file is an error. --include-system turns includeSystem on for this run.
  It cannot turn includeSystem off when the file already has true.
"""

public let cliUsageHint = "Try 'appattic --help' for more information."

/// Status colors, the same values the two windows use for the same three
/// roles. `sources` is a truecolor SGR: 38;2;r;g;b.
public struct CliTone: Sendable, Equatable {
    public let sources: [String]

    public init(sources: [String]) { self.sources = sources }

    /// A terminal that cannot report its background, or reports a light one.
    /// Amber on a light pair is 4.8:1; on the dark pair it is 1.4:1, which is
    /// why the light pair is the fallback rather than the dark one.
    public static let light = CliTone(sources: ["38;2;192;28;40", "38;2;158;102;0", "38;2;36;138;61"])
    /// For a terminal known to have a dark background, where these reach
    /// 4.9:1, 11.8:1, and 8.3:1.
    public static let dark = CliTone(sources: ["38;2;255;69;58", "38;2;255;214;10", "38;2;48;209;88"])

    public func forRole(_ role: Role) -> String { sources[role.rawValue] }

    public enum Role: Int, Sendable {
        case remove
        case review
        case keep
    }
}

/// The dark or light tone for a terminal, read from `COLORFGBG`, which is
/// "fg;bg" and only that: a value with any other field count is malformed and
/// is not read. 0 to 6 are the base palette colors and 7 is white as an xterm
/// index, but as a 0-100 percentage 7 is a near-black background, so 7 is the
/// one value left to the safe fallback. 8 and up is a percentage, split at 50.
/// Absent, unparsed, and ambiguous also fall back, which costs contrast on a
/// dark terminal but never on a light one.
public func cliTone(env: [String: String]) -> CliTone {
    guard let raw = env["COLORFGBG"] else { return .light }
    let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
    guard fields.count == 2,
        let bg = Int(fields[1].trimmingCharacters(in: .whitespaces))
    else { return .light }
    if bg <= 6 { return .dark }
    if bg < 8 { return .light }
    return bg < 50 ? .dark : .light
}

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
        if let flag = cliBooleanFlags.first(where: { $0.name == a }) {
            opts[keyPath: flag.key] = true
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
            guard i < args.count, !args[i].hasPrefix("-") else {
                opts.parseError = .categoryRequiresValue
                return opts
            }
            opts.category.append(args[i])
            i += 1
            continue
        }
        if a.hasPrefix("--category=") {
            let value = String(a.dropFirst("--category=".count))
            if value.isEmpty || value.hasPrefix("-") {
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
            if first == "disk" {
                if positional.count >= 2 { opts.diskPath = positional[1] }
                if positional.count > 2 {
                    opts.parseError = .unexpectedArgument(positional[2])
                }
            } else if positional.count > 1 {
                opts.parseError = .unexpectedArgument(positional[1])
            }
        } else {
            opts.parseError = .unknownCommand(first)
        }
    }
    if opts.leftoversOnly && opts.staleOnly && opts.parseError == nil {
        opts.parseError = .conflictingFilters
    }
    if opts.yes && opts.command != "update" && opts.parseError == nil {
        opts.parseError = .yesNeedsUpdateCommand
    }
    return opts
}
