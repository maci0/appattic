import Foundation

// Grouping: one row per orphan family, from raw items to the merged row.

public func groupOrphanedLeftovers(_ items: [DataItem]) -> [DataItem] {
    var buckets: [String: [DataItem]] = [:]
    for item in items {
        guard item.leftoverStatus == .orphaned, item.rootLabel != "LaunchAgents" else { continue }
        let key = leftoverGroupKey(item.name)
        guard !key.isEmpty else { continue }
        buckets[key, default: []].append(item)
    }
    collapseBundleIdChildBuckets(&buckets)
    collapseVendorPrefixBuckets(&buckets)
    let mergeKeys = Set(buckets.compactMap { $0.value.count > 1 ? $0.key : nil })
    // Owner index: the old per-item `leftoverBucketKey` re-derived the group
    // key and fell back to an O(buckets × size) identity scan, O(n²) after
    // collapses moved members. One pass here instead. The index is built from
    // the collapsed buckets, so an item it does not list is in no bucket at
    // all: that scan could only ever return the item's own key.
    var ownerOf: [ObjectIdentifier: String] = [:]
    ownerOf.reserveCapacity(items.count)
    for (key, group) in buckets {
        for member in group { ownerOf[ObjectIdentifier(member)] = key }
    }
    var consumed = Set<ObjectIdentifier>()
    var out: [DataItem] = []
    out.reserveCapacity(items.count)
    for item in items {
        let id = ObjectIdentifier(item)
        if consumed.contains(id) { continue }
        // The key is only ever read on the branch that merges a bucket, so an
        // item that cannot join one (owned, system, LaunchAgent) does not
        // re-derive a group key it would discard: `leftoverGroupKey` runs
        // `entryLabel` and `norm` per call, and most rows of a real list are
        // not orphaned.
        if item.leftoverStatus == .orphaned, item.rootLabel != "LaunchAgents",
           let key = ownerOf[id] ?? leftoverGroupKey(item.name), mergeKeys.contains(key),
           let group = buckets[key]
        {
            out.append(mergeOrphanGroup(group))
            for member in group { consumed.insert(ObjectIdentifier(member)) }
            continue
        }
        out.append(item)
    }
    return out
}

func leftoverGroupKey(_ name: String) -> String {
    let label = entryLabel(name)
    let n = norm(label)
    if let canon = leftoverProductAliases[n] { return canon }
    if leftoverProductAliases.values.contains(n) { return n }
    for part in posixLowercased(label).split(separator: ".") {
        let p = norm(String(part))
        if let canon = leftoverProductAliases[p] { return canon }
        if leftoverProductAliases.values.contains(p) { return p }
    }
    return n
}

func collapseBundleIdChildBuckets(_ buckets: inout [String: [DataItem]]) {
    // Index: lowered entry label -> bucket keys holding an item with that label,
    // plus per-bucket max label length (the old parent weight) and per-item labels.
    // The old code compared every child×parent pair across buckets: O(B²·G²)
    // string compares, 33 s for 3 000 distinct ids. A child can only belong to
    // a bucket whose item label is a proper dot-prefix of its own, so enumerate
    // the child's prefixes and look up owners: O(n·depth).
    var itemLabel: [ObjectIdentifier: String] = [:]
    var labelOwners: [String: Set<String>] = [:]
    var bucketWeight: [String: Int] = [:]
    for (key, group) in buckets {
        var best = 0
        for item in group {
            let entry = entryLabel(item.name)
            let ll = posixLowercased(entry)
            itemLabel[ObjectIdentifier(item)] = ll
            labelOwners[ll, default: []].insert(key)
            if entry.count > best { best = entry.count }
        }
        bucketWeight[key] = best
    }
    // Snapshot keys: removals below must not disturb iteration. Order by
    // length then key: `buckets.keys` comes out of a hash table whose seed
    // varies per process, and Swift's sort is not stable, so equal-length
    // children would be collapsed in a different order from run to run.
    for childKey in buckets.keys.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }) {
        guard let childItems = buckets[childKey] else { continue }
        var bestParent: String?
        var bestLen = 0
        for child in childItems {
            guard let ll = itemLabel[ObjectIdentifier(child)] else { continue }
            // Proper dot-prefixes of the child label, longest first. The
            // parent side must itself contain a dot, so `com.foo.bar` can roll
            // up to `com.foo` and then stops at `com`.
            var prefix = ll
            while let dot = prefix.lastIndex(of: ".") {
                prefix = String(prefix[..<dot])
                guard asciiHasByte(prefix, 0x2E) else { break }
                // Sorted: `labelOwners[prefix]` is a Set, so parents of equal
                // label length would race for `bestParent` by hash order.
                for parentKey in (labelOwners[prefix] ?? []).sorted() where parentKey != childKey {
                    let plen = bucketWeight[parentKey] ?? 0
                    if plen > bestLen {
                        bestLen = plen
                        bestParent = parentKey
                    }
                }
            }
        }
        if let parentKey = bestParent, let moving = buckets.removeValue(forKey: childKey) {
            buckets[parentKey, default: []].append(contentsOf: moving)
        }
    }
}

func dnsVendorPrefix(_ name: String) -> String? {
    let parts = entryLabel(name).split(separator: ".").map { posixLowercased(String($0)) }.filter { !$0.isEmpty }
    guard parts.count >= 3, genericDnsLabels.contains(parts[0]), parts[1].count >= 3 else { return nil }
    if genericVendorLabels.contains(norm(parts[1])) { return nil }
    return parts[0] + "." + parts[1]
}

func collapseVendorPrefixBuckets(_ buckets: inout [String: [DataItem]]) {
    var byPrefix: [String: [String]] = [:]
    for (key, items) in buckets {
        let prefixes = Set(items.compactMap { dnsVendorPrefix($0.name) })
        guard prefixes.count == 1, let prefix = prefixes.first else { continue }
        byPrefix[prefix, default: []].append(key)
    }
    // Prefix-major order, and a key tie-break on equal totals: both loops walk
    // hash tables whose seed varies per process, so a run must not pick a
    // different survivor than the previous one.
    for prefix in byPrefix.keys.sorted() {
        let keys = byPrefix[prefix] ?? []
        guard keys.count > 1 else { continue }
        var totals: [String: Int] = [:]
        for key in keys {
            totals[key] = buckets[key]?.reduce(0) { addBytes($0, $1.sizeBytes) } ?? 0
        }
        // Largest total wins; an exact tie goes to the first key so the same
        // inputs always collapse to the same survivor.
        let primary = keys.sorted { a, b in
            let (ta, tb) = (totals[a] ?? 0, totals[b] ?? 0)
            return ta == tb ? a > b : ta < tb
        }.last!
        for key in keys.sorted() where key != primary {
            if let moving = buckets.removeValue(forKey: key) {
                buckets[primary, default: []].append(contentsOf: moving)
            }
        }
    }
}

func preferredLeftoverPrimary(_ group: [DataItem]) -> DataItem {
    group.max { a, b in
        let aSym = a.kind == "symlink"
        let bSym = b.kind == "symlink"
        if aSym != bSym { return aSym && !bSym }
        if a.sizeBytes != b.sizeBytes { return a.sizeBytes < b.sizeBytes }
        return a.path > b.path
    }!
}

func mergeOrphanGroup(_ group: [DataItem]) -> DataItem {
    let primary = preferredLeftoverPrimary(group)
    var seen = Set([primary.path])
    var extras: [String] = []
    for item in group {
        if seen.insert(item.path).inserted { extras.append(item.path) }
        for path in item.extraPaths where seen.insert(path).inserted {
            extras.append(path)
        }
    }
    primary.extraPaths = extras.sorted()
    primary.sizeBytes = group.reduce(0) { addBytes($0, $1.sizeBytes) }
    primary.sizeMeasured = group.allSatisfy(\.sizeMeasured)
    primary.mtime = group.compactMap(\.mtime).max() ?? primary.mtime
    primary.activityMtime = group.compactMap(\.activityMtime).max() ?? primary.activityMtime
    return primary
}
