# AppAttic

Local cleanup for the data an uninstalled app leaves behind, and a disk usage analyzer next to it. Native window on macOS and Linux, one CLI for both.

Nothing is deleted until you read the script it would run or confirm in the window. Move to Trash from Disk Usage asks first.

Today: one Foundation scan library (`AppAtticScan`), a Gtk-free CLI (`appattic`), a SwiftCrossUI AppKit window on macOS (`AppAtticUI`), and a C++ Qt 6 window on Linux (`ui/linux-qt`) that scans through the Zig WASM core. Every package manager and every Linux leftover root is a WASM plugin; the Qt shell keeps widgets, alerts, and running the confirmed script. Architecture record: [`docs/specs/2026-08-26-zig-wasm-core-design.md`](docs/specs/2026-08-26-zig-wasm-core-design.md). Linux UI is Qt 6, same toolkit as TMOG Linux. Qt-on-Linux is not claimed linked until `scripts/linux-qt-link.sh` runs on a real Linux host.

## What it reports

- **Leftovers.** User data whose owner app is gone (Application Support, caches, XDG dirs, and similar), plus user overlays (`~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.local/share/applications`) that hide a same-named packaged file. Overlay rows use status `shadow`; cleanup removes the overlay only. Apple/system/toolchain dirs are not counted as reclaimable.
- **Stale.** Installed apps and brew formulas with weak or old usage. Last-used comes from Spotlight (macOS, including the inner executable), running processes, prefs mtime, data-dir mtime, Linux `recently-used.xbel`, and shell history for CLI tools. Unused is not the same as outdated.
- **Outdated.** Newer version available from Homebrew, Flatpak, Snap, apt, pacman, AUR (paru/yay/pikaur), dnf/yum, zypper, or the App Store. Everything but the App Store and Snap can be upgraded from the Outdated page after you confirm, or with `appattic update` (`--dry-run` prints the script first, `--yes` skips the prompt when there is no terminal). Not a full distro upgrade (`apt upgrade`, `pacman -Syu`). App Store, Snap, and the language globals (npm, pip, RubyGems, Composer) stay report-only. Untrusted Homebrew casks are listed and are not updated.
- **Packages.** Distro orphans (nothing still needs them) and user-global language tools (`npm`/`pnpm`/`bun -g`, pipx, `uv tool`, top-level pip user-site, `~/.deno/bin`; the Zig core adds RubyGems and Composer globals, and container leftovers: dangling images, dangling volumes, exited containers). Debian/Ubuntu also lists `dpkg` config remnants (`rc`); the Zig `apt` plugin adds PPA source files, which have no Swift counterpart, so the Linux window lists them and the CLI does not. Remove and mark-as-manual are confirm + script only. Distro upgrades are never included.
- **Disk usage.** Folder and device sizes with a tree, allocated vs apparent size, ring and treemap charts (Linux Qt), scan home / folder / file system, open in the file manager, and move to Trash after confirm. Other file systems are not descended into unless you ask. Directory symlinks are not followed. `appattic disk [PATH]` prints the tree.

Tiers for installed software: KEEP (in use), REVIEW (idle, check first), REMOVE (stale and easy to reinstall). Default CLI cleanup scripts (`report --dry-run`, `leftovers --dry-run`, `stale --dry-run`) only include orphaned leftovers, PATH overlays, and REMOVE-tier items. `packages --dry-run` is a separate package script. The UI can also uninstall REVIEW-tier apps you opt into.

## CLI

Swift 5.10.1 (`.swift-version`). `./build.sh` uses `swift` on PATH, then `/opt/swift/usr/bin`, then `.deps/swift/usr/bin`. Missing Swift is a named error, not `swift: command not found`. `./build.sh --help` lists contributor commands.

```bash
./build.sh              # release
./build.sh debug
./run.sh report
./run.sh config
./run.sh leftovers
./run.sh stale
./run.sh outdated
./run.sh packages
./run.sh disk
./run.sh disk /var --top 20 --allocated
./run.sh erase
./run.sh update --dry-run
```

Equivalent without `run.sh` after a build:

```bash
.build/debug/appattic report
.build/release/appattic --version
```

Useful flags: `--json FILE` (the whole scan on the report commands; `disk` writes the disk tree and `config` and `erase` write what those commands reported. `--top`, `--category`, `--leftovers-only`, and `--stale-only` shape the printed report, not the file. FILE has to end in `.json`, so `appattic --json erase` is a usage error rather than a write to a file named `erase`), `--include-system`, `--fresh` (ignore the last-scan cache), `--dry-run` (print the script for `report`, `leftovers`, `stale`, `outdated`, `packages`, `update`), `--top N` (largest leftovers on `report` and `leftovers`, largest entries per folder on `disk`), `--category CAT` (repeatable, `report` and `leftovers`; a value that names a command is refused, so `appattic --category erase` reports a missing value and still reads `erase` as the command), `--leftovers-only` and `--stale-only` (on `report`), `--all-file-systems` and `--allocated` (on `disk`), `--no-color`, `--yes` (`-y`, `update` only), `--version` (`-v`), `--help` (`-h`, also spelled `appattic help`). Progress and status (including JSON written to FILE) go to stderr; reports, `--dry-run` scripts, and what each command reports (`config`, `disk`, `erase`) go to stdout, so every command stays pipeable. Exit 0 on success, 1 when the run failed or an update was cancelled, 2 on a usage error, a `disk` root that is missing or is not a directory, an `update` with no terminal and no `--yes`, or a malformed `settings.json`.

A `disk` PATH is a path: it carries a separator, it is `.` or `..`, or it is a name that starts with a dash and came behind `--`. A bare word where a root belongs (`appattic disk REPORT`) is a usage error rather than a walk of a root that does not exist, and an empty argument is a usage error wherever it appears.

A flag that names the commands it belongs to (`--yes` on `update`, `--allocated` and `--all-file-systems` on `disk`, `--leftovers-only` and `--stale-only` on `report`, `--top` on `report`, `leftovers`, `disk`, `--category` on `report` and `leftovers`, `--include-system` on the scan commands and `config`, `--fresh` and `--dry-run` on the scan commands) is a usage error on every other command, so `appattic report --allocated`, `appattic disk --dry-run`, and `appattic stale --top 5` fail instead of printing output that ignored them. `--help` wins over a usage error anywhere on the line, so `appattic --nope --help` still prints the help; with several bad tokens, the first one is the error reported.

`--` ends the options, so a `disk` path that starts with a dash is reachable: `appattic disk -- -backup`.

`appattic config` scans nothing. It prints the settings file this machine resolved, whether it exists, every setting value with the layer it came from, and the paths the XDG variables resolved to. Use it to tell a wrong value from a wrong path, and `--json FILE` to diff two machines:

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

Each ignored path is listed under its count, one per line, so a wrong entry is visible rather than a leftover that quietly never hides. The environment switches a run reads are listed the same way, each with the effect its value has and `unset` when it is not set, so a diff of two machines shows an override that is set as well as one that is not.

`appattic erase` deletes the scan snapshot AppAttic saved, whatever its age, and reads nothing first to decide. The snapshot is a full list of the paths under your home directory, so this is the command that takes that copy off the disk. It runs before settings are read, so it works on a machine whose `settings.json` no longer parses, and it reports on stdout whether a snapshot was there (`appattic erase --json FILE` writes the same as JSON). It does not touch `settings.json`, which holds only your own settings and the paths you chose to ignore.

`appattic update` asks for confirmation on a terminal. With stdin redirected (cron, CI, a pipeline) it stops with exit 2 unless you pass `--yes`, so an unattended upgrade is always something you asked for:

```bash
appattic update --dry-run   # print the script, run nothing
appattic update --yes       # unattended, from a script or timer
```

Settings live in `settings.json` next to the scan cache (same file for CLI, macOS UI, and Linux Qt):

- Linux: `$XDG_DATA_HOME/appattic/settings.json` (default `~/.local/share/appattic/settings.json`)
- macOS: `~/Library/Application Support/AppAttic/settings.json`

```json
{
  "confirmDelete": true,
  "ignoredLeftoverPaths": [],
  "includeSystem": false
}
```

`includeSystem` defaults to false (OS system apps stay out of the stale list). The CLI also reads it; `--include-system` turns it on for that run. There is no flag to turn it off when the file already has `true`. `confirmDelete` defaults to true and is UI-only. `ignoredLeftoverPaths` hides those leftovers in both the UI and CLI. Each entry is the full path a report prints: a relative one, a `~` one, or one with a trailing slash matches nothing, so the file is rejected with the offending entry named rather than storing a setting that does nothing. A missing file uses those defaults. A malformed file is an error: the CLI exits 2, the UI shows the path and does not overwrite the file until you save settings. `appattic config` prints the file it resolved and the values in force, which is how you check a setting that looks ignored.

The Linux window used to keep its settings in `$XDG_CONFIG_HOME/AppAttic/AppAttic.conf` (a `QSettings` file) and copies them into `settings.json` the first time it starts with no `settings.json`. A value in that old file that is neither true nor false, or an `ignoredLeftovers` entry that is not a full path, is not carried over: the window opens with no settings, names the key and the old file, and leaves both files alone, because writing the defaults would overwrite a value you wrote. Edit that old file (or delete it to start from the defaults) and start the window again; saving settings inside the window does not clear this. Reading that old file narrows its mode to `0600` (group and other lose read and write on it): its `ignoredLeftovers` list is full paths under your own home, and `QSettings` wrote the file readable by group and other. A migration that lands in `settings.json` deletes the old file, so the paths are not left in a second copy that nothing opens; a migration that could not be written leaves it, because then it is the only copy.

Environment:

| Variable | Used by | Role |
|---|---|---|
| `APPATTIC_CORE_OUT` | Linux Qt | Absolute directory of `appattic_core.wasm` and plugins. AppImage sets this. Set but empty, padded, or relative is ignored and the directory is searched next to the binary, the rule the XDG variables below follow. |
| `APPATTIC_HOST_EXEC_LIVE` | Linux Qt | `1` runs the core's allowlisted package queries against the real binaries instead of the built-in fixtures. Off by default, and read as off for any value other than `1`, `true`, `yes`, or `on`. |
| `APPATTIC_HOST_EXEC_FIXTURE` | Linux Qt | `1` serves the built-in fixtures on non-macOS hosts. Same accepted values as above. macOS uses fixtures either way. |
| `APPATTIC_PAGE` | UI | Initial sidebar: `overview` (default), `leftovers`, `stale`, `outdated`, `packages`, `disk`, `settings`. An unset or empty value opens the overview; an unknown name is reported on stderr and also opens the overview. |
| `NO_COLOR` | CLI | Disable ANSI color when set to a non-empty value. Set but empty is not a disable. |
| `TERM` | CLI | `dumb` disables ANSI color, the same as `NO_COLOR` and `--no-color`. Any other value changes nothing. |
| `COLORFGBG` | CLI | Terminal background as `fg;bg`. Picks the light or dark status colors; unset uses the light set, which is the readable one on a white background. |
| `XDG_DATA_HOME` | Linux | Absolute data root; parent of `appattic/settings.json`, `last-scan.json`, and user desktop entries. The Linux window scans it for leftovers too. |
| `XDG_CONFIG_HOME` | Linux | Absolute configuration root scanned for leftovers and usage history, by the CLI and by the Linux window. |
| `XDG_CACHE_HOME` | Linux | Absolute cache root scanned for leftovers, by the CLI and by the Linux window. |
| `XDG_STATE_HOME` | Linux | Absolute state root scanned for leftovers, by the CLI and by the Linux window. |
| `XDG_DATA_DIRS` | Linux | Colon-separated absolute data roots searched for desktop entries. Unset, empty, or a list whose entries are all relative uses `/usr/local/share:/usr/share`; relative entries in a longer list are dropped, and `appattic config` prints the list that survives. |
| `XDG_RUNTIME_DIR` | Linux Qt | Runtime root of the session, read for the `gvfs` directory the network-folder scan opens at. Unset, empty, relative, or naming a root with no `gvfs` uses `~/.gvfs`. The CLI scans nothing with it; `appattic config` prints the root it resolves to. |
| `ANDROID_HOME` | CLI and Linux Qt | An Android SDK root the scan treats as a user tool directory. The first of `ANDROID_HOME` and `ANDROID_SDK_ROOT` that holds a real SDK (one with `emulator`, `platform-tools`, `cmdline-tools`, or `platforms` in it) is the root in force; a value that names no such directory is read as unset, and the fixed default roots are searched instead. |
| `ANDROID_SDK_ROOT` | CLI and Linux Qt | The other spelling of the same Android SDK root, searched after `ANDROID_HOME`. A value here that holds no SDK is reported by `appattic config` as ignored rather than as the root in force. |
| `LANG` | CLI and macOS UI | The locale whose `.lproj` directory the macOS app-name lookup reads for an app's localized name. Unset, empty, or a value that is only an encoding opens the base English names. `appattic config` prints the locale it resolved to, so a diff of two machines shows why the same app is named differently. |
| `FLATPAK_ID` | Linux Qt and the core host | Set by Flatpak. Any non-empty value means the app is sandboxed, so plugin tags and package-manager queries go through `/run/host` and `flatpak-spawn --host`. Unset or empty is a normal host run. |

Per the XDG Base Directory specification, empty or relative XDG paths are ignored and the standard user defaults are used. A trailing separator is dropped from a root that ends in one, so `XDG_CONFIG_HOME=/srv/config/` and `XDG_CONFIG_HOME=/srv/config` name the same directory to the CLI, to the Linux window, and to the core host.

`report`, `leftovers`, `stale`, `outdated`, and `packages` reuse the last scan when it is still current. Pass `--fresh` to scan now. `update` always scans live and drops the last-scan cache after a successful upgrade. A scan in which an update or package-listing check ran and failed is not saved, so a failed check is retried on the next run instead of being served as "up to date" or "no unused packages" for a day. The cache is a full inventory of the account's app and leftover paths, so a snapshot past the 24h reuse bound is deleted by the next run instead of being kept once no run would serve it, and a snapshot that does not decode is deleted on the spot. A file past 256 MB is not a snapshot and is not read into memory.

Linux CLI does not need Qt. Headless `report` works without a display.

Scan library (`AppAtticScan`):

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

Entry points, in the order a caller reaches them:

| Call | Gives you |
|---|---|
| `runFullScan(includeSystem:now:clock:progress:)` | `ScanData` from a live scan. `progress` is called with each status line, on collector worker threads and serialized, so it needs its own lock and must not start a scan. One scan runs at a time per process. |
| `resolveScan(includeSystem:fresh:forceLive:cacheURL:now:fingerprintFn:liveScan:)` | `ResolvedScan`: the last scan when it is still current, a live scan and a cache write when it is not. `cacheWriteFailure` says why a live scan was not kept. |
| `scanResult(from:ignoringLeftovers:now:)` | `ScanResult`, the grouped and filtered view every report is built from. |
| `exportedScanData(from:ignoringLeftovers:fromCache:now:)` | The `ScanData` a `--json` report prints, with totals recomputed from what is listed. |
| `cleanupScript(_:category:top:)` / `updateScript(from:selectedIds:)` | The `sh` script for a cleanup or a named upgrade. A cleanup script is only printed, for review. `updateScript` is what CLI `update` runs, after its confirmation, and the cache is dropped once it succeeds. |
| `validateDiskRoot(_:)` / `scanDiskUsage(root:oneFileSystem:cancel:)` / `formatDiskTree(_:allocatedSize:top:depth:)` | Disk usage. `validateDiskRoot` throws `DiskRootError` for a missing path or a file, so the failure is catchable before the walk starts. `cancel` is polled during the walk and a cancel returns the partial tree. |
| `listDiskVolumes(home:mountsText:)` | `DiskVolume` rows for the volume list. |
| `readScanCache(from:)` / `writeScanCache(_:to:)` / `commitScanCache(includeSystem:data:before:after:to:)` | The scan cache. `readScanCache` throws `AppAtticIOError`; `loadScanCache` returns nil instead, and deletes a file that fails to decode rather than re-reading it on every run. `commitScanCache` returns `false` when the scan was deliberately not kept, and throws when the write itself failed. |
| `isScanCacheStale(_:includeSystem:fingerprint:now:maxAge:)` | Whether a cached scan still describes this machine. `scanFingerprint()` is the stamp to compare it against. |
| `loadSettings(from:)` / `saveSettings(_:to:)` / `effectiveIncludeSystem(cliFlag:settings:)` | `AppAtticSettings`, from `settings.json` next to the cache. A malformed file throws `SettingsError`; it is never silently replaced by the defaults. |
| `parseCLIArguments(_:)` | `CLIOptions` for an argv array without the leading program name. `parseError` carries the usage error, `error` its text, and `cliHelpText` / `cliUsageHint` the wording the CLI prints. |

`AppAtticIOError` (cache), `SettingsError` (settings), and `DiskRootError` (disk root) are the library's own error types, each an `Error` with cases a caller can switch on instead of matching a message. `runAndWait` is the exception: it rethrows whatever Foundation's `Process.run()` raises, so wrap it for that one.

Wire strings stay on the JSON models (`status`, `tier`, `manager`) so a cache from a newer AppAttic still decodes. Read them through the typed accessors instead of comparing raw strings: `LeftoverItem.leftoverStatus` and `DataItem.leftoverStatus` (`LeftoverStatus`), `SoftwareItem.tierKind` and `Verdict.tierKind` (`StaleTier`), `OutdatedEntry.upgradableManager` (`UpgradableManager`). `StaleTier.selectable` is the REVIEW + REMOVE set, the raw-value form of the internal `selectableCleanupTiers`; `outdatedIsUpdatable` and `PackageEntry.canMarkManual` are the same answers in function form. Each accessor returns an optional when the stored value is not one this build knows, so an unknown tier is not mistaken for `keep`. `brewPackageMeta(from:)` names its two maps (`BrewPackageMeta.summaries` and `.titles`, both `[String: String]`). The positional-tuple `brewPackageMeta(_:)` was deprecated in 2.0.0 and removed in 3.0.0, because the order was the only thing telling its two maps apart.

Tests (same flags as `.github/workflows/linux.yml`):

```bash
bash scripts/check.sh
# fast: lint + Zig core tests + AppAtticScanTests + CLI debug build
bash scripts/check.sh --qt
# full Linux CI parity, including Qt/WASM proof
bash scripts/check.sh --core
# no Swift needed: lint + Zig core tests + reproducible artifacts.
# Editing core/src/, core/host/ or packaging? Start here. The Swift steps
# do not run, and the last line of the run says so.

bash scripts/verify-reproducible.sh                          # two builds, diffed
swift build -c debug --product appattic --disable-automatic-resolution
bash scripts/test.sh                                           # AppAtticScanTests
bash scripts/test.sh DiskSizeTests                             # one class
bash scripts/test.sh DiskSizeTests/testParseDuKBRequiresLeadingInteger   # one test
./core/build.sh test brew.zig                                  # one Zig module
./core/build.sh test jsonbuf.zig isSafeIdent               # one Zig test (from the module that declares it)
./core/build.sh test-core                                      # whole Zig core, no wasmtime/Qt
bash scripts/lint.sh
```

`scripts/test.sh` is the `swift test` to use: it carries `--disable-automatic-resolution`, the toolchain check against `.swift-version`, and, on macOS, `APPATTIC_NO_MAC_UI=1`. The CI jobs call it, so a local run and a workflow run are the same run. `swift test` builds every target in the package, and `AppAtticUI` needs a Swift 6 compiler while `.swift-version` pins 5.10.1, so a bare `swift test` fails to build on the pinned toolchain.

`swift test` and `swift build` need unrestricted permissions in sandboxed environments.

`scripts/verify-reproducible.sh` builds the WASM core and the C host twice, from two differently named directories under a different timezone and `SOURCE_DATE_EPOCH`, and fails unless the artifacts are byte-identical. It is what keeps the build's reproducibility claims honest: a build path, host timestamp or locale that reaches an output shows up here as a diff, not as a surprise in a release. `scripts/check.sh` runs it on every pass, and the `test` job in `.github/workflows/linux.yml` runs it as a blocking step, so a release is never built from a tree that stopped being reproducible.

`scripts/lint.sh` runs the gate: shellcheck and yamllint over the whole tree (both discovered, so a new file joins without editing the script), the C host compiled warnings-as-errors under every compiler on `PATH` and rerun under ASan and UBSan and under both static analyzers (`-fanalyzer` and `clang --analyze`, which reach different paths and so catch different defects), the packaging files cross-checked against each other, `zig fmt --check`, and a commit message that credits an AI tool rejected. Each optional check reports which tool is missing and how to install it, so a host that lacks one is never a silent pass; CI installs the full set, so it never skips there. `bash scripts/lint.sh --help` lists the checks, and Linux CI runs that script as a blocking job. `core/build.sh` also fails if Zig sources are unformatted or `hostexec_test` warns. The Qt shell is covered by its own build rather than by `lint.sh`, which has no Qt to compile against: `ui/linux-qt/CMakeLists.txt` gives every C++ source warnings-as-errors under `-Wall -Wextra -Wformat=2 -Wundef -Wcast-qual -Wnon-virtual-dtor -Woverloaded-virtual`, and a source added to that directory without joining the list fails the configure. `scripts/check.sh` is the fast lint + Zig core + test + CLI loop; `scripts/check.sh --qt` reproduces the full Linux CI verification. The Zig step needs only `zig` at `.zig-version`; without it `scripts/check.sh` says so and skips, and CI installs the toolchain first so the skip cannot pass there.

## Native UI

```bash
./build.sh              # release
./build.sh debug
./run.sh --ui
```

macOS: builds `AppAttic.app` (ad-hoc codesign) when `AppAtticUI` compiles, otherwise the CLI only and says so. `AppAtticUI` needs swift-cross-ui 0.2.1, which needs a Swift 6 compiler, and `.swift-version` pins 5.10.1. Launch with `open AppAttic.app` or `swift run AppAtticUI`.
SwiftPM names the UI product `AppAtticUI` so it does not collide with `appattic` on a case-insensitive volume.

Linux: UI is Qt 6 Widgets. Install headers with `./scripts/linux-deps.sh` (optional `--install` and `--install-wasmtime`). Debian/Ubuntu: `qt6-base-dev`. Fedora: `qt6-qtbase-devel`. Arch: `qt6-base`. openSUSE: `qt6-base-devel`. No `.app` bundle. `./build.sh` still builds the CLI if Qt is missing. Launch the window with `./run.sh --ui`.

You cannot cross-compile the Qt UI from macOS and call that a Linux link. Build on the Linux machine you will run, matching that distro. An Ubuntu-built binary is not assumed to start on Arch (glibc differs). Homebrew Qt on macOS is not Linux.

Qt discovery looks in the Debian multiarch directory, `/usr/lib`, and `/usr/lib64`, so the same commands work on Fedora and openSUSE, where Qt 6 installs under `lib64`. The Qt window needs glibc 2.28 or newer because Qt 6 does; the window itself uses `statx` (`ui/linux-qt/diskusage.cpp`) only where the libc has the wrapper, and falls back to `fstatat` on an older glibc. The CLI and `AppAtticScan` are pure Swift and link no C host, so they carry only the floor Swift itself has. musl is not a target: the AppImage, the Flatpak (`org.kde.Platform`), and `core/host` all build against glibc.

```bash
./scripts/linux-deps.sh              # preflight: what is present, what is missing
./scripts/linux-deps.sh --install    # Qt 6 headers, cmake, ninja, clang (root)
./scripts/linux-deps.sh --install-wasmtime
./scripts/linux-deps.sh --install-zig
./scripts/linux-deps.sh --install-shellcheck   # needed by scripts/lint.sh
# Arch has no Swift in extra. AUR: swift-bin. Or:
./scripts/linux-deps.sh --install-swift   # Swift 5.10.1 into /opt/swift (or .deps/swift without root)
export PATH="/opt/swift/usr/bin:$PATH"    # or: export PATH="$PWD/.deps/swift/usr/bin:$PATH"
./build.sh debug
# or only the UI:
bash scripts/linux-qt-link.sh            # Debug, into ui/linux-qt/build
bash scripts/linux-qt-link.sh release    # Release, into ui/linux-qt/build-release
bash scripts/verify-qt-link.sh           # assert the link proof; CI and both images run this too
bash scripts/verify-qt-link.sh release   # assert the Release link proof instead
```

`./build.sh [release|debug]` links the Qt UI in the same config it gives the CLI: `release` builds `ui/linux-qt/build-release`, `debug` builds `ui/linux-qt/build`. Each config keeps its own tree, so a release link never picks up a stale Debug binary. `./run.sh --ui` prefers `build-release/` and falls back to `build/`.

AppImage (portable Qt UI, no system Qt at runtime):

```bash
bash scripts/linux-deps.sh --install
bash scripts/linux-deps.sh --install-wasmtime
bash scripts/linux-appimage.sh
# dist/AppAttic-x86_64.AppImage  (or aarch64 on arm64 hosts)
```

`VERSION` is the current git tag without a leading `v`, or, on an untagged checkout, the version declared in `Sources/AppAtticScan/Version.swift`. That file is the only declaration: `ui/linux-qt/CMakeLists.txt` reads it with `string(REGEX MATCH)` rather than copying it, and the copies that have to keep step are the newest `<release>` in `packaging/org.appattic.AppAttic.metainfo.xml`, `CFBundleShortVersionString` and `CFBundleVersion` in `packaging/Info.plist` (which `build.sh` copies into the macOS bundle unchanged), and the version headers in `packaging/appattic.1` and `packaging/appattic-qt.1`. `bash scripts/check-version.sh` is the one reader: it prints the declared version and fails when any copy disagrees, when the newest `<release>` has no date or no `<description>` (a release with no note is a silent release), when `CFBundleVersion` is not a build number, when CMake stops deriving, or when the declared version is a tag that already points at another commit (a released version is immutable). `bash scripts/check-version.sh --tag v2.0.0` also requires the tag to match. The release workflow runs the `--tag` form against the `v*` ref, on a full-history checkout so the immutability check can see the existing tags. It then runs `bash scripts/release-notes.sh v2.0.0`, which prints that release's AppStream `<description>` and exits 1 when there is none, and publishes it as the GitHub release body. The release page carries the note that ships in the package rather than a generated commit list, so the migration text a caller needs is on the page they download from. It runs `AppAtticScanTests` before it builds: the two workflows run in parallel on a tag push, so `linux.yml` passing does not stop the release on its own. The AppImage script then runs `--smoke` and fails if that does not print `SMOKE=ok`. Debug builds additionally take `--dev-check <table|stream|disk|shot>`: the CI gates and the offscreen page renders (`shot <dir>`). They are compiled out with `NDEBUG`, which makes a release binary reject the flag with exit 2 instead of opening the window.

Requires Qt 6 dev headers, zig, and wasmtime on the build host. The script downloads pinned linuxdeploy, linuxdeploy-plugin-qt, and appimagetool into `dist/.appimage-tools/` and checks SHA-256. WASM modules ship under `usr/share/appattic/`; `libwasmtime.so` ships under `usr/lib/`, reached from the binary as `$ORIGIN/../lib`. `appimagetool` embeds update information pointing at the release's `.zsync`, which the release workflow publishes beside the image, so a downloaded AppImage can check for a newer release with AppImageUpdate. It also writes `dist/AppAttic-<arch>.AppImage.sbom.json`, a CycloneDX 1.5 inventory of every pinned third-party artifact that went into the image: the downloaded tools, the `Package.resolved` pins, and the third-party files vendored in the tree (the Michroma title font, `ui/linux-qt/fonts/`, SIL OFL 1.1, which the Qt resource compiles into the binary and `cmake --install` ships its license beside). Regenerate it or check the pins yourself:

```bash
bash scripts/deps.sh check              # pins vs download URLs vs Flatpak sha256 and runtime branch, vendored files vs their hashes and licenses
bash scripts/deps.sh sbom out.json      # CycloneDX 1.5 inventory
bash scripts/deps.sh yamllint-version   # the yamllint pin lint.sh names when it is missing
```

`deps.sh check` also fails when a Flatpak manifest names no runtime, no `runtime-version`, or no SDK. The bundle carries the runtime, so an unnamed one is not a pin: without the branch, `flatpak-builder` resolves whatever the remote's default branch is and the bytes in the released artifact move with nothing in this tree changing. The runtime reaches the inventory as a component pinned by branch rather than by digest, and says so in `appattic:pinned-by`. Two things the inventory names but does not itemize, so a consumer reading it does not read more into it than it says: the runtime is one component for the whole KDE Platform, and the AppImage's Qt libraries are collected off the build host by `linuxdeploy-plugin-qt` and are not listed at all.

`scripts/lint.sh` runs `check`, so a version bump that leaves a pin, a URL, or a Flatpak `sha256:` behind fails the local gate.

Flatpak (Qt 6 from org.kde.Platform, host package-manager queries via `flatpak-spawn --host`):

```bash
# needs flatpak-builder; installs org.kde.Sdk//6.10 from Flathub if missing
bash scripts/linux-flatpak.sh
# dist/AppAttic.flatpak
flatpak run org.appattic.AppAttic
```

The sandbox gets `--filesystem=host:ro` so leftover and disk scans can see the machine. The grant is read-only on purpose: nothing the app does inside the sandbox writes to a host path, and the one action that does, "Move to Trash", goes through the file-manager portal. The generated cleanup and update scripts, which do remove host files, run under `flatpak-spawn --host`, outside the sandbox, so a narrower grant does not stop a cleanup you confirmed. Plugin tags look under `/run/host` when `FLATPAK_ID` is set, because the sandbox PATH has no host pacman or apt. Scan plugins still cannot run `rm` or distro upgrades through `host.exec`. Manifest: `packaging/flatpak/org.appattic.AppAttic.yml`. It carries no `version` of its own: the manifest flatpak-builder gets is stamped with `appAtticVersion`, so the bundle reports the release it was built from.

Container builds:

```bash
podman build -t appattic .
# Arch userland (Qt 6 from pacman, Swift tarball):
podman build -t appattic-arch -f Dockerfile.arch .
# or: docker build -t appattic .
```

Ubuntu image installs Qt 6, runs `AppAtticScanTests`, and links the CLI plus the Qt window. `Dockerfile.arch` does the same on Arch. GitHub Actions `.github/workflows/linux.yml` runs the same matrix as the images: Ubuntu 24.04, a `swift:5.10.1-jammy` container, and archlinux, plus lint and a macOS scan-library job.

Sidebar: Overview, Leftovers, Stale Apps, Outdated, Packages, Disk Usage, Settings. The last scan is shown immediately if one was saved and is under 24 hours old. AppAttic then checks its inventory fingerprint in the background and rescans if app, package-manager, tool, Steam/CrossOver, or leftover state changed. A run that removes leftovers, updates packages, or marks packages manual drops the saved scan and rescans. Checkmarks on leftovers, stale apps, outdated rows, and Packages rows survive a background refresh if those items are still present. Settings (confirm before running; on macOS, include system apps) and ignored leftover paths persist in `settings.json` (see above). The Linux window does not scan installed system apps. Ignore a leftover from its inspector to hide it on later scans. The Linux Settings page lists every hidden path, and double-clicking one shows that leftover in the list again. Include-in-cleanup uses the leftover list tickbox on Linux, the inspector toggle, and toolbar Select All.

## Layout

| Path | Role |
|------|------|
| `Sources/AppAtticScan/` | Discover, usage, brew, outdated, packages, recommend, full scan. One file per feature (`Discover`, `Usage`, `BrewInfo`, `Outdated`, `Packages`, `Recommend`, `Scan`, `DiskUsage`, `Cache`, `Cleanup`, `Settings`, `CrossOver`, `Steam`, `StartPage`, `Models`, `Errors`), with the leftovers cluster split by concern: `Leftovers` (scan, roots, item model), `Identity` (who owns a name), `LeftoverText` (labels, reasons, blurbs), `LeftoverGroups` (grouping and collapsing), `Overlays` (PATH dirs, broken links, shadows). Plus the shared support modules it is built on: `CLIParse` (argv and the `--help` text), `Process` (subprocess, `which`), `Paths` (XDG, identity, redaction), `DiskSize` (`du`, directory walks), `Dates`, `Format`, `Text`, `ShellScript` (quoting for generated `sh`), `FilePermissions`, `Concurrency`, `LineBytes` (the UTF-8 line primitives `Outdated` and `Packages` parse with), `Platform` (os-release, distro package manager), `JSONText` (the control-character scan that keeps a hand-edited state file from aborting the decoder), `Version` (the one version declaration) |
| `Sources/AppAtticCLI/` | `appattic` command line |
| `Sources/AppAttic/` | SwiftCrossUI app (AppKit on macOS) |
| `ui/linux-qt/` | C++ Qt 6 Widgets shell (Linux). The window (`main`), findings, settings, the WASM host paths (`corehost`), disk usage and its charts, script execution, and smoke are separate files |
| `tests/AppAtticScanTests/` | XCTest port of the old scanner cases, plus seeded mutation harnesses for the parsers that read foreign text: the CLI argv and `COLORFGBG`, package manager listings, `settings.json`, and ISO timestamps |
| `DESIGN.md` | Native UI visual rules |
| `docs/specs/` | Requirement and architecture records (index: [`docs/specs/README.md`](docs/specs/README.md)). The Zig WASM core record is accepted and implemented; the Swift scan port record is implemented and superseded, kept in `archive/` |
| `docs/privacy.md` | What a scan reads, what is stored and where, what reaches the network, and how to export or erase it |
| `docs/runbooks/state-recovery.md` | What AppAttic keeps on disk, which of it is rebuildable, and how to get `settings.json` and the scan snapshot back |
| `core/` | Zig `wasm32` scan core (loader + plugins + C Wasmtime embedder). The Linux window runs on it |
| `scripts/` | Contributor gates: `check.sh` (fast local loop), `test.sh`, `lint.sh`, the tool finders, and the packaging, AppImage, Flatpak and release steps. Every script finds the project root itself, so run it by path from anywhere |
| `packaging/` | Desktop entry, AppStream metainfo, man pages for `appattic` and `appattic-qt`, macOS `Info.plist` and icons, and the Flatpak manifest. `scripts/check-packaging.sh` is what keeps the copies in step |
| `benchmarks/AppAtticBench/` | The `appattic-bench` executable target, on the scan library |

## Notes

- Homebrew `outdated` is called without `--greedy`, so auto-updating casks are not flagged just because the bottle is older than the running app.
- An untrusted Homebrew cask is still listed on Outdated. Other formula and cask descriptions still load. AppAttic will not trust the tap. This is `AppAtticScan` behavior (the CLI and the macOS window); the Zig `brew` plugin does not read tap trust yet, so the Linux window lists every outdated cask.
- Named outdated upgrades (Homebrew, Flatpak, apt, pacman, AUR, dnf/yum, zypper) run from the Outdated page (confirm first) or `./run.sh update` (runs now; pass `--dry-run` to print the script). App Store and Snap stay report-only.
- Missing package managers are skipped. A check that ran and failed (network, dead remote, broken `brew outdated`, a locked `dpkg` blocking `apt-get -s autoremove`) does not fail the scan, but the scan is marked incomplete and the last-scan cache is not written, so a failed check is never served later as "up to date" or as "no unused packages".
- Review every path in a generated script before running it.
