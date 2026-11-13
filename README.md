# AppAttic

Finds the data uninstalled apps leave behind, the software you no longer use, packages nothing needs, and what fills your disk, on macOS and Linux. One CLI for both, and a native window on each.

The CLI deletes nothing you have not seen: cleanup is a shell script it prints for you to read and run (`--dry-run`), and `update` asks before it runs. The windows run cleanup, update, and mark-manual scripts after a confirm dialog, which `confirmDelete` can turn off ([Settings](#settings)). `appattic erase` is the exception: it deletes AppAttic's own scan snapshot without asking. Everything runs locally: no account, no server, no telemetry ([`docs/privacy.md`](docs/privacy.md)).

## Status

| Part | Platforms | State |
|---|---|---|
| `appattic` CLI and the `AppAtticScan` Swift library | macOS, Linux | Works. Built and tested in CI on Ubuntu 24.04, a Swift 5.10.1 jammy container, Arch, and macOS |
| `appattic-qt` window (C++ Qt 6 Widgets, scans through the Zig WASM core in [`core/`](core/README.md)) | Linux | Works. Linked and smoke-tested in CI on Ubuntu and Arch; released as an x86_64 AppImage |
| `AppAtticUI` window (SwiftCrossUI on AppKit) | macOS | Source present, outside the pinned build. SwiftCrossUI needs Swift 6; `./build.sh` enforces 5.10.1 and falls back to the CLI. A separate Swift 6 build setup is required. Not built in CI or released |

The CLI and the Linux window run two scanners ([`core/README.md`](core/README.md), "Mirror rule"), and they differ: only the Linux window lists RubyGems and Composer globals, container leftovers, and PPA source files; only the CLI and macOS window read Homebrew tap trust and scan installed system apps.

## What it reports

- **Leftovers.** User data whose owner app is gone (Application Support, caches, XDG dirs, and similar), plus user overlays in `~/.local/bin`, `~/bin`, `~/.cargo/bin`, and `~/.local/share/applications` that hide a same-named packaged file. Overlay rows have status `shadow`, and cleanup removes the overlay only. Apple, system, and toolchain dirs are never counted as reclaimable.
- **Stale.** Installed apps and Homebrew formulas with weak or old usage, from Spotlight (macOS, including the inner executable), running processes, prefs and data-dir mtimes, Linux `recently-used.xbel`, and shell history for CLI tools. Unused is not the same as outdated.
- **Outdated.** Newer versions from Homebrew, Flatpak, Snap, apt, pacman, AUR (paru/yay/pikaur), dnf/yum, zypper, and the App Store. Homebrew, Flatpak, apt, pacman, AUR, dnf/yum, and zypper rows can be upgraded from the Outdated page or `appattic update`. That is a named upgrade, never a full distro upgrade (`apt upgrade`, `pacman -Syu`). App Store, Snap, and the language globals (npm, pnpm, Bun, pip, pipx, uv, RubyGems, Composer, Deno) are report-only. The CLI and macOS window also keep casks from an untrusted Homebrew tap report-only; the Linux window does not read tap trust and offers them as updatable. Homebrew is asked without `--greedy`, so an auto-updating cask is not flagged just because its bottle is older than the running app.
- **Packages.** Distro orphans (nothing still needs them), Debian/Ubuntu `dpkg` config remnants (`rc`), and user-global language tools (`npm`/`pnpm`/`bun -g`, pipx, `uv tool`, top-level pip user-site, `~/.deno/bin`). Remove and mark-as-manual run as a generated script: printed by `packages --dry-run`, or run by a window.
- **Disk usage.** Folder and device sizes as a tree, allocated or apparent, with ring and treemap charts in the Linux window. Scan home, a folder, or a file system; open in the file manager; move to Trash, which always asks first. Other file systems are not descended into unless you ask, and directory symlinks are not followed.

Installed software gets a tier: KEEP (in use), REVIEW (idle, check first), REMOVE (stale and easy to reinstall). The CLI cleanup scripts (`report`, `leftovers`, `stale` with `--dry-run`) hold only orphaned leftovers, PATH overlays, and REMOVE-tier items; `packages --dry-run` is a separate package script. The windows can also uninstall REVIEW-tier apps you tick.

## Install

From a release: the GitHub release page carries `AppAttic-x86_64.AppImage` (the Linux window) with its `.zsync`. Update metadata points to that release tag; it does not discover newer tags. Download newer versions from Releases. Arch recipes for a tagged release are in [`packaging/aur/`](packaging/aur/): `appattic` (the CLI), `appattic-qt` (the window against the distro's Qt 6), and `appattic-bin` (the AppImage; conflicts with `appattic-qt`).

From source, on macOS or Linux:

```bash
bash scripts/linux-deps.sh   # preflight: what is present, what is missing (also on macOS)
./build.sh                   # release CLI; also the Linux window when Qt 6 is available
./run.sh report              # first scan
./run.sh --ui                # Linux window; macOS requires a separately built UI
```

`./build.sh` needs Swift 5.10.1 (`.swift-version`) and looks for it on `PATH`, then in `/opt/swift/usr/bin`, then `.deps/swift/usr/bin`; a missing toolchain is a named error. The Linux window also needs Qt 6 Widgets headers, Zig, and the Wasmtime C API; without Qt, `./build.sh` still builds the CLI. The CLI needs no Qt and no display. Toolchain setup, the AppImage and Flatpak builds, and the test gates are in [CONTRIBUTING.md](CONTRIBUTING.md).

## CLI

```bash
appattic                          # same as: appattic report
appattic leftovers --top 10
appattic leftovers --dry-run      # print the cleanup script, run nothing
appattic disk /var --top 20 --allocated
appattic update --dry-run
appattic report --json scan.json
```

From a checkout, `./run.sh <command>` runs the newest built binary (`.build/release/appattic` or `.build/debug/appattic`). `appattic --help` and `man appattic` (`packaging/appattic.1`) are the full reference; `appattic schema` prints it as a clispec v0.3 JSON document.

| Command | Does |
|---|---|
| `report` | Leftovers, stale, outdated, and packages. The default |
| `leftovers`, `stale`, `outdated`, `packages` | One section of the report |
| `disk [PATH]` | Folder-size tree of PATH, default home. Exit 2 for a missing PATH or a file |
| `update` | Named upgrades. Prompts on a terminal; with no terminal it exits 2 unless `--yes` |
| `config` | The settings and paths this machine resolves. Scans nothing |
| `erase` | Delete the saved scan snapshot |
| `restore` | Put `settings.json.bak` back in place of `settings.json` |
| `schema [CMD]` | The clispec document, or one command of it. Reads no settings |
| `help [CMD]` | Same as `--help` |

| Option | On | Does |
|---|---|---|
| `--dry-run` | scan commands, `update` | Print the shell script instead of running anything |
| `--fresh` | scan commands, `update` | Ignore the last-scan cache |
| `--include-system` | scan commands, `update`, `config` | Include OS system apps in the stale list |
| `--top N` | `report`, `leftovers`, `disk` | N largest leftovers, or N largest entries per folder |
| `--category CAT` | `report`, `leftovers` | Filter by category substring; repeatable |
| `--leftovers-only`, `--stale-only` | `report` | One half of the report |
| `--all-file-systems`, `--allocated` | `disk` | Descend into other mounts; print allocated blocks instead of apparent size |
| `--yes`, `-y` | `update` | Skip the prompt |
| `--json FILE` | all but `schema` | Also write the result as JSON to FILE, which must end in `.json`. The report commands and `update` write the whole scan, whatever `--top`, `--category`, and the `-only` flags printed |
| `-o`, `--output MODE` | all | `auto` (default), `text`, or `json`. `auto` is text on a terminal and the `--json` document when stdout is not one |
| `--no-color` | all | No ANSI color; so do a non-empty `NO_COLOR` and `TERM=dumb` |
| `--version` (`-v`), `--help` (`-h`) | all | Print and exit |

"Scan commands" are `report`, `leftovers`, `stale`, `outdated`, and `packages`. A flag on a command it does not belong to is a usage error rather than ignored, so `appattic stale --top 5` exits 2. `--help` and `--version` win over any usage error on the line, and `--help` wins over `--version`. `--` ends the options, so `appattic disk -- -backup` reads `-backup` as the PATH; otherwise a `disk` PATH must contain a `/` or be `.` or `..`, so `appattic disk REPORT` is a usage error rather than a walk of a missing directory.

Progress goes to stderr; reports, `--dry-run` scripts, and command results go to stdout. When stdout carries the JSON document, a `--dry-run` script goes to stderr instead. Exit codes: 0 success; 1 the run failed or an update was cancelled; 2 a usage error, a bad `disk` root, an `update` with no terminal and no `--yes`, or a malformed `settings.json`.

### Scan cache

The scan commands reuse the last scan while it is current: under 24 hours old and the inventory fingerprint unchanged. `--fresh` scans now. `update` always scans live and drops the cache once its script has run, whether it succeeded or failed. A scan in which a check ran and failed (network, a dead remote, a locked `dpkg`) is marked incomplete and not saved, so a failure is never served later as "up to date". Missing package managers are skipped. The snapshot lists every app and leftover path under your home, so a stale or undecodable one is deleted, and a file over 256 MB is never read. `appattic erase` deletes it on demand, before any settings are read, so it works on a machine whose `settings.json` no longer parses.

### Settings

One `settings.json` serves the CLI and both windows:

- Linux: `$XDG_DATA_HOME/appattic/settings.json` (default `~/.local/share/appattic/settings.json`)
- macOS: `~/Library/Application Support/AppAttic/settings.json`

```json
{
  "confirmDelete": true,
  "ignoredLeftoverPaths": [],
  "includeSystem": false
}
```

[`settings.json.example`](settings.json.example) holds those three keys at their defaults; any other key is rejected rather than ignored, so a misspelling fails loud.

- `includeSystem` (default false) puts OS system apps in the stale list. `--include-system` turns it on for one run; no flag turns it off.
- `confirmDelete` (default true) is read by the windows only.
- `ignoredLeftoverPaths` hides those leftovers everywhere. Each entry is the full path a report prints; a relative, `~`, or trailing-slash entry would match nothing, so the file is rejected with that entry named.

A missing file means the defaults. A malformed one is an error: the CLI exits 2, and a window shows the path and leaves the file alone until you save. A changed save attempts to keep the previous file as `settings.json.bak`; an unchanged save leaves the backup alone. Swift backup failures do not stop the save. `appattic restore` validates the backup before restoring it and preserves readable, nonempty differing current bytes as `settings.json.bad`. A later restore can overwrite that recovery copy. Like `erase`, it reads no current settings first. [`docs/runbooks/state-recovery.md`](docs/runbooks/state-recovery.md) is the full procedure.

The Linux window once kept its settings in `$XDG_CONFIG_HOME/AppAttic/AppAttic.conf`. On a first start with no `settings.json` it copies them over and deletes the old file; a value it cannot carry over stops the migration with the key and the file named, and both files stay as they were until you fix or delete the old one.

`appattic config` is how to check a setting that looks ignored. It prints the settings file, each value and the layer it came from, every ignored path in full, the backup files, the XDG roots, and every environment switch the app reads with its effect. Nothing is redacted, so read it before pasting it anywhere. `--json FILE` gives a file to diff between machines:

```bash
appattic config
appattic config --include-system --json config.json
```

```
settings file: /home/u/.local/share/appattic/settings.json
includeSystem: false [default]
confirmDelete: true
ignoredLeftoverPaths: 0
scan cache: /home/u/.local/share/appattic/last-scan.json
settings backup: /home/u/.local/share/appattic/settings.json.bak (missing)
settings replaced by a restore: /home/u/.local/share/appattic/settings.json.bad (missing)
XDG_DATA_HOME: /home/u/.local/share
XDG_CONFIG_HOME: /home/u/.config
XDG_CACHE_HOME: /home/u/.cache
XDG_STATE_HOME: /home/u/.local/state
XDG_DATA_DIRS: /usr/local/share:/usr/share
XDG_RUNTIME_DIR: /home/u/.gvfs
NO_COLOR: unset [colors on a tty]
TERM: unset [not set]
COLORFGBG: unset [light status colors]
APPATTIC_PAGE: unset [overview]
FLATPAK_ID: unset [host run]
APPATTIC_HOST_EXEC_LIVE: unset [off: fixtures unless the platform forces them]
APPATTIC_HOST_EXEC_FIXTURE: unset [off: live package queries]
APPATTIC_CORE_OUT: unset [searched next to the binary]
ANDROID_HOME: unset [the default SDK directories only]
ANDROID_SDK_ROOT: unset [the default SDK directories only]
LANG: unset [the base English app names]
```

### Environment

On/off switches read `1`, `true`, `yes`, and `on` as on and anything else as off. Build-time variables are in [CONTRIBUTING.md](CONTRIBUTING.md#build-time-variables).

| Variable | Read by | Effect |
|---|---|---|
| `APPATTIC_CORE_OUT` | Linux window | Absolute directory holding `appattic_core.wasm` and the plugins; the AppImage sets it. Empty or relative is ignored, and the directory next to the binary is searched |
| `APPATTIC_HOST_EXEC_LIVE` | Linux window, core host | On: the core's allowlisted package queries always run against the real binaries, overriding `APPATTIC_HOST_EXEC_FIXTURE` and the macOS fixture default |
| `APPATTIC_HOST_EXEC_FIXTURE` | Linux window, core host | On: serve the built-in fixtures instead of live queries. A non-macOS host runs live by default; a macOS host uses fixtures unless `APPATTIC_HOST_EXEC_LIVE` is on |
| `APPATTIC_PAGE` | windows | Start page: `overview` (default), `leftovers`, `stale`, `outdated`, `packages`, `disk`, `settings`. An unknown name is reported on stderr and opens the overview |
| `NO_COLOR` | CLI | Non-empty disables ANSI color |
| `TERM` | CLI | `dumb` disables ANSI color |
| `COLORFGBG` | CLI | Terminal `fg;bg`, picks the light or dark status colors. Unset uses the light set |
| `XDG_DATA_HOME` | Linux | Holds `appattic/settings.json`, `last-scan.json`, and user desktop entries; scanned for leftovers |
| `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` | Linux | Scanned for leftovers; the config root also for usage history |
| `XDG_DATA_DIRS` | Linux | Colon-separated roots searched for desktop entries. Relative entries are dropped; an empty result uses `/usr/local/share:/usr/share` |
| `XDG_RUNTIME_DIR` | Linux window | Session runtime root, for the `gvfs` directory the network-folder scan opens. Falls back to `~/.gvfs` |
| `ANDROID_HOME`, `ANDROID_SDK_ROOT` | CLI, macOS window | Android SDK root treated as a user tool directory, `ANDROID_HOME` first. A value with no `emulator`, `platform-tools`, `cmdline-tools`, or `platforms` inside is ignored, and the default SDK directories are searched |
| `LANG` | CLI, macOS window | Locale whose `.lproj` the macOS app-name lookup reads. Unset, empty, or encoding-only uses the base English names |
| `FLATPAK_ID` | Linux window, core host | Non-empty means sandboxed: plugin tags and package queries go through `/run/host` and `flatpak-spawn --host` |
| `HOME` | all | Fallback for every XDG root, and the Linux window's home-dot scan. The Swift side reads the home directory from the user database instead, so the two can disagree |
| `PATH` | all | Scan queries search user bin dirs such as `~/.local/bin` first, and the core host passes it to allowlisted queries. A script the CLI or macOS window generates never inherits it: it runs with the fixed `/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`. The Linux window runs its scripts with the inherited `PATH`, the user bin dirs (`~/.local/bin`, `~/bin`, `~/.cargo/bin`, ...) prepended |
| `USER`, `LOGNAME` | CLI, macOS window | Account name for telling your own paths from another account's; `USER` first |
| `HOMEBREW_NO_AUTO_UPDATE` | Homebrew subprocesses | Swift scan queries set this to `1` for `brew`. Action scripts and Qt queries can inherit the caller's value |
| `QT_QPA_PLATFORM` | Linux window | Qt platform plugin. The window picks `offscreen` itself only when no display variable is set and no platform was requested |

Empty or relative XDG paths are ignored per the XDG Base Directory specification, and a trailing separator is dropped, so `XDG_CONFIG_HOME=/srv/config/` and `/srv/config` name the same root everywhere.

## Native windows

`./run.sh --ui` opens the window: `AppAttic.app` or `AppAtticUI` on macOS (also `open AppAttic.app`), `appattic-qt` on Linux, preferring `ui/linux-qt/build-release/` over `ui/linux-qt/build/`. `man appattic-qt` (`packaging/appattic-qt.1`) documents the Linux window's options and environment.

The sidebar has Overview, Leftovers, Stale Apps, Outdated, Packages, Disk Usage, and Settings. The macOS window shows a saved scan under 24 hours old at once, and a background fingerprint check rescans when apps, package managers, tools, Steam/CrossOver, or leftovers changed. The Linux window always scans live. In both, a run that removes leftovers, updates packages, or marks packages manual drops the shared saved scan and rescans. Ticked rows survive a background refresh while they are still present.

Ignore a leftover from its inspector to hide it on later scans; the Linux Settings page lists the hidden paths, and double-clicking one brings it back. Settings also holds confirm-before-running and, on macOS, include system apps. The Linux window does not scan installed system apps.

## Scan library

`AppAtticScan` is the Foundation-only library behind the CLI and the macOS window:

```swift
import AppAtticScan

let data = runFullScan { message in
    print(message)
}
let leftovers = visibleOrphanedLeftovers(data.leftovers, ignoring: [])
for item in leftovers where item.leftoverStatus == .shadow {
    print(item.path, "hides", item.shadows ?? "")
}
try writeScanCache(
    ScanCacheFile(fingerprint: scanFingerprint(), includeSystem: false, data: data)
)
if let err = parseCLIArguments(["--top", "-1"]).parseError {
    print(err)
}
```

Entry points, in the order a caller reaches them (`PublicAPITests` compiles each against the public API):

| Call | Gives you |
|---|---|
| `runFullScan(includeSystem:now:clock:progress:)` | `ScanData` from a live scan. `progress` is called with each status line, serialized but on collector worker threads, so it needs its own lock and must not start a scan. One scan runs at a time per process |
| `resolveScan(includeSystem:fresh:forceLive:cacheURL:now:fingerprintFn:liveScan:)` | `ResolvedScan`: the cached scan while current, else a live scan and a cache write. `cacheWriteFailure` says why a live scan was not kept |
| `scanResult(from:ignoringLeftovers:now:)` | `ScanResult`, the grouped and filtered view every report is built from |
| `exportedScanData(from:ignoringLeftovers:fromCache:now:)` | The `ScanData` a `--json` report prints, totals recomputed from what is listed |
| `cleanupScript(_:category:top:)` / `updateScript(from:selectedIds:)` | The `sh` script for a cleanup (printed for review only) or a named upgrade (what CLI `update` runs after its confirm) |
| `validateDiskRoot(_:)` / `scanDiskUsage(root:oneFileSystem:cancel:)` / `formatDiskTree(_:allocatedSize:top:depth:)` | Disk usage. `validateDiskRoot` throws `DiskRootError` before the walk; `cancel` is polled during it and a cancel returns the partial tree |
| `listDiskVolumes(home:mountsText:)` | `DiskVolume` rows for the volume list |
| `readScanCache(from:)` / `writeScanCache(_:to:)` / `commitScanCache(includeSystem:data:before:after:to:)` | The scan cache. `readScanCache` throws `AppAtticIOError`; `loadScanCache` returns nil instead and deletes a file that fails to decode. `commitScanCache` returns `false` when the scan was deliberately not kept and throws when the write failed |
| `isScanCacheStale(_:includeSystem:fingerprint:now:maxAge:)` | Whether a cached scan still describes this machine, against `scanFingerprint()` |
| `loadSettings(from:)` / `saveSettings(_:to:)` / `effectiveIncludeSystem(cliFlag:settings:)` | `AppAtticSettings` from `settings.json`. A malformed file throws `SettingsError` and is never replaced by the defaults |
| `parseCLIArguments(_:)` | `CLIOptions` for argv without the program name. `parseError` carries the usage error, `error` its text; `cliHelpText` and `cliUsageHint` are the CLI's wording |

`AppAtticIOError`, `SettingsError`, and `DiskRootError` are the library's error types, with cases to switch on instead of matching messages. `runAndWait` is the exception: it rethrows whatever Foundation's `Process.run()` raises.

The JSON models keep wire strings (`status`, `tier`, `manager`) so a cache from a newer AppAttic still decodes. Read them through the typed accessors, which return nil for a value this build does not know rather than mistaking it for `keep`: `LeftoverItem.leftoverStatus` and `DataItem.leftoverStatus` (`LeftoverStatus`), `SoftwareItem.tierKind` and `Verdict.tierKind` (`StaleTier`), `OutdatedEntry.upgradableManager` (`UpgradableManager`). `StaleTier.selectable` is the REVIEW + REMOVE set; `outdatedIsUpdatable` and `PackageEntry.canMarkManual` answer the same questions as functions. `brewPackageMeta(from:)` returns `BrewPackageMeta` with `.summaries` and `.titles`, both `[String: String]`.

## Layout

| Path | Role |
|------|------|
| `Sources/AppAtticScan/` | The scan library, one file per feature (`Discover`, `Usage`, `Outdated`, `Packages`, `Recommend`, `Scan`, `DiskUsage`, `Cache`, `Cleanup`, `Settings`, ...), the leftovers cluster split by concern (`Leftovers`, `Identity`, `LeftoverText`, `LeftoverGroups`, `Overlays`), and support modules (`CLIParse`, `Process`, `Paths`, `ShellScript`, ...). `Version` is the one version declaration |
| `Sources/AppAtticCLI/` | The `appattic` command line |
| `Sources/AppAttic/` | The macOS window (SwiftCrossUI on AppKit) |
| `ui/linux-qt/` | The Linux window (C++ Qt 6 Widgets): window, findings, settings, WASM host (`corehost`), disk usage and charts, script runner, smoke checks |
| `core/` | Zig `wasm32` ABI marker module, one plugin per package manager or leftover root, and the C Wasmtime loader/host. See [`core/README.md`](core/README.md) |
| `tests/AppAtticScanTests/` | XCTest suite, with seeded mutation harnesses for the parsers of foreign text (argv, `COLORFGBG`, package-manager output, `settings.json`, ISO timestamps) |
| `benchmarks/AppAtticBench/` | The `appattic-bench` executable |
| `scripts/` | Build, test, lint, packaging, and release scripts. Each finds the project root itself, so run it by path from anywhere |
| `packaging/` | Desktop entry, AppStream metainfo (the release notes), man pages (`appattic.1`, `appattic-qt.1`), macOS `Info.plist` and icons, the Flatpak manifest, and the AUR recipes |
| [`DESIGN.md`](DESIGN.md) | Visual rules for both windows; [`docs/tmog-design-language.md`](docs/tmog-design-language.md) is the design language it adopts from, with source notes in [`docs/research/`](docs/research/) |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Toolchains, test and lint gates, packaging, releasing |
| `docs/specs/` | Architecture records, indexed in [`docs/specs/README.md`](docs/specs/README.md) |
| [`docs/privacy.md`](docs/privacy.md) | What a scan reads, stores, and sends, and how to erase it |
| [`SECURITY.md`](SECURITY.md), [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md) | What the code can delete or run, and the attack-surface model behind it |
| `docs/runbooks/` | [`state-recovery.md`](docs/runbooks/state-recovery.md) (getting settings and the snapshot back) and [`release-rollback.md`](docs/runbooks/release-rollback.md) (withdrawing a bad release) |
