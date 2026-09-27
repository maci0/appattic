# AppAttic

Local cleanup tool for leftover data from uninstalled apps, unused installed software, unused distro orphans and language globals, packages that have a newer version available, and a disk usage analyzer (folder sizes, devices, ring/treemap charts). Nothing is deleted until you review a script or confirm in the UI. Move to Trash from Disk Usage asks first.

macOS and Linux. Today: one Foundation scan library (`AppAtticScan`), a Gtk-free CLI (`appattic`), a SwiftCrossUI AppKit window on macOS (`AppAtticUI`), and a C++ Qt 6 window on Linux (`ui/linux-qt`) that scans through the Zig WASM core. Every package manager and every Linux leftover root is a WASM plugin; the Qt shell keeps widgets, alerts, and running the confirmed script. Architecture record: [`docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md`](docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md). Linux UI is Qt 6, same toolkit as TMOG Linux. Qt-on-Linux is not claimed linked until `scripts/linux-qt-link.sh` runs on a real Linux host.

## What it reports

- **Leftovers.** User data whose owner app is gone (Application Support, caches, XDG dirs, and similar), plus user overlays (`~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.local/share/applications`) that hide a same-named packaged file. Overlay rows use status `shadow`; cleanup removes the overlay only. Apple/system/toolchain dirs are not counted as reclaimable.
- **Stale.** Installed apps and brew formulas with weak or old usage. Last-used comes from Spotlight (macOS, including the inner executable), running processes, prefs mtime, data-dir mtime, Linux `recently-used.xbel`, and shell history for CLI tools. Unused is not the same as outdated.
- **Outdated.** Newer version available from Homebrew, Flatpak, Snap, apt, pacman, AUR (paru/yay/pikaur), dnf/yum, zypper, or the App Store. Everything but the App Store and Snap can be upgraded from the Outdated page after you confirm, or with `appattic update` (`--dry-run` prints the script first, `--yes` skips the prompt when there is no terminal). Not a full distro upgrade (`apt upgrade`, `pacman -Syu`). App Store, Snap, and the language globals (npm, pip, RubyGems, Composer) stay report-only. Untrusted Homebrew casks are listed and are not updated. Debian/Ubuntu also lists `dpkg` config remnants (`rc`) and PPA source files.
- **Packages.** Distro orphans (nothing still needs them) and user-global language tools (`npm`/`pnpm`/`bun -g`, pipx, `uv tool`, top-level pip user-site, `~/.deno/bin`; the Zig core adds RubyGems and Composer globals, and container leftovers: dangling images, dangling volumes, exited containers). Remove and mark-as-manual are confirm + script only. Distro upgrades are never included.
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
./run.sh update --dry-run
```

Equivalent without `run.sh` after a build:

```bash
.build/debug/appattic report
.build/release/appattic --version
```

Useful flags: `--json FILE`, `--include-system`, `--fresh` (ignore the last-scan cache), `--dry-run` (print the script for `report`, `leftovers`, `stale`, `outdated`, `packages`, `update`), `--top N` (largest leftovers on `report` and `leftovers`, largest entries per folder on `disk`), `--category CAT` (repeatable, `report` and `leftovers`), `--leftovers-only` and `--stale-only` (on `report`), `--all-file-systems` and `--allocated` (on `disk`), `--no-color`, `--yes` (`update` only), `--version` (`-v`), `--help` (`-h`, also spelled `appattic help`). Progress and status (including JSON written to FILE) go to stderr so reports and `--dry-run` scripts stay pipeable. Exit 0 on success, 1 when the run failed or an update was cancelled, 2 on a usage error or a malformed `settings.json`.

A flag that names the commands it belongs to (`--yes` on `update`, `--allocated` and `--all-file-systems` on `disk`, `--leftovers-only` and `--stale-only` on `report`, `--top` on `report`, `leftovers`, `disk`, `--category` on `report` and `leftovers`, `--include-system` and `--fresh` and `--dry-run` on the scan commands) is a usage error on every other command, so `appattic report --allocated`, `appattic disk --dry-run`, and `appattic stale --top 5` fail instead of printing output that ignored them. `--help` wins over a usage error anywhere on the line, so `appattic --nope --help` still prints the help; with several bad tokens, the first one is the error reported.

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
XDG_DATA_HOME: /home/u/.local/share
XDG_CONFIG_HOME: /home/u/.config
XDG_CACHE_HOME: /home/u/.cache
XDG_STATE_HOME: /home/u/.local/state
XDG_DATA_DIRS: /usr/local/share:/usr/share
```

Each ignored path is listed under its count, one per line, so a wrong entry is visible rather than a leftover that quietly never hides.

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

Environment:

| Variable | Used by | Role |
|---|---|---|
| `APPATTIC_CORE_OUT` | Linux Qt | Directory of `appattic_core.wasm` and plugins. AppImage sets this. |
| `APPATTIC_HOST_EXEC_LIVE` | Linux Qt | `1` runs the core's allowlisted package queries against the real binaries instead of the built-in fixtures. Off by default, and read as off for any value other than `1`, `true`, `yes`, or `on`. |
| `APPATTIC_HOST_EXEC_FIXTURE` | Linux Qt | `1` serves the built-in fixtures on non-macOS hosts. Same accepted values as above. macOS uses fixtures either way. |
| `APPATTIC_PAGE` | UI | Initial sidebar: `overview` (default), `leftovers`, `stale`, `outdated`, `packages`, `disk`, `settings`. An unset or empty value opens the overview; an unknown name is reported on stderr and also opens the overview. |
| `NO_COLOR` | CLI | Disable ANSI color when set to a non-empty value. Also `--no-color` or `TERM=dumb`. |
| `COLORFGBG` | CLI | Terminal background as `fg;bg`. Picks the light or dark status colors; unset uses the light set, which is the readable one on a white background. |
| `XDG_DATA_HOME` | Linux | Absolute data root; parent of `appattic/settings.json`, `last-scan.json`, and user desktop entries. |
| `XDG_CONFIG_HOME` | Linux | Absolute configuration root scanned for leftovers and usage history. |
| `XDG_CACHE_HOME` | Linux | Absolute cache root scanned for leftovers. |
| `XDG_STATE_HOME` | Linux | Absolute state root scanned for leftovers. |
| `XDG_DATA_DIRS` | Linux | Colon-separated absolute data roots searched for desktop entries. Unset or empty uses `/usr/local/share:/usr/share`; relative entries are skipped. |
| `FLATPAK_ID` | Linux Qt and the core host | Set by Flatpak. Any non-empty value means the app is sandboxed, so plugin tags and package-manager queries go through `/run/host` and `flatpak-spawn --host`. Unset or empty is a normal host run. |

Per the XDG Base Directory specification, empty or relative XDG paths are ignored and the standard user defaults are used.

`report`, `leftovers`, `stale`, `outdated`, and `packages` reuse the last scan when it is still current. Pass `--fresh` to scan now. `update` always scans live and drops the last-scan cache after a successful upgrade. A scan in which an update or package-listing check ran and failed is not saved, so a failed check is retried on the next run instead of being served as "up to date" or "no unused packages" for a day. The cache is a full inventory of the account's app and leftover paths, so a snapshot past the 24h reuse bound is deleted by the next run instead of being kept once no run would serve it.

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

Wire strings stay on the JSON models (`status`, `tier`, `manager`) so a cache from a newer AppAttic still decodes. Read them through the typed accessors instead of comparing raw strings: `LeftoverItem.leftoverStatus` and `DataItem.leftoverStatus` (`LeftoverStatus`), `SoftwareItem.tierKind` and `Verdict.tierKind` (`StaleTier`), `OutdatedEntry.upgradableManager` (`UpgradableManager`). `StaleTier.selectable` is the REVIEW + REMOVE set behind `selectableCleanupTiers`; `outdatedIsUpdatable` and `PackageEntry.canMarkManual` are the same answers in function form. Each accessor returns an optional when the stored value is not one this build knows, so an unknown tier is not mistaken for `keep`.

Tests (same flags as `.github/workflows/linux.yml`):

```bash
bash scripts/check.sh
# fast: lint + Zig core tests + AppAtticScanTests + CLI debug build
bash scripts/check.sh --qt
# full Linux CI parity, including Qt/WASM proof

bash scripts/verify-reproducible.sh                          # two builds, diffed
swift build --target AppAtticScan -c debug --disable-automatic-resolution
bash scripts/test.sh                                           # AppAtticScanTests
bash scripts/test.sh DiskSizeTests                             # one class
bash scripts/test.sh DiskSizeTests/testParseDuKBRequiresLeadingInteger   # one test
./core/build.sh test brew.zig                                  # one Zig plugin
./core/build.sh test-core                                      # whole Zig core, no wasmtime/Qt
bash scripts/lint.sh
```

`scripts/test.sh` is the `swift test` to use: it carries `--disable-automatic-resolution`, the toolchain check against `.swift-version`, and, on macOS, `APPATTIC_NO_MAC_UI=1`. The CI jobs call it, so a local run and a workflow run are the same run. `swift test` builds every target in the package, and `AppAtticUI` needs a Swift 6 compiler while `.swift-version` pins 5.10.1, so a bare `swift test` fails to build on the pinned toolchain.

`swift test` and `swift build` need unrestricted permissions in sandboxed environments.

`scripts/verify-reproducible.sh` builds the WASM core and the C host twice, from two differently named directories under a different timezone and `SOURCE_DATE_EPOCH`, and fails unless the artifacts are byte-identical. It is what keeps the build's reproducibility claims honest: a build path, host timestamp or locale that reaches an output shows up here as a diff, not as a surprise in a release. `scripts/check.sh` runs it on every pass.

`scripts/lint.sh` runs shellcheck on every `*.sh` in the tree (discovered, so a new script joins the gate without editing the script), yamllint in `--strict` mode on every `*.yml` and `*.yaml` in the tree (discovered the same way, so a new workflow or a `.yaml` extension joins the gate), checks that every version copy agrees, compiles every C file under `core/host` with warnings as errors under every compiler on `PATH`, so a diagnostic only one of them emits cannot merge unseen (`embed.c` needs the Wasmtime headers, so a host without them says which file went unchecked and how to install them; CI installs them, so it never skips there), reruns the C host suite under AddressSanitizer and UndefinedBehaviorSanitizer with `-fno-sanitize-recover` so a finding fails the run, runs `zig fmt --check` when `zig` is on PATH, and rejects any commit message that credits an AI tool (`Co-authored-by: Cursor` and friends): commit messages carry no tool attribution, and that check is what keeps it that way. Linux CI runs that script as a blocking job. `core/build.sh` also fails if Zig sources are unformatted or `hostexec_test` warns. `scripts/check.sh` is the fast lint + Zig core + test + CLI loop; `scripts/check.sh --qt` reproduces the full Linux CI verification. The Zig step needs only `zig` at `.zig-version`; without it `scripts/check.sh` says so and skips, and CI installs the toolchain first so the skip cannot pass there.

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

Qt discovery looks in the Debian multiarch directory, `/usr/lib`, and `/usr/lib64`, so the same commands work on Fedora and openSUSE, where Qt 6 installs under `lib64`. The Qt window needs glibc 2.28 or newer (`statx`, in `ui/linux-qt/diskusage.cpp`); the CLI and `AppAtticScan` are pure Swift and link no C host, so they carry only the floor Swift itself has. musl is not a target: the AppImage, the Flatpak (`org.kde.Platform`), and `core/host` all build against glibc.

```bash
./scripts/linux-deps.sh              # print Qt 6 + Wasmtime + Swift + shellcheck notes
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

`VERSION` is the current git tag without a leading `v`, or, on an untagged checkout, the version declared in `Sources/AppAtticScan/Version.swift`. That file is the only declaration: `ui/linux-qt/CMakeLists.txt` reads it with `string(REGEX MATCH)` rather than copying it, and the copies that have to keep step are the newest `<release>` in `packaging/org.appattic.AppAttic.metainfo.xml`, `CFBundleShortVersionString` and `CFBundleVersion` in `packaging/Info.plist` (which `build.sh` copies into the macOS bundle unchanged), and the version header in `packaging/appattic-qt.1`. `bash scripts/check-version.sh` is the one reader: it prints the declared version and fails when any copy disagrees, when the newest `<release>` has no date or no `<description>` (a release with no note is a silent release), when `CFBundleVersion` is not a build number, when CMake stops deriving, or when the declared version is a tag that already points at another commit (a released version is immutable). `bash scripts/check-version.sh --tag v2.0.0` also requires the tag to match. The release workflow runs the `--tag` form against the `v*` ref, on a full-history checkout so the immutability check can see the existing tags. It runs `AppAtticScanTests` before it builds: the two workflows run in parallel on a tag push, so `linux.yml` passing does not stop the release on its own. The AppImage script then runs `--smoke` and fails if that does not print `SMOKE=ok`. Debug builds additionally take `--dev-check <table|stream|disk|shot>`: the CI gates and the offscreen page renders (`shot <dir>`). They are compiled out with `NDEBUG`, which makes a release binary reject the flag with exit 2 instead of opening the window.

Requires Qt 6 dev headers, zig, and wasmtime on the build host. The script downloads pinned linuxdeploy, linuxdeploy-plugin-qt, and appimagetool into `dist/.appimage-tools/` and checks SHA-256. WASM modules ship under `usr/share/appattic/`; `libwasmtime.so` ships under `usr/lib/`, reached from the binary as `$ORIGIN/../lib`. `appimagetool` embeds update information pointing at the release's `.zsync`, which the release workflow publishes beside the image, so a downloaded AppImage can check for a newer release with AppImageUpdate. It also writes `dist/AppAttic-<arch>.AppImage.sbom.json`, a CycloneDX 1.5 inventory of every pinned third-party artifact that went into the image: the downloaded tools, the `Package.resolved` pins, and the third-party files vendored in the tree (the Michroma title font, `ui/linux-qt/fonts/`, SIL OFL 1.1, which the Qt resource compiles into the binary and `cmake --install` ships its license beside). Regenerate it or check the pins yourself:

```bash
bash scripts/deps.sh check              # pins vs download URLs vs Flatpak sha256, vendored files vs their hashes and licenses
bash scripts/deps.sh sbom out.json      # CycloneDX 1.5 inventory
bash scripts/deps.sh yamllint-version   # the yamllint pin lint.sh names when it is missing
```

`scripts/lint.sh` runs `check`, so a version bump that leaves a pin, a URL, or a Flatpak `sha256:` behind fails the local gate.

Flatpak (Qt 6 from org.kde.Platform, host package-manager queries via `flatpak-spawn --host`):

```bash
# needs flatpak-builder; installs org.kde.Sdk//6.10 from Flathub if missing
bash scripts/linux-flatpak.sh
# dist/AppAttic.flatpak
flatpak run org.appattic.AppAttic
```

The sandbox gets `--filesystem=host` so leftover and disk scans can see the machine. Plugin tags look under `/run/host` when `FLATPAK_ID` is set, because the sandbox PATH has no host pacman or apt. Scan plugins still cannot run `rm` or distro upgrades through `host.exec`. Manifest: `packaging/flatpak/org.appattic.AppAttic.yml`. It carries no `version` of its own: the manifest flatpak-builder gets is stamped with `appAtticVersion`, so the bundle reports the release it was built from.

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
| `Sources/AppAtticScan/` | Discover, usage, brew, outdated, packages, recommend, full scan. One file per feature, with the leftovers cluster split by concern: `Leftovers` (scan, roots, item model), `Identity` (who owns a name), `LeftoverText` (labels, reasons, blurbs), `LeftoverGroups` (grouping and collapsing), `Overlays` (PATH dirs, broken links, shadows). Plus the shared support modules it is built on: `Process` (subprocess, `which`), `Paths` (XDG, identity, redaction), `DiskSize` (`du`, directory walks), `Dates`, `Format`, `Text`, `ShellScript` (quoting for generated `sh`), `FilePermissions`, `Concurrency`, `Platform` (os-release, distro package manager), `Version` (the one version declaration) |
| `Sources/AppAtticCLI/` | `appattic` command line |
| `Sources/AppAttic/` | SwiftCrossUI app (AppKit on macOS) |
| `ui/linux-qt/` | C++ Qt 6 Widgets shell (Linux). Window, findings, settings, WASM host paths, and smoke are separate files |
| `tests/AppAtticScanTests/` | XCTest port of the old scanner cases, plus seeded mutation harnesses for the parsers that read foreign text: the CLI argv and `COLORFGBG`, package manager listings, `settings.json`, and ISO timestamps |
| `DESIGN.md` | Native UI visual rules |
| `docs/superpowers/specs/` | Requirement and architecture records (index: [`docs/superpowers/specs/README.md`](docs/superpowers/specs/README.md)). The Zig WASM core record is accepted and implemented; the Swift scan port record is implemented and superseded, kept in `archive/` |
| `core/` | Zig `wasm32` scan core (loader + plugins + C Wasmtime embedder). The Linux window runs on it |

## Notes

- Homebrew `outdated` is called without `--greedy`, so auto-updating casks are not flagged just because the bottle is older than the running app.
- An untrusted Homebrew cask is still listed on Outdated. Other formula and cask descriptions still load. AppAttic will not trust the tap.
- Named outdated upgrades (Homebrew, Flatpak, apt, pacman, AUR, dnf/yum, zypper) run from the Outdated page (confirm first) or `./run.sh update` (runs now; pass `--dry-run` to print the script). App Store and Snap stay report-only.
- Missing package managers are skipped. A check that ran and failed (network, dead remote, broken `brew outdated`, a locked `dpkg` blocking `apt-get -s autoremove`) does not fail the scan, but the scan is marked incomplete and the last-scan cache is not written, so a failed check is never served later as "up to date" or as "no unused packages".
- Review every path in a generated script before running it.
