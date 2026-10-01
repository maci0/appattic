import Foundation

/// Search-box matching for the rows each list page shows.
///
/// Every surface that filters rows folds the query with `posixFolded` first,
/// so "Cafe" + U+0301 matches "Café" and "CAFÉ" matches either. A typed query
/// is compared against the fields a reader sees on that row and nothing else:
/// a page that matched a hidden field would show a row whose match is not on
/// screen.
///
/// `filterPackages` in `Packages` owns the Packages page, because it also sorts.
/// These three are predicates only, so a surface filters with them and keeps
/// its own ordering.

// MARK: - Query

/// The folded query, or nil when the search box is empty. Callers skip the
/// per-row test entirely on nil rather than folding every row against "".
public func searchQuery(_ search: String) -> String? {
    let q = posixFolded(search)
    return q.isEmpty ? nil : q
}

/// True when any of `fields` contains the folded query. An empty or absent
/// query matches every row, so a caller can pass this without a guard.
public func searchMatches(_ q: String?, _ fields: String?...) -> Bool {
    guard let q else { return true }
    return fields.contains { field in
        guard let field else { return false }
        return posixFolded(field).contains(q)
    }
}

// MARK: - Rows

/// A leftover row matches when the query is in its display name, path, root,
/// status, owner, reason, summary, or shadows. `extra_paths` match on the
/// folded path too: the display name is already built from them, but it
/// collapses to one label, so a query naming a second path only finds the row
/// through this test.
public func leftoverMatchesSearch(_ item: LeftoverItem, _ q: String?) -> Bool {
    guard let q else { return true }
    if searchMatches(q, leftoverDisplayName(name: item.name, extraPaths: item.extra_paths ?? []),
                     item.name, item.path, item.root, item.status,
                     item.owner, item.reason, item.summary, item.shadows) { return true }
    return (item.extra_paths ?? []).contains { posixFolded($0).contains(q) }
}

/// A stale-software row matches when the query is in its name, path, source,
/// tier, reason, or summary. A prefix of "outdated" also matches any row
/// flagged `outdated`, so the flag is searchable from the same box.
public func softwareMatchesSearch(_ item: SoftwareItem, _ q: String?) -> Bool {
    guard let q else { return true }
    if searchMatches(q, item.name, item.path, item.source,
                     item.tier, item.reason, item.summary) { return true }
    return item.outdated == true && "outdated".hasPrefix(q)
}

/// An outdated row matches when the query is in its name, manager, title,
/// summary, or reason.
public func outdatedMatchesSearch(_ entry: OutdatedEntry, _ q: String?) -> Bool {
    searchMatches(q, entry.name, entry.manager, entry.title, entry.summary, entry.reason)
}