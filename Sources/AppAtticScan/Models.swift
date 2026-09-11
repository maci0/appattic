import Foundation

/// Leftover classification stored as a string on JSON models so unknown values stay round-trippable.
public enum LeftoverStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case orphaned
    case shadow
    case owned
    case system
    case active
}

/// Stale-software recommendation stored as a string on JSON models so unknown values stay round-trippable.
public enum SoftwareTier: String, Codable, Sendable, Hashable, CaseIterable {
    case keep
    case review
    case remove
    case system
}

/// Distro orphan vs user-global language tool.
public enum PackageKind: String, Codable, Sendable, Hashable, CaseIterable {
    case orphan
    case global
}

public struct ScanTotals: Codable, Sendable {
    public let apps_installed: Int
    public let orphaned_items: Int
    public let orphaned_bytes: Int
    public let system_leftover_bytes: Int
    public let reclaimable_bytes: Int
    public let stale_apps: Int
    public let outdated_apps: Int?

    public init(
        apps_installed: Int,
        orphaned_items: Int,
        orphaned_bytes: Int,
        system_leftover_bytes: Int,
        reclaimable_bytes: Int,
        stale_apps: Int,
        outdated_apps: Int?
    ) {
        self.apps_installed = apps_installed
        self.orphaned_items = orphaned_items
        self.orphaned_bytes = orphaned_bytes
        self.system_leftover_bytes = system_leftover_bytes
        self.reclaimable_bytes = reclaimable_bytes
        self.stale_apps = stale_apps
        self.outdated_apps = outdated_apps
    }
}

public struct LeftoverItem: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let root: String
    public let kind: String
    public let status: String
    public let owner: String?
    public let size_bytes: Int?
    public let size_measured: Bool
    public let mtime: String?
    public let reason: String?
    public let summary: String?
    public let extra_paths: [String]?
    public let shadows: String?
    public var id: String { path }
    public var leftoverStatus: LeftoverStatus? { LeftoverStatus(rawValue: status) }

    public init(
        name: String,
        path: String,
        root: String,
        kind: String,
        status: String,
        owner: String? = nil,
        size_bytes: Int? = nil,
        size_measured: Bool = true,
        mtime: String? = nil,
        reason: String? = nil,
        summary: String? = nil,
        extra_paths: [String]? = nil,
        shadows: String? = nil
    ) {
        self.name = name
        self.path = path
        self.root = root
        self.kind = kind
        self.status = status
        self.owner = owner
        self.size_bytes = size_bytes
        self.size_measured = size_measured
        self.mtime = mtime
        self.reason = reason
        self.summary = summary
        self.extra_paths = extra_paths
        self.shadows = shadows
    }
}

/// Paths that hide this leftover when present in the ignore list: the item path plus extra_paths.
public func leftoverIgnorePaths(_ item: LeftoverItem) -> [String] {
    [item.path] + (item.extra_paths ?? [])
}

/// Leftovers shown in the list: orphaned data and PATH/desktop overlays (`shadow`). Owned, system, and active stay hidden.
public func isListedLeftoverStatus(_ status: LeftoverStatus) -> Bool {
    status == .orphaned || status == .shadow
}

public func isListedLeftoverStatus(_ status: String) -> Bool {
    guard let parsed = LeftoverStatus(rawValue: status) else { return false }
    return isListedLeftoverStatus(parsed)
}

/// Orphaned leftover dirs and shadow overlays, minus ignored paths (item path and extra_paths).
public func visibleOrphanedLeftovers(_ leftovers: [LeftoverItem], ignoring: Set<String>) -> [LeftoverItem] {
    let ignoredKeys = Set(ignoring.map(pathIdentityKey))
    return leftovers.filter { item in
        isListedLeftoverStatus(item.status)
            && leftoverIgnorePaths(item).allSatisfy { !ignoredKeys.contains(pathIdentityKey($0)) }
    }
}

public struct SoftwareItem: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let kind: String
    public let path: String
    public let source: String
    public let version: String?
    public let size_bytes: Int?
    public let size_measured: Bool?
    public let data_bytes: Int?
    public let data_paths: [String]?
    public let last_used: String?
    public let installed_at: String?
    public let usage_source: String?
    public let running_service: Bool?
    public let tier: String?
    public let reason: String?
    public let cask_name: String?
    public let is_leaf: Bool?
    public let outdated: Bool?
    public let current_version: String?
    public let latest_version: String?
    public let summary: String?
    public let steam_appid: String?
    public let pkg_id: String?
    public let bundle_id: String?
    public var id: String { path }
    public var totalBytes: Int { addBytes(size_bytes ?? 0, data_bytes ?? 0) }
    public var softwareTier: SoftwareTier? { tier.flatMap { SoftwareTier(rawValue: $0) } }

    public init(
        name: String,
        kind: String,
        path: String,
        source: String,
        version: String? = nil,
        size_bytes: Int? = nil,
        size_measured: Bool? = nil,
        data_bytes: Int? = nil,
        data_paths: [String]? = nil,
        last_used: String? = nil,
        installed_at: String? = nil,
        usage_source: String? = nil,
        running_service: Bool? = nil,
        tier: String? = nil,
        reason: String? = nil,
        cask_name: String? = nil,
        is_leaf: Bool? = nil,
        outdated: Bool? = nil,
        current_version: String? = nil,
        latest_version: String? = nil,
        summary: String? = nil,
        steam_appid: String? = nil,
        pkg_id: String? = nil,
        bundle_id: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.path = path
        self.source = source
        self.version = version
        self.size_bytes = size_bytes
        self.size_measured = size_measured
        self.data_bytes = data_bytes
        self.data_paths = data_paths
        self.last_used = last_used
        self.installed_at = installed_at
        self.usage_source = usage_source
        self.running_service = running_service
        self.tier = tier
        self.reason = reason
        self.cask_name = cask_name
        self.is_leaf = is_leaf
        self.outdated = outdated
        self.current_version = current_version
        self.latest_version = latest_version
        self.summary = summary
        self.steam_appid = steam_appid
        self.pkg_id = pkg_id
        self.bundle_id = bundle_id
    }
}

public struct OutdatedEntry: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let manager: String
    public let current_version: String?
    public let latest_version: String?
    public let title: String?
    public let summary: String?
    public let reason: String?
    public let kind: String?
    public let bundle_id: String?
    public var id: String { manager + ":" + name }
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }
    public var updatable: Bool { outdatedIsUpdatable(manager: manager, kind: kind) }

    public init(
        name: String,
        manager: String,
        current_version: String? = nil,
        latest_version: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        reason: String? = nil,
        kind: String? = nil,
        bundle_id: String? = nil
    ) {
        self.name = name
        self.manager = manager
        self.current_version = current_version
        self.latest_version = latest_version
        self.title = title
        self.summary = summary
        self.reason = reason
        self.kind = kind
        self.bundle_id = bundle_id
    }
}

public func outdatedIsUpdatable(manager: String, kind: String?) -> Bool {
    if kind == "untrusted" { return false }
    switch manager {
    case "brew-formula", "brew-cask", "flatpak",
         "apt", "pacman", "aur", "dnf", "yum", "zypper":
        return true
    default:
        return false
    }
}

public struct PackageEntry: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let manager: String
    public let kind: String
    public let version: String?
    public let size_bytes: Int?
    public let size_measured: Bool
    public let summary: String?
    public let reason: String?
    public let children: [String]?
    public var id: String { manager + ":" + name }
    public var packageKind: PackageKind? { PackageKind(rawValue: kind) }
    public var canMarkManual: Bool {
        kind == "orphan" && ["apt", "pacman", "dnf", "zypper"].contains(manager)
    }

    public init(
        name: String,
        manager: String,
        kind: String,
        version: String? = nil,
        size_bytes: Int? = nil,
        size_measured: Bool = false,
        summary: String? = nil,
        reason: String? = nil,
        children: [String]? = nil
    ) {
        self.name = name
        self.manager = manager
        self.kind = kind
        self.version = version
        self.size_bytes = size_bytes
        self.size_measured = size_measured
        self.summary = summary
        self.reason = reason
        self.children = children
    }
}

public struct ScanData: Codable, Sendable {
    public let scanned_at: String
    public let duration_s: Double
    public let brew_available: Bool
    public let totals: ScanTotals
    public let leftovers: [LeftoverItem]
    public let software: [SoftwareItem]
    public let outdated: [OutdatedEntry]?
    public let packages: [PackageEntry]?
    public var from_cache: Bool?
    public var incomplete: Bool?

    public init(
        scanned_at: String,
        duration_s: Double,
        brew_available: Bool,
        totals: ScanTotals,
        leftovers: [LeftoverItem],
        software: [SoftwareItem],
        outdated: [OutdatedEntry]? = nil,
        packages: [PackageEntry]? = nil,
        from_cache: Bool? = nil,
        incomplete: Bool? = nil
    ) {
        self.scanned_at = scanned_at
        self.duration_s = duration_s
        self.brew_available = brew_available
        self.totals = totals
        self.leftovers = leftovers
        self.software = software
        self.outdated = outdated
        self.packages = packages
        self.from_cache = from_cache
        self.incomplete = incomplete
    }
}
