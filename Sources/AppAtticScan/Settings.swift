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
}

public struct CleanupSelection: Equatable, Sendable {
    public var leftovers: Set<String>
    public var apps: Set<String>
    public var outdated: Set<String>
    public var packages: Set<String>
    public var markManual: Set<String>

    public init(
        leftovers: Set<String> = [],
        apps: Set<String> = [],
        outdated: Set<String> = [],
        packages: Set<String> = [],
        markManual: Set<String> = []
    ) {
        self.leftovers = leftovers
        self.apps = apps
        self.outdated = outdated
        self.packages = packages
        self.markManual = markManual
    }
}

public func defaultSettingsURL() -> URL {
    defaultScanCacheURL().deletingLastPathComponent().appendingPathComponent("settings.json")
}

public func loadSettings(from url: URL = defaultSettingsURL()) -> AppAtticSettings {
    guard let raw = try? Data(contentsOf: url) else { return .default }
    return (try? JSONDecoder().decode(AppAtticSettings.self, from: raw)) ?? .default
}

public func saveSettings(_ settings: AppAtticSettings, to url: URL = defaultSettingsURL()) {
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let raw = try? encoder.encode(settings) else { return }
    try? raw.write(to: url, options: .atomic)
}

public func addIgnoredLeftover(_ path: String, to settings: AppAtticSettings) -> AppAtticSettings {
    addIgnoredLeftovers([path], to: settings)
}

public func addIgnoredLeftovers(_ paths: [String], to settings: AppAtticSettings) -> AppAtticSettings {
    var next = settings
    for path in paths where !path.isEmpty && !next.ignoredLeftoverPaths.contains(path) {
        next.ignoredLeftoverPaths.append(path)
    }
    return next
}

public func clearIgnoredLeftovers(_ settings: AppAtticSettings) -> AppAtticSettings {
    var next = settings
    next.ignoredLeftoverPaths = []
    return next
}

public func leftoverIgnorePaths(_ item: LeftoverItem) -> [String] {
    [item.path] + (item.extra_paths ?? [])
}

public func isListedLeftoverStatus(_ status: String) -> Bool {
    status == "orphaned" || status == "shadow"
}

public func visibleOrphanedLeftovers(_ leftovers: [LeftoverItem], ignoring: Set<String>) -> [LeftoverItem] {
    leftovers.filter { item in
        isListedLeftoverStatus(item.status) && leftoverIgnorePaths(item).allSatisfy { !ignoring.contains($0) }
    }
}

public let selectableCleanupTiers: Set<String> = ["remove", "review"]

public func pruneCleanupSelection(
    leftovers: Set<String>,
    apps: Set<String>,
    outdated: Set<String>,
    packages: Set<String> = [],
    markManual: Set<String> = [],
    data: ScanData,
    ignoring: Set<String>
) -> CleanupSelection {
    let leftoverPaths = Set(visibleOrphanedLeftovers(data.leftovers, ignoring: ignoring).map(\.path))
    let appPaths = Set(
        data.software.filter { selectableCleanupTiers.contains($0.tier ?? "") }.map(\.path)
    )
    let outdatedIds = Set((data.outdated ?? []).filter(\.updatable).map(\.id))
    let listed = data.packages ?? []
    let packageIds = Set(listed.map(\.id))
    let markIds = Set(listed.filter(\.canMarkManual).map(\.id))
    return CleanupSelection(
        leftovers: leftovers.intersection(leftoverPaths),
        apps: apps.intersection(appPaths),
        outdated: outdated.intersection(outdatedIds),
        packages: packages.intersection(packageIds),
        markManual: markManual.intersection(markIds)
    )
}

public func resolvedSelection(_ selected: String?, visibleIds: [String]) -> String? {
    if let selected, visibleIds.contains(selected) { return selected }
    return visibleIds.first
}

public func toggleListedSelection(selected: Set<String>, visible: [String]) -> Set<String> {
    let vis = Set(visible)
    if vis.isEmpty { return selected }
    if vis.isSubset(of: selected) { return [] }
    return selected.union(vis)
}
