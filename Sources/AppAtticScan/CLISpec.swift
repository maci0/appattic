import Foundation

/// Whether stdout should carry the JSON document. `auto` follows the terminal.
/// An explicit `text` or `json` wins, including `text` when stdout is a pipe.
public func cliOutputIsJSON(flag: String, stdoutIsTTY: Bool) -> Bool {
    switch flag {
    case "json": return true
    case "text": return false
    default: return !stdoutIsTTY
    }
}

/// One compact error envelope. The caller prints it last on stderr.
public func cliErrorEnvelope(kind: String, message: String, hint: String?) -> String {
    var err: [String: Any] = ["kind": kind, "message": message]
    if let hint { err["hint"] = hint }
    let data = try? JSONSerialization.data(withJSONObject: ["error": err], options: [.sortedKeys])
    let line = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":{\"kind\":\"\(kind)\",\"message\":\"failed\"}}"
    return line.hasSuffix("\n") ? line : line + "\n"
}

public enum CLISpecError: Error, Equatable, CustomStringConvertible {
    case noMatch(String)

    public var description: String {
        switch self {
        case .noMatch(let path):
            return "schema: no command matches '\(path)'"
        }
    }
}

/// The clispec v0.3 document. Building it reads no settings, no credentials, and no network.
public func cliSpecJSON(path: [String] = [], pretty: Bool = false) throws -> Data {
    var doc = cliSpecDocument()
    if !path.isEmpty {
        let wanted = path.joined(separator: " ")
        let commands = (doc["commands"] as? [[String: Any]] ?? []).filter { command in
            let name = command["name"] as? String ?? ""
            return name == wanted || name.hasPrefix(wanted + " ")
        }
        if commands.isEmpty { throw CLISpecError.noMatch(wanted) }
        doc["commands"] = commands
    }
    var options: JSONSerialization.WritingOptions = [.sortedKeys]
    if pretty { options.insert(.prettyPrinted) }
    return try JSONSerialization.data(withJSONObject: doc, options: options)
}

private func cliSpecDocument() -> [String: Any] {
    let scan = "May refresh the local scan snapshot. It does not change installed software."
    return [
        "clispec": "0.3",
        "name": "appattic",
        "version": appAtticVersion,
        "description": "Leftovers, stale apps, unused packages, outdated versions, and disk usage.",
        "output": ["tty": "text", "piped": "json"],
        "global_args": [
            cliArg(
                "--output", "string", "auto, text, or json. auto is text on a terminal and JSON otherwise.",
                short: "-o", enumValues: ["auto", "text", "json"], defaultValue: "auto"
            ),
            cliArg("--json", "string", "Also write the same JSON document to this .json file."),
            cliArg("--no-color", "boolean", "Disable ANSI color."),
            cliArg("--help", "boolean", "Print help and exit.", short: "-h"),
            cliArg("--version", "boolean", "Print the version and exit.", short: "-v"),
        ],
        "errors": [
            cliError("usage", 2, false, "The command line was rejected. Nothing was attempted."),
            cliError(
                "confirmation_required", 2, false,
                "update needs a terminal. Pass --yes to run it unattended."
            ),
            cliError("parse", 2, false, "settings.json could not be read as settings."),
            cliError("failure", 1, false, "The command failed after it started."),
        ],
        "commands": [
            cliOpaque(
                "schema",
                "Print this clispec v0.3 document. Extra words keep one command.",
                args: [cliArg("path", "string[]", "Command path to keep. Empty prints every command.")]
            ),
            cliData(
                "config",
                "Print the settings and paths this machine resolves. Nothing is scanned.",
                effects: "read_only",
                cardinality: "single",
                fields: [
                    cliField("settingsPath", "string", "Path of settings.json."),
                    cliField("settingsFileExists", "boolean", "Whether that file is present."),
                    cliField("settingsBackupPath", "string", "Path of settings.json.bak."),
                    cliField("settingsBackupExists", "boolean", "Whether the backup is present."),
                    cliField("settingsRejectedPath", "string", "Path of settings.json.bad."),
                    cliField("settingsRejectedExists", "boolean", "Whether a replaced settings file is present."),
                    cliField("includeSystemFile", "boolean", "includeSystem as stored in the file."),
                    cliField("includeSystemFlag", "boolean", "Whether --include-system was passed."),
                    cliField("includeSystem", "boolean", "Whether this run includes OS apps."),
                    cliField("confirmDelete", "boolean", "Whether a delete asks first."),
                    cliField("ignoredLeftoverPaths", "array", "Leftover paths left out of the report.", items: ["type": "string"]),
                    cliField("scanCachePath", "string", "Path of the scan snapshot."),
                    cliField("dataHome", "string", "Resolved XDG_DATA_HOME."),
                    cliField("configHome", "string", "Resolved XDG_CONFIG_HOME."),
                    cliField("cacheHome", "string", "Resolved XDG_CACHE_HOME."),
                    cliField("stateHome", "string", "Resolved XDG_STATE_HOME."),
                    cliField("dataDirs", "string", "Resolved XDG_DATA_DIRS."),
                    cliField("runtimeHome", "string", "Resolved XDG_RUNTIME_DIR."),
                    cliField(
                        "environment", "array", "Switches this run reads.",
                        items: [
                            "type": "object",
                            "fields": [
                                cliField("name", "string", "Variable name."),
                                cliField("value", "string", "Raw value, empty when unset."),
                                cliField("isSet", "boolean", "Whether the variable is set."),
                                cliField("effect", "string", "What that value does."),
                            ],
                        ]
                    ),
                ]
            ),
            cliData("report", "Full report: leftovers, stale apps, outdated packages, and unused packages. \(scan)", effects: "read_only", cardinality: "single", schema: [:]),
            cliData("leftovers", "Orphaned data and PATH overlays from uninstalled apps. \(scan)", effects: "read_only", cardinality: "single", schema: [:]),
            cliData("stale", "Unused installed software. \(scan)", effects: "read_only", cardinality: "single", schema: [:]),
            cliData("outdated", "Installed packages with a newer version available. \(scan)", effects: "read_only", cardinality: "single", schema: [:]),
            cliData("packages", "Distro orphans and language globals. \(scan)", effects: "read_only", cardinality: "single", schema: [:]),
            cliData(
                "disk",
                "Folder sizes under PATH, or the home directory when PATH is omitted.",
                effects: "read_only",
                cardinality: "single",
                schema: [:],
                args: [cliArg("path", "string", "Directory to walk. Omit it for the home directory.")]
            ),
            cliData(
                "erase",
                "Delete the stored scan snapshot. A second run finds nothing left and changes nothing.",
                effects: "idempotent",
                cardinality: "single",
                fields: [
                    cliField("path", "string", "Snapshot path."),
                    cliField("erased", "boolean", "True when a snapshot was removed."),
                    cliField("changed", "boolean", "True when this run deleted a file."),
                ]
            ),
            cliData(
                "restore",
                "Put settings.json.bak back in place of settings.json. A retry writes the file again and is not safe to treat as a no-op.",
                effects: "non_idempotent",
                cardinality: "single",
                fields: [
                    cliField("path", "string", "Settings file that was written."),
                    cliField("restoredFrom", "string", "Backup the bytes came from."),
                    cliField("replacedPath", "string", "Where the replaced file was kept, or empty."),
                    cliField("settings", "object", "The settings that were restored."),
                ]
            ),
            cliData(
                "update",
                "Upgrade the named packages the scan found. A retry runs the upgrades again and is not safe. Without a terminal the command refuses unless --yes is set.",
                effects: "non_idempotent",
                cardinality: "single",
                schema: [:],
                args: [
                    cliArg("--yes", "boolean", "Skip the confirmation prompt.", short: "-y"),
                    cliArg("--dry-run", "boolean", "Print the upgrade script and do not run it."),
                ],
                extra: [
                    "confirmation_bypass_arg": "--yes",
                    "errors": ["confirmation_required", "usage", "failure"],
                ]
            ),
        ],
    ]
}

private func cliArg(
    _ name: String,
    _ type: String,
    _ description: String,
    short: String? = nil,
    enumValues: [String]? = nil,
    defaultValue: String? = nil
) -> [String: Any] {
    var arg: [String: Any] = ["name": name, "type": type, "description": description]
    if let short { arg["short"] = short }
    if let enumValues { arg["enum"] = enumValues }
    if let defaultValue { arg["default"] = defaultValue }
    return arg
}

private func cliField(
    _ name: String,
    _ type: String,
    _ description: String,
    items: [String: Any]? = nil
) -> [String: Any] {
    var field: [String: Any] = ["name": name, "type": type, "description": description]
    if let items { field["items"] = items }
    return field
}

private func cliError(_ kind: String, _ code: Int, _ retryable: Bool, _ description: String) -> [String: Any] {
    ["kind": kind, "exit_code": code, "retryable": retryable, "description": description]
}

private func cliOpaque(_ name: String, _ description: String, args: [[String: Any]]) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "effects": "read_only",
        "output_kind": "opaque",
        "media_type": "application/json",
        "args": args,
        "errors": ["usage"],
    ]
}

private func cliData(
    _ name: String,
    _ description: String,
    effects: String,
    cardinality: String,
    fields: [[String: Any]]? = nil,
    schema: [String: Any]? = nil,
    args: [[String: Any]] = [],
    extra: [String: Any] = [:]
) -> [String: Any] {
    var command: [String: Any] = [
        "name": name,
        "description": description,
        "effects": effects,
        "cardinality": cardinality,
    ]
    if let fields { command["output_fields"] = fields }
    if let schema { command["stdout_schema"] = schema }
    if !args.isEmpty { command["args"] = args }
    for (key, value) in extra { command[key] = value }
    return command
}
