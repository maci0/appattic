# AppAttic

Local cleanup tool for leftover data from uninstalled apps, unused installed software, and packages that have a newer version available. Nothing is deleted until you review a script or confirm in the UI.

macOS and Linux. Today: one Foundation scan library (`AppAtticScan`), a Gtk-free CLI (`appattic`), a SwiftCrossUI AppKit window on macOS (`AppAtticUI`), and a C++ Qt 6 window on Linux (`ui/linux-qt`). Direction: Zig core compiled to WASM, extra package managers and dialog copy as WASM plugins, native widgets only in the shell. Spec: [`docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md`](docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md). Linux UI is Qt 6, same toolkit as TMOG Linux. Qt-on-Linux is not claimed linked until `scripts/linux-qt-link.sh` runs on a real Linux host.

## What it reports

- **Leftovers.** User data whose owner app is gone (Application Support, caches, XDG dirs, and similar). Apple/system/toolchain dirs are not counted as reclaimable.
- **Stale.** Installed apps and brew formulas with weak or old usage. Last-used comes from Spotlight (macOS, including the inner executable), running processes, prefs mtime, data-dir mtime, Linux `recently-used.xbel`, and shell history for CLI tools. Unused is not the same as outdated.
- **Outdated.** Newer version available from Homebrew, Flatpak, Snap, apt, pacman, dnf, zypper, or the App Store. Homebrew formulas/casks and Flatpak can be updated after you confirm. App Store, apt, pacman, dnf, zypper, and Snap stay report-only. Untrusted Homebrew casks are listed and are not updated.

Tiers for installed software: KEEP (in use), REVIEW (idle, check first), REMOVE (stale and easy to reinstall). CLI cleanup scripts only include orphaned leftovers and REMOVE-tier items. The UI can also uninstall REVIEW-tier apps you opt into.

## CLI

```bash
./build.sh              # release
./build.sh debug
./run.sh report
./run.sh leftovers
./run.sh stale
./run.sh outdated
./run.sh update --dry-run
```

Equivalent without `run.sh` after a build:

```bash
.build/debug/appattic report
.build/release/appattic --version
```

Useful flags: `--json FILE`, `--include-system`, `--fresh` (ignore the last-scan cache), `--dry-run` (print the cleanup script), `--top N` (largest leftovers), `--category CAT`, `--leftovers-only`, `--stale-only`, `--version`.

`report`, `leftovers`, `stale`, and `outdated` reuse the last scan when it is still current. Pass `--fresh` to scan now. `update` always scans live.

Linux CLI does not need Qt. Headless `report` works without a display.

Tests:

```bash
swift build --target AppAtticScan -c debug
swift test --filter AppAtticScanTests
```

`swift test` and `swift build` need unrestricted permissions in sandboxed environments.

## Native UI

```bash
./build.sh              # release
./build.sh debug
./run.sh --ui
```

macOS: builds `AppAttic.app` (ad-hoc codesign). Launch with `open AppAttic.app` or `swift run AppAtticUI`.
SwiftPM names the UI product `AppAtticUI` so it does not collide with `appattic` on a case-insensitive volume.

Linux: UI is Qt 6 Widgets. Install headers with `./scripts/linux-deps.sh` (optional `--install` and `--install-wasmtime`). Debian/Ubuntu: `qt6-base-dev`. Fedora: `qt6-qtbase-devel`. Arch: `qt6-base`. openSUSE: `qt6-base-devel`. No `.app` bundle. `./build.sh` still builds the CLI if Qt is missing. Launch the window with `./run.sh --ui`.

You cannot cross-compile the Qt UI from macOS and call that a Linux link. Build on the Linux machine you will run, matching that distro. An Ubuntu-built binary is not assumed to start on Arch (glibc differs). Homebrew Qt on macOS is not Linux.

```bash
./scripts/linux-deps.sh              # print Qt 6 + Wasmtime + Swift notes
./scripts/linux-deps.sh --install    # Qt 6 headers, cmake, ninja, clang (root)
./scripts/linux-deps.sh --install-wasmtime
# Arch has no Swift in extra. AUR: swift-bin. Or:
./scripts/linux-deps.sh --install-swift   # Swift 5.10.1 into /opt/swift
export PATH="/opt/swift/usr/bin:$PATH"
./build.sh debug
# or only the UI:
bash scripts/linux-qt-link.sh
```

AppImage (portable Qt UI, no system Qt at runtime):

```bash
bash scripts/linux-deps.sh --install
bash scripts/linux-deps.sh --install-wasmtime
bash scripts/linux-appimage.sh
# dist/AppAttic-x86_64.AppImage  (or aarch64 on arm64 hosts)
```

Requires Qt 6 dev headers, zig, and wasmtime on the build host. The script downloads linuxdeploy, linuxdeploy-plugin-qt, and appimagetool into `dist/.appimage-tools/`. WASM modules ship under `usr/share/appattic/`; `libwasmtime.so` sits next to the binary.

Container builds:

```bash
podman build -t appattic .
# Arch userland (Qt 6 from pacman, Swift tarball):
podman build -t appattic-arch -f Dockerfile.arch .
# or: docker build -t appattic .
```

Ubuntu image installs Qt 6, runs `AppAtticScanTests`, and links the CLI plus the Qt window. `Dockerfile.arch` does the same on Arch. GitHub Actions `.github/workflows/linux.yml` runs both Ubuntu and archlinux jobs.

Sidebar: Overview, Leftovers, Stale Apps, Outdated, Settings. The last scan is shown immediately if one was saved. AppAttic then checks in the background whether that scan is still current, and rescans only if apps, brew, leftover folders, or the 24-hour age limit changed. Checkmarks on leftovers, stale apps, and outdated packages survive a background refresh if those items are still present. Settings (include system apps, confirm before running) and ignored leftover paths persist across launches. Ignore a leftover from its inspector to hide it on later scans. Include-in-cleanup uses the inspector toggle and toolbar Select All.

## Layout

| Path | Role |
|------|------|
| `Sources/AppAtticScan/` | Discover, usage, brew, leftovers, outdated, recommend, full scan |
| `Sources/AppAtticCLI/` | `appattic` command line |
| `Sources/AppAttic/` | SwiftCrossUI app (AppKit on macOS) |
| `ui/linux-qt/` | C++ Qt 6 Widgets shell (Linux) |
| `tests/AppAtticScanTests/` | XCTest port of the old scanner cases |
| `generate_icon.py` | One-off PNG icon generator. Not used at scan or UI runtime. |
| `DESIGN.md` | Native UI visual rules |
| `docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md` | Zig WASM core + plugin split |
| `core/` | Zig `wasm32` spike (core + plugins + C Wasmtime embedder) |

## Notes

- Homebrew `outdated` is called without `--greedy`, so auto-updating casks are not flagged just because the bottle is older than the running app.
- An untrusted Homebrew cask is still listed on Outdated. Other formula and cask descriptions still load. AppAttic will not trust the tap.
- Outdated Homebrew formulas/casks and Flatpak apps can be updated from the Outdated page or `./run.sh update`. Confirm first. App Store, apt, pacman, dnf, zypper, and Snap stay report-only.
- Missing package managers are skipped. A failed `brew outdated` (network) does not fail the scan.
- Review every path in a generated script before running it.
