import Foundation

public struct AppAtticSettings: Codable, Equatable, Sendable {
    public var includeSystem: Bool
    public var confirmDelete: Bool
    public var ignoredLeftoverPaths: [String]

    public static let `default` = AppAtticSettings()

    public init(
        includeSystem: Bool = false,
        confirmDelete: Bool = true,
        ignoredLeftoverPaths: [String] = []
    ) {
        self.includeSystem = includeSystem
        self.confirmDelete = confirmDelete
        self.ignoredLeftoverPaths = ignoredLeftoverPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeSystem = try c.decodeIfPresent(Bool.self, forKey: .includeSystem) ?? false
        confirmDelete = try c.decodeIfPresent(Bool.self, forKey: .confirmDelete) ?? true
        ignoredLeftoverPaths = try c.decodeIfPresent([String].self, forKey: .ignoredLeftoverPaths) ?? []
    }

    public func normalized() -> AppAtticSettings {
        var seen = Set<String>()
        var paths: [String] = []
        for path in ignoredLeftoverPaths {
            let key = pathIdentityKey(path)
            if key.isEmpty || !seen.insert(key).inserted { continue }
            paths.append(key)
        }
        if paths == ignoredLeftoverPaths { return self }
        var copy = self
        copy.ignoredLeftoverPaths = paths
        return copy
    }
}

public enum SettingsError: Error, Equatable, LocalizedError, CustomStringConvertible, Sendable {
    case unreadable(path: String, reason: String)
    case invalid(path: String, reason: String)
    case unwritable(path: String, reason: String)

    /// The settings path sits under the account home, so the composed line is
    /// redacted whole: `~/...` still names the file, the account name does not
    /// reach the terminal or a pasted bug report.
    public var description: String {
        redactHomePaths(rawDescription)
    }

    private var rawDescription: String {
        switch self {
        case .unreadable(let path, let reason):
            return "cannot read settings \(path): \(reason)"
        case .invalid(let path, let reason):
            return "invalid settings \(path): \(reason)"
        case .unwritable(let path, let reason):
            return "cannot write settings \(path): \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// Wording for the UI. CLI keeps `SettingsError.description`.
public func settingsErrorUserMessage(_ error: Error) -> String {
    guard let error = error as? SettingsError else {
        return error.localizedDescription
    }
    switch error {
    case .unreadable(let path, let reason):
        return redactHomePaths("Could not read settings at \(path) (\(reason)). AppAttic will not overwrite that file until you save settings.")
    case .invalid(let path, let reason):
        return redactHomePaths("Settings at \(path) are not valid (\(reason)). AppAttic will not overwrite that file until you save settings.")
    case .unwritable(let path, let reason):
        return redactHomePaths("Could not save settings to \(path) (\(reason)).")
    }
}

private let settingsJSONKeys: Set<String> = ["includeSystem", "confirmDelete", "ignoredLeftoverPaths"]

public func defaultSettingsURL() -> URL {
    defaultScanCacheURL().deletingLastPathComponent().appendingPathComponent("settings.json")
}

/// CLI `--include-system` ORs with the file. A true file value cannot be turned off from the CLI.
public func effectiveIncludeSystem(cliFlag: Bool, settings: AppAtticSettings) -> Bool {
    cliFlag || settings.includeSystem
}

/// The configuration one run actually uses, with every layer named: the
/// settings file, the file values, the flag that overrides them, and the
/// environment roots the paths resolved to. `appattic config` prints it so two
/// machines can be diffed, which is the only way to tell a wrong value from a
/// wrong path. Encodable only: nothing reads configuration back out of a report.
public struct EffectiveConfig: Encodable, Equatable, Sendable {
    public let settingsPath: String
    public let settingsFileExists: Bool
    public let includeSystemFile: Bool
    public let includeSystemFlag: Bool
    public let confirmDelete: Bool
    public let ignoredLeftoverPaths: [String]
    public let scanCachePath: String
    public let dataHome: String
    public let configHome: String
    public let cacheHome: String
    public let stateHome: String
    public let dataDirs: String

    /// The merged value the scan and the report use.
    public var includeSystem: Bool { includeSystemFlag || includeSystemFile }

    private enum CodingKeys: String, CodingKey {
        case settingsPath, settingsFileExists
        case includeSystem, includeSystemFile, includeSystemFlag
        case confirmDelete, ignoredLeftoverPaths, scanCachePath
        case dataHome, configHome, cacheHome, stateHome, dataDirs
    }

    public func encode(to encoder: Encoder) throws {
        let c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(settingsPath, forKey: .settingsPath)
        try c.encode(settingsFileExists, forKey: .settingsFileExists)
        try c.encode(includeSystem, forKey: .includeSystem)
        try c.encode(includeSystemFile, forKey: .includeSystemFile)
        try c.encode(includeSystemFlag, forKey: .includeSystemFlag)
        try c.encode(confirmDelete, forKey: .confirmDelete)
        try c.encode(ignoredLeftoverPaths, forKey: .ignoredLeftoverPaths)
        try c.encode(scanCachePath, forKey: .scanCachePath)
        try c.encode(dataHome, forKey: .dataHome)
        try c.encode(configHome, forKey: .configHome)
        try c.encode(cacheHome, forKey: .cacheHome)
        try c.encode(stateHome, forKey: .stateHome)
        try c.encode(dataDirs, forKey: .dataDirs)
    }

    public init(
        settings: AppAtticSettings,
        settingsURL: URL = defaultSettingsURL(),
        includeSystemFlag: Bool = false,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.settingsPath = settingsURL.path
        self.settingsFileExists = FileManager.default.fileExists(atPath: settingsURL.path)
        self.includeSystemFile = settings.includeSystem
        self.includeSystemFlag = includeSystemFlag
        self.confirmDelete = settings.confirmDelete
        self.ignoredLeftoverPaths = settings.ignoredLeftoverPaths
        self.scanCachePath = defaultScanCacheURL().path
        self.dataHome = xdgDataHome(env: env)
        self.configHome = xdgConfigHome(env: env)
        self.cacheHome = xdgCacheHome(env: env)
        self.stateHome = xdgStateHome(env: env)
        self.dataDirs = xdgSystemDirs(env: env)
    }

    /// One `key: value` line per setting, in the order a reader meets them,
    /// with the ignored paths on their own lines under their count.
    /// `includeSystem` shows where the value came from, since the file and the
    /// flag combine with OR and the flag is the only one that can turn it on.
    public var lines: [String] {
        // Only a file that turned the setting on is the layer in force: a file
        // that omits the key and one that writes `false` leave the same value,
        // and naming the file for a value it did not supply sends the reader
        // looking for a `true` that is not there.
        let source = includeSystemFlag ? "on (--include-system)" : (includeSystemFile ? "file" : "default")
        var lines = [
            "settings file: \(settingsPath)\(settingsFileExists ? "" : " (missing, using defaults)")",
            "includeSystem: \(includeSystem) [\(source)]",
            "confirmDelete: \(confirmDelete)",
            "ignoredLeftoverPaths: \(ignoredLeftoverPaths.count)",
        ]
        // The count cannot be wrong in a way a reader can see. The entries are
        // what a user compares against the paths a report prints, so they are
        // printed in full, the way the paths on either side of them are.
        lines.append(contentsOf: ignoredLeftoverPaths.map { "  \($0)" })
        lines.append(contentsOf: [
            "scan cache: \(scanCachePath)",
            "XDG_DATA_HOME: \(dataHome)",
            "XDG_CONFIG_HOME: \(configHome)",
            "XDG_CACHE_HOME: \(cacheHome)",
            "XDG_STATE_HOME: \(stateHome)",
            "XDG_DATA_DIRS: \(dataDirs)",
        ])
        return lines
    }
}

/// Load settings.json. A missing file is defaults. Empty JSON, unknown keys, wrong
/// types, and an ignored path that is not absolute are errors.
public func loadSettings(from url: URL = defaultSettingsURL()) throws -> AppAtticSettings {
    let path = url.path
    if !FileManager.default.fileExists(atPath: path) {
        return .default
    }
    let raw: Data
    do {
        raw = try Data(contentsOf: url)
    } catch {
        throw SettingsError.unreadable(path: path, reason: error.localizedDescription)
    }
    if raw.isEmpty {
        throw SettingsError.invalid(path: path, reason: "file is empty")
    }
    let obj: Any
    do {
        obj = try JSONSerialization.jsonObject(with: raw)
    } catch {
        throw SettingsError.invalid(path: path, reason: "not valid JSON")
    }
    guard let dict = obj as? [String: Any] else {
        throw SettingsError.invalid(path: path, reason: "root must be a JSON object")
    }
    let unknown = Set(dict.keys).subtracting(settingsJSONKeys)
    if !unknown.isEmpty {
        throw SettingsError.invalid(
            path: path,
            reason: "unknown key(s): \(unknown.sorted().joined(separator: ", "))"
        )
    }
    let decoded: AppAtticSettings
    do {
        decoded = try JSONDecoder().decode(AppAtticSettings.self, from: raw)
    } catch {
        throw SettingsError.invalid(
            path: path,
            reason: "wrong type (includeSystem and confirmDelete must be true or false; ignoredLeftoverPaths must be an array of strings)"
        )
    }
    let settings = decoded.normalized()
    // An ignore entry is matched against the leftover path a scan reports, so
    // a relative one, a `~` one, or one with a trailing slash never matches and
    // the leftover the user hid stays in every report. Silent: nothing else in
    // the file says the entry is wrong. Refuse it here, where the file is
    // already strict about everything else.
    if let bad = settings.ignoredLeftoverPaths.first(where: { !$0.hasPrefix("/") }) {
        throw SettingsError.invalid(
            path: path,
            reason: "ignoredLeftoverPaths entry \"\(bad)\" is not an absolute path; "
                + "use the full path, the one the report prints"
        )
    }
    return settings
}

/// Write settings.json (pretty, sorted keys, normalized ignore list). Used by the UI.
public func saveSettings(_ settings: AppAtticSettings, to url: URL = defaultSettingsURL()) throws {
    let dir = url.deletingLastPathComponent()
    do {
        try prepareStateDirectory(dir)
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let raw: Data
    do {
        raw = try encoder.encode(settings.normalized())
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
    do {
        // cordis-boundary: emission. settings.json is the app's own state file
        // and its sole writer; the atomic overwrite is the commit. No inverse is
        // held because the file is the state, not a cached copy of it.
        try raw.write(to: url, options: .atomic)
        try restrictPrivateDataFile(at: url)
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
}
