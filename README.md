# AppAttic

Local cleanup tool for leftover data from uninstalled apps, unused installed software, unused distro orphans and language globals, packages that have a newer version available, and a disk usage analyzer (folder sizes, devices, ring/treemap charts). Nothing is deleted until you review a script or confirm in the UI. Move to Trash from Disk Usage asks first.

macOS and Linux. Today: one Foundation scan library (`AppAtticScan`), a Gtk-free CLI (`appattic`), a SwiftCrossUI AppKit window on macOS (`AppAtticUI`), and a C++ Qt 6 window on Linux (`ui/linux-qt`). Direction: Zig core compiled to WASM, extra package managers and dialog copy as WASM plugins, native widgets only in the shell. Spec: [`docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md`](docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md). Linux UI is Qt 6, same toolkit as TMOG Linux. Qt-on-Linux is not claimed linked until `scripts/linux-qt-link.sh` runs on a real Linux host.

## What it reports

- **Leftovers.** User data whose owner app is gone (Application Support, caches, XDG dirs, and similar), plus user overlays (`~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.local/share/applications`) that hide a same-named packaged file. Overlay rows use status `shadow`; cleanup removes the overlay only. Apple/system/toolchain dirs are not counted as reclaimable.
- **Stale.** Installed apps and brew formulas with weak or old usage. Last-used comes from Spotlight (macOS, including the inner executable), running processes, prefs mtime, data-dir mtime, Linux `recently-used.xbel`, and shell history for CLI tools. Unused is not the same as outdated.
- **Outdated.** Newer version available from Homebrew, Flatpak, Snap, apt, pacman, AUR (paru/yay/pikaur), dnf/yum, zypper, or the App Store. Named upgrades (Homebrew, Flatpak, apt, pacman, AUR, dnf/yum, zypper) run from the Outdated page after you confirm, or with `appattic update` (`--dry-run` prints the script first). Not a full distro upgrade (`apt upgrade`, `pacman -Syu`). App Store and Snap stay report-only. Untrusted Homebrew casks are listed and are not updated. Debian/Ubuntu also lists `dpkg` config remnants (`rc`) and PPA source files.
- **Packages.** Distro orphans (nothing still needs them) and user-global language tools (`npm`/`pnpm`/`bun -g`, pipx, `uv tool`). Remove and mark-as-manual are confirm + script only. Distro upgrades are never included.
- **Disk usage.** Folder and device sizes with a tree, allocated vs apparent size, ring and treemap charts (Linux Qt), scan home / folder / file system, open in the file manager, and move to Trash after confirm. Other file systems are not descended into unless you ask. Directory symlinks are not followed. `appattic disk [PATH]` prints the tree.

Tiers for installed software: KEEP (in use), REVIEW (idle, check first), REMOVE (stale and easy to reinstall). Default CLI cleanup scripts (`report --dry-run`, `leftovers --dry-run`, `stale --dry-run`) only include orphaned leftovers, PATH overlays, and REMOVE-tier items. `packages --dry-run` is a separate package script. The UI can also uninstall REVIEW-tier apps you opt into.

## CLI

Swift 5.10.1 (`.swift-version`). `./build.sh` uses `swift` on PATH, then `/opt/swift/usr/bin`, then `.deps/swift/usr/bin`. Missing Swift is a named error, not `swift: command not found`. `./build.sh --help` lists contributor commands.

```bash
./build.sh              # release
./build.sh debug
./run.sh report
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

Useful flags: `--json FILE`, `--include-system`, `--fresh` (ignore the last-scan cache), `--dry-run` (print the script for this command), `--top N` (largest leftovers), `--category CAT`, `--leftovers-only`, `--stale-only`, `--no-color`, `--version` (`-v`), `--help` (`-h`). Progress and status (including JSON written to FILE) go to stderr so reports and `--dry-run` scripts stay pipeable.

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

`includeSystem` defaults to false (OS system apps stay out of the stale list). The CLI also reads it; `--include-system` turns it on for that run. There is no flag to turn it off when the file already has `true`. `confirmDelete` defaults to true and is UI-only. `ignoredLeftoverPaths` hides those leftovers in both the UI and CLI. A missing file uses those defaults. A malformed file is an error: the CLI exits 2, the UI shows the path and does not overwrite the file until you save settings.

Environment:

| Variable | Used by | Role |
|---|---|---|
| `APPATTIC_CORE_OUT` | Linux Qt | Directory of `appattic_core.wasm` and plugins. AppImage sets this. |
| `APPATTIC_PAGE` | UI | Initial sidebar: `overview` (default), `leftovers`, `stale`, `outdated`, `packages`, `disk`, `settings`. |
| `NO_COLOR` | CLI | Disable ANSI color when set to a non-empty value. Also `--no-color` or `TERM=dumb`. |
| `XDG_DATA_HOME` | Linux | Absolute data root; parent of `appattic/settings.json`, `last-scan.json`, and user desktop entries. |
| `XDG_CONFIG_HOME` | Linux | Absolute configuration root scanned for leftovers and usage history. |
| `XDG_CACHE_HOME` | Linux | Absolute cache root scanned for leftovers. |
| `XDG_STATE_HOME` | Linux | Absolute state root scanned for leftovers. |
| `XDG_DATA_DIRS` | Linux | Colon-separated absolute data roots searched for desktop entries (default `/usr/local/share:/usr/share`). |

Per the XDG Base Directory specification, empty or relative XDG paths are ignored and the standard user defaults are used.

`report`, `leftovers`, `stale`, `outdated`, and `packages` reuse the last scan when it is still current. Pass `--fresh` to scan now. `update` always scans live and drops the last-scan cache after a successful upgrade.

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

Tests (same flags as `.github/workflows/linux.yml`):

```bash
bash scripts/check.sh
# fast: lint + AppAtticScanTests + CLI debug build
bash scripts/check.sh --qt
# full Linux CI parity, including Qt/WASM proof

swift build --target AppAtticScan -c debug --disable-automatic-resolution
swift test --filter AppAtticScanTests --disable-automatic-resolution
swift test --filter UtilTests --disable-automatic-resolution   # one class
./core/build.sh test brew.zig                                  # one Zig plugin
bash scripts/lint.sh
```

`swift test` and `swift build` need unrestricted permissions in sandboxed environments.

`scripts/lint.sh` runs shellcheck on the build scripts, compiles `hostexec` with warnings as errors, and runs `zig fmt --check` when `zig` is on PATH. Linux CI runs that script as a blocking job. `core/build.sh` also fails if Zig sources are unformatted or `hostexec_test` warns. `scripts/check.sh` is the fast lint + test + CLI loop; `scripts/check.sh --qt` reproduces the full Linux CI verification.

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
./scripts/linux-deps.sh --install-swift   # Swift 5.10.1 into /opt/swift (or .deps/swift without root)
export PATH="/opt/swift/usr/bin:$PATH"    # or: export PATH="$PWD/.deps/swift/usr/bin:$PATH"
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

`VERSION` is the current git tag without a leading `v`, or `1.2.0` if untagged. The release workflow sets it from the `v*` tag. The script then runs `--smoke` on the AppImage and fails if that does not print `SMOKE=ok`.

Requires Qt 6 dev headers, zig, and wasmtime on the build host. The script downloads pinned linuxdeploy, linuxdeploy-plugin-qt, and appimagetool into `dist/.appimage-tools/` and checks SHA-256. WASM modules ship under `usr/share/appattic/`; `libwasmtime.so` sits next to the binary.

Flatpak (Qt 6 from org.kde.Platform, host package-manager queries via `flatpak-spawn --host`):

```bash
# needs flatpak-builder; installs org.kde.Sdk//6.10 from Flathub if missing
bash scripts/linux-flatpak.sh
# dist/AppAttic.flatpak
flatpak run org.appattic.AppAttic
```

The sandbox gets `--filesystem=host` so leftover and disk scans can see the machine. Plugin tags look under `/run/host` when `FLATPAK_ID` is set, because the sandbox PATH has no host pacman or apt. Scan plugins still cannot run `rm` or distro upgrades through `host.exec`. Manifest: `packaging/flatpak/org.appattic.AppAttic.yml`.

Container builds:

```bash
podman build -t appattic .
# Arch userland (Qt 6 from pacman, Swift tarball):
podman build -t appattic-arch -f Dockerfile.arch .
# or: docker build -t appattic .
```

Ubuntu image installs Qt 6, runs `AppAtticScanTests`, and links the CLI plus the Qt window. `Dockerfile.arch` does the same on Arch. GitHub Actions `.github/workflows/linux.yml` runs both Ubuntu and archlinux jobs.

Sidebar: Overview, Leftovers, Stale Apps, Outdated, Packages, Disk Usage, Settings. The last scan is shown immediately if one was saved. AppAttic then checks its inventory fingerprint in the background and rescans if app, package-manager, tool, Steam/CrossOver, or leftover state changed, or if the scan is over 24 hours old. Checkmarks on leftovers, stale apps, outdated rows, and Packages rows survive a background refresh if those items are still present. Settings (confirm before running; on macOS, include system apps) and ignored leftover paths persist in `settings.json` (see above). The Linux window does not scan installed system apps. Ignore a leftover from its inspector to hide it on later scans. Include-in-cleanup uses the leftover list tickbox on Linux, the inspector toggle, and toolbar Select All.

## Layout

| Path | Role |
|------|------|
| `Sources/AppAtticScan/` | Discover, usage, brew, leftovers, outdated, packages, recommend, full scan |
| `Sources/AppAtticCLI/` | `appattic` command line |
| `Sources/AppAttic/` | SwiftCrossUI app (AppKit on macOS) |
| `ui/linux-qt/` | C++ Qt 6 Widgets shell (Linux). Window, findings, settings, WASM host paths, and smoke are separate files |
| `tests/AppAtticScanTests/` | XCTest port of the old scanner cases |

| `DESIGN.md` | Native UI visual rules |
| `docs/superpowers/specs/` | Requirement and architecture records (Swift port implemented; Zig WASM core accepted) |
| `core/` | Zig `wasm32` spike (core + plugins + C Wasmtime embedder) |

## Notes

- Homebrew `outdated` is called without `--greedy`, so auto-updating casks are not flagged just because the bottle is older than the running app.
- An untrusted Homebrew cask is still listed on Outdated. Other formula and cask descriptions still load. AppAttic will not trust the tap.
- Named outdated upgrades (Homebrew, Flatpak, apt, pacman, AUR, dnf/yum, zypper) run from the Outdated page (confirm first) or `./run.sh update` (runs now; pass `--dry-run` to print the script). App Store and Snap stay report-only.
- Missing package managers are skipped. A failed `brew outdated` (network) does not fail the scan.
- Review every path in a generated script before running it.
