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

    public var description: String {
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
        return "Could not read settings at \(path) (\(reason)). AppAttic will not overwrite that file until you save settings."
    case .invalid(let path, let reason):
        return "Settings at \(path) are not valid (\(reason)). AppAttic will not overwrite that file until you save settings."
    case .unwritable(let path, let reason):
        return "Could not save settings to \(path) (\(reason))."
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

/// Load settings.json. A missing file is defaults. Empty JSON, unknown keys, or wrong types are errors.
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
    do {
        return try JSONDecoder().decode(AppAtticSettings.self, from: raw).normalized()
    } catch {
        throw SettingsError.invalid(
            path: path,
            reason: "wrong type (includeSystem and confirmDelete must be true or false; ignoredLeftoverPaths must be an array of strings)"
        )
    }
}

/// Decode settings.json with JSONDecoder only. Missing files throw; unknown keys are not rejected.
public func readSettings(from url: URL = defaultSettingsURL()) throws -> AppAtticSettings {
    let raw: Data
    do {
        raw = try Data(contentsOf: url)
    } catch {
        throw AppAtticIOError.readFailed(path: url.path, message: error.localizedDescription)
    }
    do {
        return try JSONDecoder().decode(AppAtticSettings.self, from: raw)
    } catch {
        throw AppAtticIOError.decodeFailed(path: url.path, message: error.localizedDescription)
    }
}

/// Write settings.json (pretty, sorted keys, normalized ignore list). Used by the UI.
public func saveSettings(_ settings: AppAtticSettings, to url: URL = defaultSettingsURL()) throws {
    let dir = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if dir.lastPathComponent.lowercased() == "appattic" {
            try restrictOwnerOnlyDirectory(at: dir)
        }
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
        try raw.write(to: url, options: .atomic)
        try restrictPrivateDataFile(at: url)
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
}

/// Write settings.json (sorted keys, no pretty-print, no normalize). Throws `AppAtticIOError`.
public func writeSettings(_ settings: AppAtticSettings, to url: URL = defaultSettingsURL()) throws {
    let dir = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if dir.lastPathComponent.lowercased() == "appattic" {
            try restrictOwnerOnlyDirectory(at: dir)
        }
    } catch {
        throw AppAtticIOError.createDirectoryFailed(path: dir.path, message: error.localizedDescription)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let raw: Data
    do {
        raw = try encoder.encode(settings)
    } catch {
        throw AppAtticIOError.encodeFailed(message: error.localizedDescription)
    }
    do {
        try raw.write(to: url, options: .atomic)
        try restrictPrivateDataFile(at: url)
    } catch {
        throw AppAtticIOError.writeFailed(path: url.path, message: error.localizedDescription)
    }
}

public func addIgnoredLeftover(_ path: String, to settings: AppAtticSettings) -> AppAtticSettings {
    addIgnoredLeftovers([path], to: settings)
}

public func addIgnoredLeftovers(_ paths: [String], to settings: AppAtticSettings) -> AppAtticSettings {
    var next = settings
    for path in paths {
        let key = pathIdentityKey(path)
        if key.isEmpty { continue }
        if next.ignoredLeftoverPaths.contains(where: { pathIdentityKey($0) == key }) { continue }
        next.ignoredLeftoverPaths.append(key)
    }
    return next
}

public func clearIgnoredLeftovers(_ settings: AppAtticSettings) -> AppAtticSettings {
    var next = settings
    next.ignoredLeftoverPaths = []
    return next
}
