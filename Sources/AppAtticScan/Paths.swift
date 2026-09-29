import Foundation
/// XDG Base Directory: unset, empty, or non-absolute values use `home/fallback`.
/// A trailing separator is dropped, so the value reads as the directory the
/// scan opens. `core/host/hostexec.c` and `ui/linux-qt/finding.cpp` normalize
/// the same way, and a root that ends in one makes the host build a path with
/// two separators where the CLI printed one.
public func xdgUserDir(
    _ variable: String,
    fallback: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    if let raw = env[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("/") {
        var root = raw
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        return root
    }
    return (home as NSString).appendingPathComponent(fallback)
}

/// `$XDG_DATA_HOME`, or `$HOME/.local/share` when it is unset, empty, or not
/// absolute. `home` and `env` are parameters so a caller can resolve another
/// account's paths, or a fixture's, without touching the process environment.
public func xdgDataHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_DATA_HOME", fallback: ".local/share", home: home, env: env)
}

/// `$XDG_CONFIG_HOME`, or `$HOME/.config`, under the same rules as
/// `xdgDataHome`.
public func xdgConfigHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_CONFIG_HOME", fallback: ".config", home: home, env: env)
}

/// `$XDG_CACHE_HOME`, or `$HOME/.cache`, under the same rules as
/// `xdgDataHome`.
public func xdgCacheHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_CACHE_HOME", fallback: ".cache", home: home, env: env)
}

/// `$XDG_STATE_HOME`, or `$HOME/.local/state`, under the same rules as
/// `xdgDataHome`.
public func xdgStateHome(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgUserDir("XDG_STATE_HOME", fallback: ".local/state", home: home, env: env)
}

/// The spec default for an unset or empty `XDG_DATA_DIRS`, and for one that
/// names no absolute entry to search.
private let defaultXDGDataDirs = ["/usr/local/share", "/usr/share"]

/// The system data roots a scan searches, as the spec defines them: unset,
/// empty, or a variable whose entries are all relative uses the spec default,
/// and a relative entry in a longer list is dropped.
///
/// Filtering here rather than at each caller is what makes `appattic config`
/// honest. The report printed the variable as written, so a
/// `XDG_DATA_DIRS=relative:/opt/share` named a root the scan never looked in.
/// A variable that names no usable root is read as unset, not as a request to
/// search nothing: `linuxDesktopDirs` searches both spec roots either way, so
/// the fallback changes no result.
public func xdgSystemDirList(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    let raw = env["XDG_DATA_DIRS"] ?? ""
    var out: [String] = []
    for entry in raw.split(separator: ":", omittingEmptySubsequences: false) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { out.append(trimmed) }
    }
    return out.isEmpty ? defaultXDGDataDirs : out
}

/// The same roots as `xdgSystemDirList`, joined the way the variable spells
/// them, for the `XDG_DATA_DIRS:` line of `appattic config`.
public func xdgSystemDirs(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    xdgSystemDirList(env: env).joined(separator: ":")
}

/// Fold one scalar the way `norm` does: NFD -> case+diacritic fold -> keep
/// ASCII letters/digits. Only the non-ASCII path needs the full Unicode machinery.
private func normSlow(_ s: String) -> String {
    s.decomposedStringWithCanonicalMapping
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

/// Identity token for leftover/app matching. NFC and NFD spellings of the same
/// word collapse (macOS filenames are NFD, plist names are usually NFC), and
/// `normSlow` shows the full fold this fast path reproduces.
public func norm(_ s: String) -> String {
    // Fast path: for pure-ASCII input, canonical decomposition and diacritic
    // folding are no-ops, so this is exactly lowercasing then keeping [a-z0-9].
    // Most app names take it, avoiding three String allocations per call.
    var bytes: [UInt8] = []
    bytes.reserveCapacity(s.utf8.count)
    for b in s.utf8 {
        if b >= 0x80 {
            return normSlow(s)
        }
        let c = (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
        if (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) {
            bytes.append(c)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// `norm`, or nil when the fold leaves nothing. `norm` keeps only ASCII
/// letters and digits, so a name written entirely in another script (CJK,
/// Cyrillic, Greek) or made of symbols folds to "". A table indexed by this
/// key must skip the empty form, or the first such name indexed answers every
/// later one: a catalog entry for 微信 would describe any other non-Latin
/// leftover.
public func normKey(_ s: String) -> String? {
    let k = norm(s)
    return k.isEmpty ? nil : k
}

/// Comparison form for leftover ignore paths. NFC so a pasted path matches
/// a filesystem path that used combining marks.
public func pathIdentityKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping
}

/// Standardized home, cached: `homeDirectoryForCurrentUser` (6.7 µs) plus
/// `standardizingPath` (4 µs) dominated this function, not the scan itself.
/// Bounded: `redactHomePaths` takes a caller-supplied home, so the key space is
/// whatever a long-lived process passes in, and the map outlives every scan.
/// Only caller-supplied homes live here; the process home has its own slot,
/// because `""` is a real caller home and not a stand-in for "no home given".
private let redactHomeLock = NSLock()
private let redactHomeCacheLimit = 8
nonisolated(unsafe) private var redactHomeCache: [String: String] = [:]
nonisolated(unsafe) private var redactProcessHome: (standardized: String, raw: String?)? = nil

/// Drop one entry once the map is over the limit. Not an age: a caller that
/// feeds it unbounded keys must not grow it, but the working set is whatever
/// that caller reuses. The victim is the greatest key, so the entries a run
/// keeps do not depend on the hash seed. `keeping` is never the victim: a home
/// whose spelling sorts last would otherwise be dropped by the very call that
/// stored it, and every later lookup of it would pay the `standardizingPath`
/// again while the eight rarely passed homes sat in the map.
private func trimRedactHomeCache(keeping keep: String) {
    guard redactHomeCache.count > redactHomeCacheLimit,
          let victim = redactHomeCache.keys
            .filter({ $0 != keep })
            .max()
    else { return }
    redactHomeCache.removeValue(forKey: victim)
}

private func standardizedHome(_ home: String) -> String {
    redactHomeLock.lock()
    defer { redactHomeLock.unlock() }
    if let cached = redactHomeCache[home] { return cached }
    let std = (home as NSString).standardizingPath
    redactHomeCache[home] = std
    trimRedactHomeCache(keeping: home)
    return std
}

/// Process home, resolved once: `homeDirectoryForCurrentUser` costs ~7 µs per
/// call and the old default-arg form paid it on every log line. Kept out of
/// `redactHomeCache` so an explicit `home: ""` cannot read this slot back.
///
/// Both spellings are kept. `standardizingPath` resolves symlinks on Darwin
/// (/home, /tmp, /var) and on a symlinked Linux home, and a subprocess error
/// can carry either the resolved form or the one `$HOME` names, so a cache
/// holding only the resolved form left the other spelling in the message.
private func processHome() -> (standardized: String, raw: String?) {
    redactHomeLock.lock()
    defer { redactHomeLock.unlock() }
    if let cached = redactProcessHome { return cached }
    let raw = FileManager.default.homeDirectoryForCurrentUser.path
    let std = (raw as NSString).standardizingPath
    let cached = (standardized: std, raw: raw == std ? nil : raw)
    redactProcessHome = cached
    return cached
}

/// Replace the user's home directory prefix with `~` so logs and errors do not
/// carry the account path. `/home/alice2` is left alone when home is `/home/alice`.
public func redactHomePaths(
    _ text: String,
    home: String? = nil
) -> String {
    // No path separator, no home prefix.
    guard text.contains("/") else { return text }
    let homePath: String
    var rawHome: String?
    if let home {
        homePath = standardizedHome(home)
        // `standardizingPath` resolves symlinks on Darwin (/home, /tmp, /var),
        // so a subprocess error can carry either spelling. Try both.
        if home != homePath { rawHome = home }
    } else {
        let cached = processHome()
        homePath = cached.standardized
        rawHome = cached.raw
    }
    for candidate in homePathSpellings(homePath) + (rawHome.map(homePathSpellings) ?? []) {
        if candidate.count > 1, text.contains(candidate),
           let redacted = redactHomePrefix(text, homePath: candidate) {
            return redacted
        }
    }
    return text
}

/// Spellings of a path that name the same path. macOS reports account and app
/// names in NFD, while tools and pasted text print NFC, so a byte comparison
/// finds no home prefix in a log line carrying an accented account name.
private func homePathSpellings(_ path: String) -> [String] {
    let nfc = path.precomposedStringWithCanonicalMapping
    let nfd = path.decomposedStringWithCanonicalMapping
    var out = [path]
    for variant in [nfc, nfd] where variant != path { out.append(variant) }
    return out
}

/// Replace every `homePath` occurrence in `text` that ends on a path boundary
/// with `~`. Nil when there is none. `range(of:)` works on any String, so the
/// Darwin bridged-NSString case needs no byte-scan fallback.
private func redactHomePrefix(_ text: String, homePath: String) -> String? {
    var ranges: [Range<String.Index>] = []
    var search = text.startIndex
    while let r = text.range(of: homePath, range: search..<text.endIndex) {
        if r.upperBound == text.endIndex || isHomeBoundary(text[r.upperBound]) {
            ranges.append(r)
        }
        search = text.index(after: r.lowerBound)
    }
    guard !ranges.isEmpty else { return nil }
    var out = text
    // Replace back to front so earlier indices stay valid.
    for r in ranges.reversed() {
        out.replaceSubrange(r, with: "~")
    }
    return out
}

/// A path prefix may only be redacted when it ends here: end of text, a
/// separator, or a character that cannot continue a path. A parenthetical
/// message (`Cannot open /home/u (denied)`) and a bracketed one put the
/// account name behind a byte this set did not carry, so the whole line came
/// back unredacted. Anything that is neither a separator nor a path character
/// ends the path; only a path character means a longer name could follow.
private func isHomeBoundary(_ c: Character) -> Bool {
    if c == "/" || c == " " || c == "\t" || c == "\n" || c == "\r" { return true }
    return !c.isLetter && !c.isNumber && c != "." && c != "-" && c != "_"
        && c != "~" && c != "+" && c != "="
}

public func cleanupPathDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
    [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        (home as NSString).appendingPathComponent(".local/bin"),
        (home as NSString).appendingPathComponent("bin"),
        "/usr/bin",
        "/bin",
    ]
}
