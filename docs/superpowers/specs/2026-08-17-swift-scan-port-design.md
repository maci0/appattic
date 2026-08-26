# AppAttic Swift scan port

Date: 2026-08-17

Port the Python scanner into Swift so the Mac UI and Linux CLI/UI run with no Python. Product behavior stays the same: leftovers, stale software, outdated version signal. Nothing auto-deletes. Outdated never upgrades.

## Goal

One Foundation scan library, two executables:

- `appattic`: CLI (`report`, `leftovers`, `stale`, `outdated`)
- `AppAtticUI`: SwiftCrossUI window on macOS (AppKit). Linux UI is C++ Qt 6 in `ui/linux-qt`.

Delete the Python package when the Swift tests cover the old cases and the UI calls the library in-process.

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
| `AppAttic` | executable | `AppAtticScan`, SwiftCrossUI, DefaultBackend |
| `AppAtticScanTests` | test | `AppAtticScan` |

Platform floor: macOS 13. Linux is a first-class scan and CLI host. Linux UI needs Qt 6 Widgets at build and run (`scripts/linux-qt-link.sh`).

## Library files (`Sources/AppAtticScan/`)

| File | Responsibility |
|------|----------------|
| `Util.swift` | subprocess, `du`, human size, date helpers |
| `Discover.swift` | installed apps (`.app` / `.desktop`) |
| `Usage.swift` | last-used (Spotlight, processes, shell history, xbel) |
| `BrewInfo.swift` | formulas, casks, leaves, `desc`, untrusted-cask retry |
| `Outdated.swift` | brew / MAS / flatpak / snap / apt; attach summaries |
| `Leftovers.swift` | data-dir scan, classify owned/system/orphaned, reasons |
| `Recommend.swift` | software list, KEEP / REVIEW / REMOVE |
| `Scan.swift` | `runFullScan(includeSystem:progress:)` |
| `Cleanup.swift` | reviewable `/bin/sh` script |

Scan types the UI already decodes (`ScanData`, `LeftoverItem`, `SoftwareItem`, `OutdatedEntry`, `ScanTotals`) live in the library. The UI target imports `AppAtticScan`. `Sources/AppAttic/Models.swift` keeps only UI helpers (`humanSize`, `formatDate`) that are not scan types.

## Scan pipeline

Same order as `scan.run_full_scan`:

1. Discover apps. Drop system apps unless `includeSystem`.
2. Fill usage metadata.
3. Collect Homebrew info (`brew` missing → `available == false`, empty lists).
4. Outdated: brew outdated + Linux managers + App Store. Report only.
5. Leftover data dirs + orphan LaunchAgents.
6. Prefs-mtime fallback for apps with no last-used.
7. `buildSoftware` + apply outdated flags + copy summaries + `evaluateAll`.

Progress is a `String` callback, same messages the UI status line already shows.

## Mac vs Linux

One library, `#if os(macOS)` / `#if os(Linux)` inside the files above. Not two apps.

Shared on both: leftover classify rules, tier thresholds, brew JSON (`--formula/--cask --installed`, drop refused casks, join desc by path / artifact / title), apt/flatpak/snap parsers, cleanup script text.

Darwin only: Spotlight via `Process` (`mdls` / `mdfind`), `.app` bundles, Info.plist + InfoPlist.strings via Foundation `PropertyListSerialization`, MAS receipt / `mas outdated` (never `--accurate`).

Linux only: `.desktop` from XDG application dirs, XDG config/data/cache/state leftover roots, `recently-used.xbel`, Linux system-name classify.

Forbidden in `AppAtticScan` and `appattic`: `import AppKit`, `NSImage`, SF Symbols, `NSVisualEffectView`, AppKit `List`.

`ContentView.swift` may keep existing `#if os(macOS)` for Reveal in Finder vs Files.

## CLI (`Sources/AppAtticCLI/`, product name `appattic`)

Default command is `report` if none is given.

Commands: `report`, `leftovers`, `stale`, `outdated`.

Flags to port from today's CLI (not `serve`):

- `--json FILE`
- `--include-system`
- `--dry-run` (print cleanup script, do not run it)
- `--top N` (largest leftovers)
- `--category` (leftover root substring filter)
- `--leftovers-only` / `--stale-only` on `report`
- `--version`

Exit 0 on a completed scan. Non-zero if the scan throws. Missing optional tools do not fail the scan.

Headless Linux: this binary must link without Gtk.

## UI

`ScannerViewModel` calls `AppAtticScan.runFullScan` on a background queue. Remove `executePythonScan`, `pythonExecutable`, `pythonPackageParent`, and `APPATTIC_PYTHON`.

Cleanup still writes a temp `.sh` and runs `/bin/sh`. Selection, confirm alert, and script sheet stay in the UI.

## Errors

- `brew`, `mas`, `flatpak`, `snap`, `apt` missing or failing: that manager contributes `[]`. Scan continues.
- Untrusted Homebrew cask: skip that cask, still load other formula/cask `desc` (current Python fix).
- Thrown scan failure: UI `errorMessage`; CLI stderr + non-zero exit.
- Outdated is never an upgrade. Cleanup script comments outdated lines, does not run them.

## Tests

`AppAtticScanTests` ports Python cases with fixtures (fake apps, temp dirs, canned JSON/stdout). No requirement to hit live Spotlight or network.

Must cover:

- Leftover false positives (`tests/test_classify.py`)
- KEEP / REVIEW / REMOVE thresholds (`tests/test_recommend.py`)
- Prefs-mtime fallback (`tests/test_prefs.py`)
- `effectiveLastUsed` Spotlight index window (`tests/test_usage.py`)
- Brew untrusted-cask retry and desc join
- Outdated parsers: apt, mas, brew JSON (`tests/test_outdated.py`)
- Linux `.desktop` / XDG system names (`tests/test_linux.py`)

Live `Process` wrappers are injectable so tests pass canned output.

Command: `swift test` (needs unrestricted permissions in this environment, same as `swift build`).

## Cutover

1. Add library + tests. Port modules one at a time. Python stays until `runFullScan` exists and tests pass.
2. Point `ScannerViewModel` at the library. Point CLI at the library.
3. Delete the runtime Python package (`scan.py`, `discover.py`, `leftovers.py`, `usage.py`, `recommend.py`, `outdated.py`, `brewinfo.py`, `cli.py`, `web.py`, `util.py`, `__main__.py`, `__init__.py`), `tests/*.py`, and `AppAttic.app/Contents/Resources/appattic`. Remove `APPATTIC_PYTHON` handling and `copy_python` / `link_python` in `build.sh`. Keep `generate_icon.py` only as a one-off asset script; it is not part of scan or UI runtime.

No dual-run of Python and Swift in production. No JSON-compare gate required if tests port the old cases.

## Scripts and docs

`run.sh`:

- `./run.sh` and `./run.sh report|leftovers|stale|outdated` exec the `appattic` CLI binary from `.build`.
- `./run.sh --ui` execs `AppAtticUI` on macOS or `ui/linux-qt/build/appattic-qt` on Linux.
- No `PYTHONPATH`. No `python3 -m appattic`.

`build.sh`:

- macOS: build UI, stage `AppAttic.app`, ad-hoc codesign. Do not copy Python.
- Linux: always build `appattic` CLI. Build Qt UI via `scripts/linux-qt-link.sh` only if `pkg-config Qt6Widgets` succeeds. Do not fail the whole script for missing Qt when the user only needs CLI.

`README.md` matches the above. Version stays `1.0.0` until a later release decision.

## Success

- `swift test` passes the ported cases.
- Mac: `open AppAttic.app` scans with Python uninstalled or not on `PATH`.
- Linux: `appattic report` runs without Gtk.
- Linux UI still requires Qt 6 Widgets (`ui/linux-qt`).
- User-visible leftover/stale/outdated rules and copy stay equivalent to the Python scanner (including brew `desc` after the untrusted-cask fix).
