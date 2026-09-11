# AppAttic Swift scan port

Date: 2026-08-17
Updated: 2026-09-05
Status: Implemented

Port the Python scanner into Swift so the Mac UI and Linux CLI/UI run with no Python. Product behavior stays the same: leftovers, stale software, outdated version signal. Nothing auto-deletes. Outdated is report-only except Homebrew formulas/casks and Flatpak, which apply only through the explicit `update` command or UI confirm. Distro managers, Snap, and the App Store stay report-only.

Follow-on architecture (Zig WASM core + plugins; Linux Qt already loads it): [`2026-08-26-zig-wasm-core-design.md`](2026-08-26-zig-wasm-core-design.md).

## Goal

One Foundation scan library, two executables:

- `appattic`: CLI (`report`, `leftovers`, `stale`, `outdated`, `packages`, `update`)
- `AppAtticUI`: SwiftCrossUI window on macOS (AppKit; SwiftPM product name `AppAtticUI` because APFS is case-insensitive and would collide with `appattic`). Linux UI is C++ Qt 6 in `ui/linux-qt`.

The Python package is gone. Icons live in `packaging/`.

## Out of scope

- `serve` / `web.py` (optional web dashboard). Not ported.
- `brew-leaves` CLI command. Not in this port.
- Rewriting the window chrome or DESIGN.md visual rules.
- AppKit, SF Symbols, materials, or AppKit `List` in any target Linux compiles.

## Package layout

`Package.swift` defines:

| Target | Kind | Depends on |
|--------|------|------------|
| `AppAtticScan` | library | Foundation only |
| `appattic` | executable | `AppAtticScan` |
| `AppAtticUI` | executable (macOS only; target name `AppAttic`) | `AppAtticScan`, SwiftCrossUI, DefaultBackend |
| `AppAtticScanTests` | test (`tests/AppAtticScanTests`) | `AppAtticScan` |

On Linux, `Package.swift` omits the SwiftCrossUI product and dependency. Platform floor: macOS 13. Linux is a first-class scan and CLI host. Linux UI needs Qt 6 Widgets at build and run (`scripts/linux-qt-link.sh`).

## Library files (`Sources/AppAtticScan/`)

| File | Responsibility |
|------|----------------|
| `Util.swift` | subprocess, `du`, human size, date helpers |
| `Discover.swift` | installed apps (`.app` / `.desktop`) |
| `Usage.swift` | last-used (Spotlight, processes, shell history, xbel) |
| `BrewInfo.swift` | formulas, casks, leaves, `desc`, untrusted-cask retry |
| `Outdated.swift` | brew / MAS / flatpak / snap / apt / pacman / dnf / zypper; attach summaries |
| `Leftovers.swift` | data-dir scan, classify owned/system/orphaned, reasons |
| `Recommend.swift` | software list, KEEP / REVIEW / REMOVE |
| `Scan.swift` | `runFullScan(includeSystem:progress:)` |
| `Cleanup.swift` | reviewable `/bin/sh` script |
| `Cache.swift` | last-scan cache (`--fresh` bypasses it) |
| `Settings.swift` | include-system, confirm, ignore list, cleanup selection |
| `Packages.swift` | distro orphans and language globals |
| `Steam.swift` | Steam leftovers / uninstall helpers |
| `CrossOver.swift` | CrossOver bottle helpers |

`Sources/AppAtticScan/CLIParse.swift` owns CLI flags and commands.

Scan types the UI already decodes (`ScanData`, `LeftoverItem`, `SoftwareItem`, `OutdatedEntry`, `ScanTotals`, `PackageEntry`) live in the library. The UI target imports `AppAtticScan`. `Sources/AppAttic/Models.swift` keeps only UI helpers (`formatDate`) that are not scan types.

## Scan pipeline

Same order as `scan.run_full_scan`:

1. Discover apps. Drop system apps unless `includeSystem`.
2. Fill usage metadata.
3. Collect Homebrew info (`brew` missing → `available == false`, empty lists).
4. Outdated: brew outdated + Linux managers + App Store. Report only in the scan result. Homebrew/Flatpak apply through `update` / UI confirm, never from the leftover cleanup script.
5. Leftover data dirs + orphan LaunchAgents.
6. Prefs-mtime fallback for apps with no last-used.
7. `buildSoftware` + apply outdated flags + copy summaries + `evaluateAll`.
8. Distro orphans and language globals (`collectPackages`).

Progress is a `String` callback, same messages the UI status line already shows.

## Mac vs Linux

One library, `#if os(macOS)` / `#if os(Linux)` inside the files above. Not two apps.

Shared on both: leftover classify rules, tier thresholds, brew JSON (`--formula/--cask --installed`, drop refused casks, join desc by path / artifact / title), apt/pacman/dnf/zypper/flatpak/snap parsers, cleanup script text.

Darwin only: Spotlight via `Process` (`mdls` / `mdfind`), `.app` bundles, Info.plist + InfoPlist.strings via Foundation `PropertyListSerialization`, MAS receipt / `mas outdated` (never `--accurate`).

Linux only: `.desktop` from XDG application dirs, XDG config/data/cache/state leftover roots, `recently-used.xbel`, Linux system-name classify.

Forbidden in `AppAtticScan` and `appattic`: `import AppKit`, `NSImage`, SF Symbols, `NSVisualEffectView`, AppKit `List`.

`ContentView.swift` may keep existing `#if os(macOS)` for Reveal in Finder vs Files.

## CLI (`Sources/AppAtticCLI/`, product name `appattic`)

Default command is `report` if none is given.

Commands: `report`, `leftovers`, `stale`, `outdated`, `packages`, `update`.

Flags (not `serve`):

- `--json FILE`
- `--include-system`
- `--fresh` (ignore the last-scan cache)
- `--dry-run` (print cleanup or update script, do not run it)
- `--top N` (largest leftovers)
- `--category` (leftover root substring filter)
- `--leftovers-only` / `--stale-only` on `report`
- `--version`
- `--help`

`update` upgrades only updatable Homebrew formulas/casks and Flatpak apps. Distro managers, Snap, and the App Store stay report-only. `report`, `leftovers`, `stale`, `outdated`, and `packages` reuse the last scan when it is still current; `update` always scans live.

Exit 0 on a completed scan. Non-zero if the scan throws. Missing optional tools do not fail the scan.

Headless Linux: this binary must link without Gtk.

## UI

`ScannerViewModel` calls `AppAtticScan.runFullScan` on a background queue. There is no `executePythonScan` / `APPATTIC_PYTHON` path.

Cleanup still writes a temp `.sh` and runs `/bin/sh`. Selection, confirm alert, and script sheet stay in the UI. Sidebar: Overview, Leftovers, Stale Apps, Outdated, Packages, Settings.

## Errors

- `brew`, `mas`, `flatpak`, `snap`, `apt`, `pacman`, `dnf`, `zypper` missing or failing: that manager contributes `[]`. Scan continues.
- Untrusted Homebrew cask: listed on Outdated, not updated; other formula/cask `desc` still load.
- Thrown scan failure: UI `errorMessage`; CLI stderr + non-zero exit.
- Cleanup script comments outdated lines, does not run them. Homebrew/Flatpak upgrades live only in `update` / UI confirm.

## Tests

`tests/AppAtticScanTests` ports the old Python cases with fixtures (fake apps, temp dirs, canned JSON/stdout). No requirement to hit live Spotlight or network.

Must cover:

- Leftover false positives (`ClassifyTests.swift`)
- KEEP / REVIEW / REMOVE thresholds (`RecommendTests.swift`)
- Prefs-mtime fallback and `effectiveLastUsed` (`UsageTests.swift`)
- Brew untrusted-cask retry and desc join (`BrewInfoTests.swift`)
- Outdated parsers: apt, mas, brew JSON, pacman, dnf, zypper (`OutdatedTests.swift`)
- Linux `.desktop` / XDG system names (`DiscoverTests.swift`)
- CLI flags including `packages`, `update`, `--fresh` (`ScanTests.swift`)
- Packages orphans/globals (`PackageTests.swift`)

Live `Process` wrappers are injectable so tests pass canned output.

Command: `swift test` (needs unrestricted permissions in this environment, same as `swift build`).

## Cutover

Completed. `ScannerViewModel` calls `AppAtticScan.runFullScan`. The CLI links `AppAtticScan`. The runtime Python package, `tests/*.py`, `APPATTIC_PYTHON`, and `copy_python` / `link_python` are gone.

No dual-run of Python and Swift in production.

## Scripts and docs

`run.sh`:

- `./run.sh` and `./run.sh report|leftovers|stale|outdated|packages|update` exec the `appattic` CLI binary from `.build`.
- `./run.sh --ui` execs `AppAtticUI` on macOS or `ui/linux-qt/build/appattic-qt` on Linux.
- No `PYTHONPATH`. No `python3 -m appattic`.

`build.sh`:

- macOS: build UI, stage `AppAttic.app`, ad-hoc codesign. Do not copy Python.
- Linux: always build `appattic` CLI. Build Qt UI via `scripts/linux-qt-link.sh` only if `pkg-config Qt6Widgets` succeeds. Do not fail the whole script for missing Qt when the user only needs CLI.

`README.md` matches the above. Version is `1.1.3`; `appAtticVersion` in `Sources/AppAtticScan/Util.swift` is the source of truth.

## Success

- `swift test` passes the ported cases.
- Mac: `open AppAttic.app` scans with Python uninstalled or not on `PATH`.
- Linux: `appattic report` runs without Gtk.
- Linux UI still requires Qt 6 Widgets (`ui/linux-qt`).
- User-visible leftover/stale/outdated rules and copy stay equivalent to the Python scanner (including brew `desc` after the untrusted-cask fix).
