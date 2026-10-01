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

/// Where `settings.json` lives: beside the scan cache, so one directory holds
/// everything the app writes for the account. `loadSettings` and `saveSettings`
/// both default to it.
public func defaultSettingsURL() -> URL {
    defaultScanCacheURL().deletingLastPathComponent().appendingPathComponent("settings.json")
}

/// The last settings file the app wrote, kept beside it as `settings.json.bak`.
///
/// `settings.json` is the only thing the app writes that a scan cannot rebuild:
/// the ignore list is the user's own choices, and a file that has been emptied,
/// truncated by a full disk, or hand-mangled into invalid JSON is refused by
/// `loadSettings` and never repaired. `saveSettings` copies the file it is
/// about to replace here first, so the last state the app itself wrote that
/// differs from the current one is always one `cp` away. A save that changed
/// nothing leaves this holding what it already held, so a repeated save cannot
/// replace that state with a copy of itself. Nothing reads this file at run
/// time: it is recovery material, and `docs/runbooks/state-recovery.md` is
/// what says so to a user.
public func settingsBackupURL(_ url: URL = defaultSettingsURL()) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
}

/// CLI `--include-system` ORs with the file. A true file value cannot be turned off from the CLI.
public func effectiveIncludeSystem(cliFlag: Bool, settings: AppAtticSettings) -> Bool {
    cliFlag || settings.includeSystem
}

/// The configuration one run actually uses, with every layer named: the
/// settings file, the file values, the flag that overrides them, the
/// environment roots the paths resolved to, and the environment switches that
/// change what the run does. `appattic config` prints it so two machines can
/// be diffed, which is the only way to tell a wrong value from a wrong path.
/// Encodable only: nothing reads configuration back out of a report.
public struct EffectiveConfig: Encodable, Equatable, Sendable {
    public let settingsPath: String
    public let settingsFileExists: Bool
    /// The last settings file the app wrote, and whether it is there. A
    /// missing backup next to an existing `settings.json` is the one state
    /// case a user cannot act on alone, so the config output names it.
    public let settingsBackupPath: String
    public let settingsBackupExists: Bool
    /// The settings file a restore replaced. Named with the backup because it is
    /// the other half of a restore's undo: the copy the runbook used to tell a
    /// user to make consumed the bytes it replaced, and these are what was
    /// consumed.
    public let settingsRejectedPath: String
    public let settingsRejectedExists: Bool
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
    /// The `gvfs` root the Linux window's network-folder scan opens at. The
    /// only XDG root outside the four the scan walks, and read by no command
    /// in this process, so it had no line and a diff of two machines could not
    /// show which root either window would pick.
    public let runtimeHome: String
    public let environment: [ConfigEnvEntry]

    /// One environment switch, its raw value, and what that value resolves to.
    public struct ConfigEnvEntry: Encodable, Equatable, Sendable {
        public let name: String
        public let value: String
        public let isSet: Bool
        /// The effect, in the words a reader needs to tell a wrong value from
        /// a right one. Never empty: a switch that is not set says so.
        public let effect: String
    }

    /// The merged value the scan and the report use, stored rather than
    /// computed so it is encoded by the synthesized `Encodable` alongside the
    /// two layers it merges. Both of those are `let`, so the stored copy cannot
    /// drift from them.
    public let includeSystem: Bool

    public init(
        settings: AppAtticSettings,
        settingsURL: URL = defaultSettingsURL(),
        includeSystemFlag: Bool = false,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.settingsPath = settingsURL.path
        self.settingsFileExists = FileManager.default.fileExists(atPath: settingsURL.path)
        self.settingsBackupPath = settingsBackupURL(settingsURL).path
        self.settingsBackupExists = FileManager.default.fileExists(atPath: settingsBackupURL(settingsURL).path)
        self.settingsRejectedPath = settingsRejectedURL(settingsURL).path
        self.settingsRejectedExists = FileManager.default.fileExists(atPath: settingsRejectedURL(settingsURL).path)
        self.includeSystemFile = settings.includeSystem
        self.includeSystemFlag = includeSystemFlag
        self.includeSystem = effectiveIncludeSystem(
            cliFlag: includeSystemFlag, settings: settings)
        self.confirmDelete = settings.confirmDelete
        self.ignoredLeftoverPaths = settings.ignoredLeftoverPaths
        self.scanCachePath = defaultScanCacheURL().path
        self.dataHome = xdgDataHome(env: env)
        self.configHome = xdgConfigHome(env: env)
        self.cacheHome = xdgCacheHome(env: env)
        self.stateHome = xdgStateHome(env: env)
        self.dataDirs = xdgSystemDirs(env: env)
        self.runtimeHome = gvfsRoot(home: FileManager.default.homeDirectoryForCurrentUser.path, env: env)
        self.environment = configEnvEntries(env: env)
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
            "ignoredLeftoverPaths: \(localeCount(ignoredLeftoverPaths.count))",
        ]
        // The count cannot be wrong in a way a reader can see. The entries are
        // what a user compares against the paths a report prints, so they are
        // printed in full, the way the paths on either side of them are.
        lines.append(contentsOf: ignoredLeftoverPaths.map { "  \($0)" })
        lines.append(contentsOf: [
            "scan cache: \(scanCachePath)",
            "settings backup: \(settingsBackupPath)\(settingsBackupExists ? "" : " (missing)")",
            "settings replaced by a restore: \(settingsRejectedPath)\(settingsRejectedExists ? "" : " (missing)")",
            "XDG_DATA_HOME: \(dataHome)",
            "XDG_CONFIG_HOME: \(configHome)",
            "XDG_CACHE_HOME: \(cacheHome)",
            "XDG_STATE_HOME: \(stateHome)",
            "XDG_DATA_DIRS: \(dataDirs)",
            "XDG_RUNTIME_DIR: \(runtimeHome)",
        ])
        // The switches last, and only the ones the process actually reads, so
        // the block stays the diff surface: a value that is unset says `unset`
        // rather than being absent, which is the difference between "no
        // override" and "an override I forgot".
        lines.append(contentsOf: environment.map { entry in
            let shown = entry.isSet ? "\"\(entry.value)\"" : "unset"
            return "\(entry.name): \(shown) [\(entry.effect)]"
        })
        return lines
    }
}

/// The environment switches the app reads, with the effect each value has.
///
/// A switch the process does not read is not listed, so the block cannot grow
/// into a copy of the environment: these are the names in the README's
/// environment table whose effect is one boolean or one choice. The XDG roots
/// are not here, because each has its own resolution rule rather than a switch
/// value; `EffectiveConfig.lines` prints those as plain `NAME: path` lines
/// above. The two host-exec switches are read by the C core host and the Qt
/// shell rather than by this process, and they are listed because a Linux run's
/// package results come from them and a diff of two machines has to show that.
public func configEnvEntries(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [EffectiveConfig.ConfigEnvEntry] {
    func entry(
        _ name: String,
        unsetEffect: String,
        effect: (String) -> String
    ) -> EffectiveConfig.ConfigEnvEntry {
        let raw = env[name]
        return EffectiveConfig.ConfigEnvEntry(
            name: name,
            value: raw ?? "",
            isSet: raw != nil,
            effect: raw.map(effect) ?? unsetEffect
        )
    }
    return [
        entry("NO_COLOR", unsetEffect: "colors on a tty") { raw in
            raw.isEmpty ? "set but empty, which is not a disable" : "colors off"
        },
        entry("TERM", unsetEffect: "not set") { raw in
            if raw == "dumb" { return "colors off (dumb terminal)" }
            return raw.isEmpty ? "set but empty, which is not a disable" : "colors on (only dumb disables)"
        },
        entry("COLORFGBG", unsetEffect: "light status colors") { _ in
            cliTone(env: env) == .dark ? "dark status colors" : "light status colors"
        },
        entry("APPATTIC_PAGE", unsetEffect: "overview") { raw in
            let page = resolveStartPage(env: ["APPATTIC_PAGE": raw])
            return page.unknownValue == nil ? page.page.rawValue : "unknown, opening overview"
        },
        entry("FLATPAK_ID", unsetEffect: "host run") { raw in
            raw.isEmpty ? "set but empty, so a host run" : "sandboxed: package queries go through /run/host"
        },
        entry("APPATTIC_HOST_EXEC_LIVE", unsetEffect: "off: fixtures unless the platform forces them") { raw in
            configBoolSwitch(raw) ? "on: package queries run the real binaries" : "off: read as off"
        },
        entry("APPATTIC_HOST_EXEC_FIXTURE", unsetEffect: "off: live package queries") { raw in
            configBoolSwitch(raw) ? "on: built-in fixtures" : "off: live package queries"
        },
        entry("APPATTIC_CORE_OUT", unsetEffect: "searched next to the binary") { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "set but empty, so it is searched next to the binary" }
            // `coreOutDir` ignores a value that is not an absolute path, so
            // reporting it as in force would name a directory the window
            // never looked in.
            guard trimmed.hasPrefix("/") else {
                return "not an absolute path, so it is searched next to the binary"
            }
            return "WASM modules read from this directory"
        },
        // The two Android SDK variables are the first ones in this block that
        // choose a root rather than a switch, and they were the only roots the
        // scan read that nothing here named: a user who exported one and still
        // saw no `android` overlay had no way to tell a stale value from a
        // value the report ignored. Reported together because the scan takes
        // the first of the two that holds a real SDK.
        entry("ANDROID_HOME", unsetEffect: "the default SDK directories only") { raw in
            androidSdkEntryEffect(raw, home: env["ANDROID_SDK_ROOT"] ?? "")
        },
        entry("ANDROID_SDK_ROOT", unsetEffect: "the default SDK directories only") { raw in
            androidSdkEntryEffect(raw, home: env["ANDROID_HOME"] ?? "")
        },
        // `LANG` picks the `.lproj` directories the macOS app-name lookup
        // reads, so a machine diff that omitted it could show two runs naming
        // the same app differently with every other line equal. The value is
        // resolved by `lprojLocale`, the helper `lprojCandidates` uses, so the
        // report cannot name a locale the app did not look for.
        entry("LANG", unsetEffect: "the base English app names") { raw in
            if raw.isEmpty { return "set but empty, so the base English app names" }
            let locale = lprojLocale(lang: raw)
            return locale.isEmpty
                ? "set but empty, so the base English app names"
                : "app names read from the \(locale) .lproj when it exists"
        },
    ]
}

/// The effect of one Android SDK variable as the scan resolves it: the first
/// of the two that holds a directory with an SDK in it is the root in force,
/// and a value that names neither is read as absent, so the report says which
/// of the two cases a value is rather than claiming a root the scan skipped.
/// A value is taken as `defaultAndroidSdkDirs` takes it, untrimmed, so the
/// report cannot name a root the scan did not test.
private func androidSdkEntryEffect(_ raw: String, home other: String) -> String {
    let candidates = [raw, other]
    if let real = candidates.first(where: { !$0.isEmpty && androidSdkLooksReal($0) }) {
        return "Android SDK read from \(real)"
    }
    if candidates.contains(where: { !$0.isEmpty }) {
        return "set, but no such SDK directory, so the default directories only"
    }
    return "set but empty, so the default SDK directories only"
}

/// `1`/`true`/`yes`/`on` in any case, after trimming, and nothing else.
///
/// The trim set is the C host's, not Foundation's: `env_flag` in
/// `core/host/hostexec.c` strips a space and a tab off each end and compares
/// what is left, so that is all a value may carry here. `trimmingCharacters(in:
/// .whitespaces)` also strips a newline, a carriage return, a form feed, a
/// vertical tab, and every Unicode space, and an `APPATTIC_HOST_EXEC_LIVE`
/// holding `"\n1\n"` then read as on in this report and as off in the host that
/// actually runs the query — the report claiming a live execvp that never
/// happened. `Package.swift` trims the same set for `APPATTIC_NO_MAC_UI`, and
/// `scripts/lint.sh` compares all three so the sets cannot drift again.
func configBoolSwitch(_ raw: String) -> Bool {
    let value = configBoolSwitchTrimmed(raw).lowercased()
    return value == "1" || value == "true" || value == "yes" || value == "on"
}

/// The blanks `configBoolSwitch` removes, and no others: U+0020 and U+0009,
/// the two `env_flag` skips. Named so the lint check can read the literals out
/// of the one place that applies them.
let configBoolSwitchTrimSet = " \t"

func configBoolSwitchTrimmed(_ raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet(charactersIn: configBoolSwitchTrimSet))
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
    // The decoder's string unwrap is a `try!` for the control characters
    // scanning leaves it. The settings file is written by hand, so this is the
    // reader most likely to meet one; see `jsonHasNoControlCharacterInString`.
    guard jsonHasNoControlCharacterInString(raw) else {
        throw SettingsError.invalid(path: path, reason: "not valid JSON: control character in a string")
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
    if let bad = settings.ignoredLeftoverPaths.first(where: { $0.hasSuffix("/") }) {
        throw SettingsError.invalid(
            path: path,
            reason: "ignoredLeftoverPaths entry \"\(bad)\" has a trailing slash; "
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
        //
        // `writeOwnerOnlyFile`, not `write(to:options:.atomic)` then a chmod:
        // the ignore list is paths under the account's own home, and the atomic
        // rename publishes the file at the umask default before the mode is
        // narrowed. `prepareStateDirectory` above closes that window for the
        // app's own state directory, and a caller-supplied `to:` can name any
        // other parent. mkstemp creates at `0600`, so there is no window at any
        // destination.
        try? keepSettingsBackup(at: url, replacingWith: raw)
        try writeOwnerOnlyFile(raw, to: url)
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
}

/// Copy the settings file that is about to be replaced to `settings.json.bak`,
/// so the last state the app wrote survives the write that replaces it.
///
/// A file the backup already holds is not copied again. A save that changed
/// nothing is a normal one: the settings page persists on every toggle, a
/// double click reaches the handler twice, and a window that re-saves what it
/// loaded writes the same bytes. Copying them would leave the backup holding a
/// copy of the file that is already there, and the last state that differed
/// from the current one would be gone: exactly the state this file exists for,
/// destroyed by a run that removed nothing.
///
/// A backup that does not land does not stop the save. The file being replaced
/// is either readable and the copy is worth having, or unreadable and there is
/// nothing to copy; either way the write the caller asked for has to be the one
/// that happens, and the older backup, if there is one, is still the last
/// state the app wrote.
private func keepSettingsBackup(at url: URL, replacingWith raw: Data) throws {
    guard let previous = try? Data(contentsOf: url), !previous.isEmpty else { return }
    if previous == raw { return }
    let backup = settingsBackupURL(url)
    if let kept = try? Data(contentsOf: backup), kept == previous { return }
    try writeOwnerOnlyFile(previous, to: backup)
}

/// The settings file a restore replaced, kept beside the backup. Recovery
/// material like the backup and read by nothing: it is what makes a restore
/// that turned out to be the wrong one undoable, and `docs/privacy.md` is where
/// the extra copy of the account's own paths is recorded.
public func settingsRejectedURL(_ url: URL = defaultSettingsURL()) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bad")
}

/// Put `settings.json.bak` back in place of `settings.json`, after checking
/// that the backup is a file the app will actually load.
///
/// The copy `docs/runbooks/state-recovery.md` used to tell a user to make had
/// nothing to check: a backup that is itself truncated, emptied by a full disk,
/// or hand-mangled replaced a file that was still on disk with one the loader
/// refuses, and the bytes the copy consumed were gone. So the backup is read
/// through `loadSettings` — the same parser, and the only definition of a
/// settings file the app accepts — before anything is written. A backup that
/// does not load is reported as the failure it is and changes nothing on disk.
///
/// The Linux window's `restoreSettingsBackup` is the same function in Qt,
/// with the same two files and the same check, because a backup a user can
/// restore in one window and not the other is not a backup.
///
/// The file being replaced is kept as `settings.json.bad` first, one generation
/// the way the backup is. A restore is a destructive step a user takes by hand
/// on a machine that is already broken; if it is interrupted, or the file it
/// wrote turns out to be the wrong state, what was there is still there. It is
/// written the owner-only way the other two are and read at run time by
/// nothing.
///
/// The restore itself goes through `writeOwnerOnlyFile`, so it is whole or not
/// at all and is on disk before this returns, the same as a save.
@discardableResult
public func restoreSettingsBackup(
    from url: URL = defaultSettingsURL()
) throws -> AppAtticSettings {
    let backup = settingsBackupURL(url)
    guard FileManager.default.fileExists(atPath: backup.path) else {
        throw SettingsError.unreadable(
            path: backup.path,
            reason: "there is no settings backup to restore"
        )
    }
    // The parse is the check. A backup that loads is a file the app will read,
    // so the restore cannot be the step that leaves the settings unloadable.
    let restored = try loadSettings(from: backup)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let raw: Data
    do {
        raw = try encoder.encode(restored.normalized())
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
    do {
        try prepareStateDirectory(url.deletingLastPathComponent())
        // Keep the state this restore replaces, so a restore that was wrong is
        // still a `cp` from being undone. A file that is not there is not a
        // failure: then the wanted state is a fresh settings.json.
        if let current = try? Data(contentsOf: url), !current.isEmpty, current != raw {
            try writeOwnerOnlyFile(current, to: settingsRejectedURL(url))
        }
        try writeOwnerOnlyFile(raw, to: url)
    } catch let error as SettingsError {
        throw error
    } catch {
        throw SettingsError.unwritable(path: url.path, reason: error.localizedDescription)
    }
    return restored
}
