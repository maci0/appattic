# AppAttic Swift scan port (ARCHIVED)

Date: 2026-08-17
Updated: 2026-11-13
Status: Historical. The port landed. Do not extend this file.

The current Linux scan path is [`2026-08-26-zig-wasm-core-design.md`](../2026-08-26-zig-wasm-core-design.md). The Swift CLI and the macOS UI still use `AppAtticScan`. Current commands, flags, and window behavior are in the source and in [`DESIGN.md`](../../../DESIGN.md), not in the lists below.

## What this record decided

Port the Python scanner into Swift so the Mac UI and the CLI run with no Python. Product behavior stayed the same at the time of the port: leftovers, stale software, and an outdated-version signal. Nothing auto-deleted.

One Foundation scan library, two executables:

- `appattic`, the CLI, linking `AppAtticScan` only.
- `AppAtticUI`, the SwiftCrossUI window on macOS (AppKit). The SwiftPM product is `AppAtticUI` because APFS is case-insensitive and `AppAttic` would collide with `appattic`. The target name is `AppAttic`.

On Linux, `Package.swift` omits the SwiftCrossUI product. The platform floor in the manifest is macOS 13. Linux UI is C++ Qt 6 in `ui/linux-qt`, linked by `scripts/linux-qt-link.sh`. Headless `appattic` does not link Gtk.

The Python package is gone: no `APPATTIC_PYTHON`, no `python3 -m appattic`, no `tests/*.py`. Icons live in `packaging/`.

Left out of the port, and still absent: a `serve` command and the old `web.py` dashboard, and a `brew-leaves` command (`parseCLIArguments` rejects it as an unknown command).

`AppAtticScan` and `appattic` do not import AppKit. `ContentView.swift` may keep `#if os(macOS)` for Reveal in Finder versus Files.

Library files at the port: `Discover.swift`, `Usage.swift`, `BrewInfo.swift`, `Outdated.swift`, `Leftovers.swift`, `Recommend.swift`, `Scan.swift`, `Cleanup.swift`, `Cache.swift`, `Settings.swift`, `Packages.swift`, `Steam.swift`, `CrossOver.swift`, and `CLIParse.swift`. `Util.swift` held subprocess, `du`, human size, and date helpers, and was later split into `Process.swift`, `DiskSize.swift`, `Format.swift`, `Dates.swift`, and `Text.swift`.

## Scan order at the port

The Swift scan followed the old `scan.run_full_scan` order:

1. Discover apps. Drop system apps unless `includeSystem`.
2. Fill usage metadata.
3. Collect Homebrew info. A missing `brew` means `available == false` and empty lists.
4. Outdated: brew, the Linux managers, and the App Store. Report only inside the scan result. Homebrew and Flatpak apply through `update` or a UI confirm, never from the leftover cleanup script.
5. Leftover data dirs and orphan LaunchAgents.
6. Prefs-mtime fallback for apps with no last-used.
7. `buildSoftware`, apply outdated flags, copy summaries, `evaluateAll`.
8. Distro orphans and language globals (`collectPackages`).

Progress is a `String` callback.

One library, with `#if os(macOS)` and `#if os(Linux)` inside the scan files.

Shared: leftover classify rules, tier thresholds, brew JSON (`--formula` / `--cask --installed`, drop refused casks, join desc by path, artifact, or title), apt, pacman, dnf, zypper, flatpak, and snap parsers, and cleanup script text.

Darwin only: Spotlight through `Process` (`mdls` / `mdfind`), `.app` bundles, Info.plist and InfoPlist.strings through Foundation `PropertyListSerialization`, MAS receipt and `mas outdated` (never `--accurate`).

Linux only, on this stack: `.desktop` files from XDG application dirs, XDG config, data, cache, and state leftover roots, `recently-used.xbel`, and the Linux system-name list.

A missing or failing `brew`, `mas`, `flatpak`, `snap`, `apt`, `pacman`, `dnf`, or `zypper` contributes `[]`. The scan continues. An untrusted Homebrew cask is listed and is not updated. Other formula and cask `desc` rows still load. That untrusted-cask rule is Swift-only. The Zig `brew` plugin does not apply it. A thrown scan failure is `errorMessage` in the UI and stderr plus a non-zero exit in the CLI.

The cleanup script comments outdated lines. It does not run them. Homebrew and Flatpak upgrades live in `update` and in the UI confirm path.

`ScannerViewModel` calls `AppAtticScan.runFullScan` on a background queue. There is no `executePythonScan` path. Cleanup writes a temp `.sh` and runs `/bin/sh`.

## What has moved since

Treat the following as history of the port, not as the current tree.

- CLI commands at the port were `report` (the default), `leftovers`, `stale`, `outdated`, `packages`, and `update`. Flags were `--json FILE`, `--include-system`, `--fresh`, `--dry-run`, `--top N`, `--category`, `--leftovers-only`, `--stale-only`, `--version`, and `--help`. Later commands (`config`, `disk`, `erase`, `restore`, `schema`) and later flags are in `CLIParse.swift`.
- `update` at the port upgraded Homebrew formulas and casks and Flatpak apps. Distro managers, Snap, and the App Store stayed report-only. Later updatable managers are in the Zig spec and in `Outdated.swift`.
- The port sidebar was Overview, Leftovers, Stale Apps, Outdated, Packages, and Settings. Disk Usage came later.
- `confirmDelete` already existed. It defaults to on and can be turned off, so "always confirm" was never a hard rule. See [`DESIGN.md`](../../../DESIGN.md).
- Version at the port was `1.2.1`. `appAtticVersion` in `Sources/AppAtticScan/Version.swift` is the source of truth.
- `run.sh` execs the `appattic` binary from `.build`. `./run.sh --ui` execs `AppAtticUI` on macOS or the Qt binary on Linux. `build.sh` builds the CLI, and builds the Qt UI when `pkg-config Qt6Widgets` succeeds. The macOS UI build depends on a Swift 6 compiler for SwiftCrossUI. The pinned Swift 5.10.1 toolchain cannot build it, and `build.sh` rejects other Swift versions before reaching the UI build. Its fallback builds the CLI only; a Swift 6 UI build needs a separate setup.

Tests for the port live in `tests/AppAtticScanTests` and use fixtures. They do not require live Spotlight or a network. Live `Process` wrappers are injectable. `swift test` on the pinned toolchain needs `APPATTIC_NO_MAC_UI=1` because `AppAtticUI` does not build on Swift 5.10. `scripts/test.sh` sets that.

## Cutover

Done. The CLI links `AppAtticScan`. Production does not run Python and Swift together. Linux Qt later took its own scan path and loads the WASM core. That split is the accepted spec, not a leftover of this port.
