# Threat model: AppAttic

Last reviewed: 2026-09-05.

No owner or review cadence is published. This file is the living model of the attack surface. Point fixes belong in application code reviews, not here.

AppAttic is a local cleanup utility (CLI `appattic`, macOS AppKit UI, Linux Qt 6 UI, Zig WASM scan core). It is not a network service. There is no login, tenant isolation, or remote API. The process runs as the OS user who launched it. The blast radius is that user's files, packages, and any privilege those package managers can obtain (polkit/sudo).

## Risk-ranked summary

| Rank | Risk | Boundary | Impact | Existing control | Gap |
|---|---|---|---|---|---|
| 1 | A generated `/bin/sh` script runs `rm -rf`, `brew uninstall`, `flatpak uninstall -y`, `snap remove`, or distro `purge`/`-Rns` against scan results | User → app (script execution) | Permanent loss of apps, leftover data, or packages | UI confirm dialog when `confirmDelete` is true; interactive CLI `update` prompt; `shellQuote`; KEEP/system leftovers excluded from default CLI dry-run | Non-interactive CLI `update` deliberately proceeds without a prompt. UI confirm can be turned off. Scripts are the only gate between a bad finding and a destructive argv. |
| 2 | Scan cache or WASM plugin JSON is treated as a trusted finding list and becomes cleanup commands | Build/runtime plugins; cache file → app | Attacker-chosen paths or package names in the script the user is asked to run | Cache fingerprint + 24h age (`Cache.swift`). WASM `host.exec` query allowlist (`hostexec.c`). Qt drops some `rm` of `/usr/` (`finding.cpp`) | Cache has no MAC. Plugin `.wasm` is unsigned. Qt uses plugin-supplied `command` almost verbatim. Swift leftover `rm` has no `/usr` deny. |
| 3 | Leftover classifier lists a credential or config tree as orphaned (`rm -rf ~/.aws` and similar) | Filesystem → leftover model | Secret loss (cloud keys, Docker config) | `linuxSystemNames` / `appleServiceNames` mark `.ssh`, `.gnupg`, and many OS dirs `system` (`Leftovers.swift`) | `.aws` is scanned as a home leaf and is not in the system-name set. Misclassification is a recurring class. |
| 4 | `host.exec` is the only host import; a bug there is WASM breakout to process spawn | WASM guest → host | Arbitrary subprocess if allowlist fails | Allowlist + metacharacter reject + destructive-token deny (`hostexec.c`). No WASI filesystem. | No Wasmtime fuel/epoch. `APPATTIC_CORE_OUT` loads whatever `.wasm` files are there. Live `execvp` on Linux unless `APPATTIC_HOST_EXEC_FIXTURE`. |
| 5 | Outdated / brew / Flatpak talk to the network; answers are parsed as versions and names | App → internet | Wrong upgrade target; attacker who owns the tap/index influences `brew upgrade` / `flatpak update` | Untrusted Homebrew casks listed, not updated (`BrewInfo.swift`, `Outdated.swift`). Named distro upgrades run only after confirm as `/bin/sh`, never via `host.exec`. App Store stays report-only. `HOMEBREW_NO_AUTO_UPDATE=1`. | iTunes lookup is HTTPS with no pinning. Package-manager stdout is trusted JSON/text. |
| 6 | Build scripts download toolchains | Build → runtime | Compromised zig/wasmtime/Swift/linuxdeploy becomes the binary you ship | SHA-256 pins in `scripts/dep-checksums.sha256` for Zig, Wasmtime, Swift, linuxdeploy, appimagetool. Dockerfiles copy that file and `verify-sha256.sh` next to `linux-deps.sh` before `--install`. | No GPG. `swift:5.10.1-jammy` and `archlinux:base-devel` are tag-pinned, not digest-pinned. |

## Attack surface inventory

No TCP/HTTP listener, webhook, or `serve` command. `parseCLIArguments(["serve"])` is an unknown command (`CLIParse.swift`, `ScanTests.swift`).

### Process entry points

| Entry | Where | What it accepts |
|---|---|---|
| CLI argv | `Sources/AppAtticCLI/main.swift`, `Sources/AppAtticScan/CLIParse.swift` | Commands `report`, `leftovers`, `stale`, `outdated`, `packages`, `update`. Flags `--json FILE`, `--include-system`, `--fresh`, `--dry-run`, `--top N`, `--category`, `--leftovers-only`, `--stale-only`, `--no-color`, `--version`, `--help`. |
| Linux Qt argv | `ui/linux-qt/main.cpp` | `--version`, `--help`, `--smoke`, then `QApplication`. |
| WASM host stub | `core/host/stub.c` | Paths to `core.wasm` and plugin `.wasm[=tag]`. |
| macOS UI | `Sources/AppAttic/App.swift`, `ContentView.swift` | Clicks, search, selection, Settings toggles, Preview/Delete/Update. |
| Linux Qt UI | `ui/linux-qt/main.cpp` | Same jobs as macOS UI against WASM findings. |

### Environment

| Variable | Where | Role |
|---|---|---|
| `APPATTIC_CORE_OUT` | `ui/linux-qt/corehost.cpp`, `run.sh` | Directory of `appattic_core.wasm` and plugins. AppImage and `./run.sh --ui` set this. Untrusted if an attacker can write that directory or the variable. |
| `APPATTIC_PAGE` | `ContentView.swift`, `ui/linux-qt/main.cpp` | Initial sidebar page (`overview`, `leftovers`, `stale`, `outdated`, `packages`, `disk`, `settings`). Not a privilege control. |
| `APPATTIC_HOST_EXEC_LIVE` | `core/host/hostexec.c` | Forces `execvp` of allowlisted queries (default on Linux). |
| `APPATTIC_HOST_EXEC_FIXTURE` | `core/host/hostexec.c` | Injects canned stdout (default on Darwin). |
| `FLATPAK_ID` | `core/host/hostexec.c`, `ui/linux-qt/corehost.cpp` | Set by Flatpak. Live `host.exec` wraps `flatpak-spawn --host`. Plugin tags also search `/run/host/usr/bin`. |
| `XDG_DATA_HOME` / `XDG_*` | `Cache.swift`, `Settings.swift`, `Discover.swift`, `ui/linux-qt/settings.cpp` | Settings and scan-cache location; leftover roots. |
| `PATH`, `USER`, `LOGNAME`, `LANG`, `NO_COLOR` | `Util.swift`, `CLIParse` help, CLI color | Binary resolution and display. `whichCommand` searches `PATH` plus Homebrew paths. |
| `HOMEBREW_NO_AUTO_UPDATE` | set by `runCommand` in `Util.swift` | Stops brew from self-updating during scans. |

### Files parsed (untrusted relative to the process)

| File | Where | Trust |
|---|---|---|
| `settings.json` | `Sources/AppAtticScan/Settings.swift`, `ui/linux-qt/settings.cpp` | Local. Unknown keys / bad types are errors. Missing file → defaults (`confirmDelete` true, `includeSystem` false). |
| `last-scan.json` | `Sources/AppAtticScan/Cache.swift` | Trusted if fingerprint, `includeSystem`, and age match. No signature. Becomes leftover/stale/outdated rows. |
| Homebrew / apt / pacman / paru / yay / dnf / yum / zypper / Flatpak / Snap / npm / pipx stdout | `Outdated.swift`, `Packages.swift`, `BrewInfo.swift`, WASM plugins | Treated as structured inventory. |
| iTunes Lookup JSON | `Outdated.swift` `itunesRequest` | HTTPS `https://itunes.apple.com/lookup`, 12s timeout. Used for App Store version/title/description only (report-only). |
| Desktop files, plists, XBEL, shell history | `Discover.swift`, `Leftovers.swift`, `Usage.swift` | Local FS. History capped at 500_000 lines. |
| Plugin `.wasm` | `core/host/embed.c`, `ui/linux-qt/corehost.cpp` | Loaded if the file exists. ABI 1 required. Not signed. |

### Spawned processes

| Spawn | Where | Notes |
|---|---|---|
| `Process` of package managers | `Util.swift` `runCommand` | argv array, stdin `/dev/null`, 60s timeout then SIGTERM/SIGKILL. Absolute path or `whichCommand`. |
| `/bin/sh` on a temp `.sh` | `AppAtticCLI/main.swift` `runShellScript`; `Sources/AppAttic/Scanner.swift` `runTempScript`; `ui/linux-qt/main.cpp` `runScript` | This is the destructive path. CLI uses it for `update`. UIs use it for delete/update/mark-manual. |
| `host.exec` → `execvp` | `core/host/hostexec.c` | Query allowlist only. |
| `/usr/bin/open -R` / `xdg-open` | `ContentView.swift` `revealPath` | Reveals a listed path. |
| `QProcess` | `ui/linux-qt/main.cpp` | Same as `/bin/sh` script runner. |

### Not present

No HTTP server, no RPC, no message consumer, no webhook, no scheduled job inside the app, no IPC server, no admin port, no debug endpoint in the shipped binaries. `--smoke` is a Qt widget smoke test (`ui/linux-qt/smoke.cpp`), not a network probe.

Build/CI downloads (Zig, Wasmtime, linuxdeploy, Swift tarball, `swift-cross-ui` 0.2.1) are a separate build-time surface (`scripts/linux-deps.sh`, `scripts/linux-appimage.sh`, `Package.swift`, `.github/workflows/linux.yml`).

## Trust boundaries and data flow

### 1. User → app (no authentication)

There is no app identity. Whoever can run `appattic` or the UI is the operator. Confirmation is a UI setting, not authn.

Privilege transition: the process is the user. Generated scripts call `pacman`, `apt-get`, `dnf`, `zypper`, `snap`, `flatpak`, `brew`, `launchctl bootout` (`Cleanup.swift` `leftoverRemoveCommand`, `Packages.swift` `packageRemoveCommand`). Those tools may prompt for root. AppAttic does not call `sudo` itself.

CLI `--include-system` can only turn *on* including OS apps; it cannot turn a true `settings.json` value off (`Settings.swift` `effectiveIncludeSystem`).

### 2. App → filesystem (home and system inventory)

Scan roots are user XDG/Library trees plus listed home dots (`Leftovers.swift` `scanRootsForPlatform`, `homeDotData`). Overlay scan also looks at `/usr/bin` and similar as *package* dirs to detect shadows, and must not `rm` those packaged paths (Qt `isProtectedPackagedPath`; Swift leftover commands quote the overlay path, not `/usr/bin/flatpak` — README and `DESIGN.md`).

### 3. App → package managers (stdout is data)

`runCommand` / `host.exec` collect text. Parsers (`parseBrewOutdatedJSON`, `parsePacmanOrphans`, `parseAptAutoremove`, plugin JSON) turn that text into names that later become `shellQuote(name)` in uninstall/upgrade lines. A compromised `brew` on `PATH` is a compromised inventory.

### 4. App → internet

- macOS App Store outdated: `URLSession` to `itunes.apple.com/lookup` (`Outdated.swift`).
- Homebrew and Flatpak commands may hit their own CDNs when `update` runs, and during `brew outdated` / `flatpak` queries.
- No other in-process HTTP client.

### 5. Plugin WASM → host

Plugins import only `host.exec` (`embed.c` `wasmtime_linker_define_func`). Default Wasmtime engine: no WASI, so no direct open/read of the host FS. Findings JSON is copied out and parsed by Qt (`finding.cpp` `appendFindingsFromBlob`). `command` / `updateCommand` fields flow into the script.

Linux default: live `execvp` (`hostexec.c` `use_fixture`). Darwin default: fixtures.

### 6. Secrets → code

AppAttic does not store service credentials. It *reads* user files that may contain them (`.aws`, `.docker`, `.kube`, `.ssh` as scan targets; shell history for usage). `settings.json` and `last-scan.json` are written atomically but not mode 0600. Temp scripts live under the process temp dir; Qt sets owner rwx (`main.cpp`), Swift does not set an explicit mode.

### 7. Build → runtime

Pinned SHA-256 for Zig, Wasmtime C API, Swift Linux tarball, linuxdeploy, and appimagetool (`scripts/dep-checksums.sha256`, `verify-sha256.sh`). macOS app is ad-hoc codesigned (`build.sh` `codesign --force --sign -`). AppImage is not signed in-tree. Docker base images are version tags, not digests.

## Assets and impact

| Asset | Where it lives | If stolen / corrupted / denied |
|---|---|---|
| User leftover dirs and overlay binaries | Home, `~/Library`, XDG, `~/.local/bin` | `rm -rf` of the listed path. Wrong row → wrong delete. |
| Installed apps / brew casks / Flatpak / Snap | Paths from discover + package managers | Uninstall via generated script. Steam/CrossOver are comments, not `rm` (`Cleanup.swift`). |
| Distro packages and language globals | `Packages.swift` / WASM plugins | `apt-get purge -y`, `pacman -Rns`, `npm -g uninstall`, etc. |
| Cloud and tool credentials on disk | `.aws` (scanned), `.ssh`/`.gnupg` (scanned but classified system) | Delete or disclose via `--json` / cache. |
| Scan cache and settings | `last-scan.json`, `settings.json` | Hide leftovers (ignore list), skip confirm, poison findings. |
| Host `PATH` binaries | `whichCommand` | Fake `brew`/`flatpak` during scan or update. |
| WASM modules | `APPATTIC_CORE_OUT` / `usr/share/appattic` | Fake findings and `command` strings. |
| Availability of the user session | scan workers, `du`, plugin loops | Local DoS (CPU/IO), not a remote amp. |

Impact is local and user-scoped, not a multi-tenant data breach. The concrete worst case is irreversible delete of the operator's software and leftover data, including credential directories the classifier failed to mark `system`.

## Threats per boundary

### User → app

- **Spoofing:** none at app layer; OS user is the principal.
- **Tampering:** `settings.json` `confirmDelete: false` removes the UI stop. `ignoredLeftoverPaths` hides real leftovers (availability of the warning, not of the files).
- **Repudiation:** no audit log of scripts that ran. Temp `.sh` is deleted after use (`Scanner.swift`, Qt `QFile::remove`).
- **Disclosure:** `--json FILE` writes the full scan (paths, versions) to an operator-chosen path (`main.swift`). Cache holds the same.
- **DoS:** `--top` is bounded; leftover measurement uses `pmap` workers and `duSize` timeouts (`Leftovers.swift`). Unbounded: size of cache JSON, number of leftover rows, history file up to 500k lines (`Usage.swift`).
- **Elevation:** CLI `update` without `--dry-run` prompts only when stdin is a TTY; redirected or automated invocations proceed directly to `runShellScript` (`AppAtticCLI/main.swift` `confirmLiveUpdate`). Distro remove scripts may ask for root via the package manager, not via AppAttic.

### App → filesystem / leftover model

- **Tampering / elevation of “delete me”:** `Identity.classify` returns `orphaned` for unknown names (`Leftovers.swift`). `homeDotData` includes `.aws`, `.docker`, `.gradle`, `.android`. `.ssh` and `.gnupg` hit `linuxSystemNames` and stay `system`. A future rename of a system dir that is not on the list will show up as leftover. Default CLI dry-run includes orphaned leftovers (`Cleanup.swift` `cleanupScript`).
- **DoS:** `probeActivityMtime` caps entries/depth/time. `duSize` 6s timeout.

### App → package managers / internet

- **Spoofing:** `whichCommand` prefers extras then `PATH`. A user-writable directory earlier on `PATH` wins for `brew`/`flatpak`.
- **Tampering:** `parseBrewOutdatedJSON` and friends take names from stdout. Those names are `shellQuote`d into `brew upgrade` / `flatpak update -y`.
- **Disclosure:** iTunes description text is shown (truncated `shortDesc`). No TLS pin.
- **DoS:** `runCommand` 60s per process; iTunes 12s + 15s wait.

### WASM guest → host

- **Elevation:** only if `appattic_host_exec_allowed` returns true for a dangerous argv. Current deny includes `rm`, `rmi`, `remove`, `purge`, `-y`, `install`, `upgrade`, pacman `-R*`, etc. (`hostexec.c` `destructive_token`). Metacharacters `;|&\`$<>` rejected in `parse_argv`.
- **Tampering:** plugin JSON `command` is used by Qt `leftoverCleanupCommand` after a narrow `/usr` `rm` filter. A plugin can emit `rm -rf /home/user/.aws`.
- **DoS:** `wasm_engine_new()` with no fuel (`embed.c`). Infinite loop in a plugin hangs the scan.
- **Disclosure:** allowlisted `ls` / package queries return host inventory into guest memory, then into the UI.

### Build → runtime

- **Tampering:** Swift tarball `curl | tar` (`linux-deps.sh` `install_swift_tarball`). Zig/Wasmtime/AppImage tools are hashed.
- **Spoofing:** ad-hoc macOS signature only (`build.sh`).

## Mitigations mapping

| Control | File | Covers | Does not cover |
|---|---|---|---|
| No network listener | CLI parse + absence of bind/listen | Remote unauthn | Local user and local files |
| UI `confirmDelete` default true; CLI `confirmLiveUpdate` on a TTY | `Settings.swift`, `ContentView.swift`, `ui/linux-qt/main.cpp`, `AppAtticCLI/main.swift` | Accidental click or interactive CLI update | Disabled UI setting; non-interactive CLI `update` |
| `--dry-run` prints, does not run (except it short-circuits before `update` run) | `CLIParse.swift`, `main.swift` | Review of leftover/stale/package scripts | Operator pasting the script into a root shell |
| `shellQuote` | `Util.swift` | Metacharacters in paths/names inside generated `sh` | A finding that should not have been listed at all |
| KEEP / `system` / untrusted-cask / no full distro upgrade | `Recommend.swift`, `Leftovers.swift`, `Outdated.swift`, `Packages.swift` | Default CLI script omits KEEP and system leftovers; no `apt upgrade` / `-Syu`; named upgrades only after confirm | REVIEW-tier if the UI user opts in; `.aws`-class misses; plugin `command` |
| Steam/CrossOver not deleted | `Cleanup.swift` `uninstallCommand` | Steam library `rm` | User running a hand-edited script |
| Qt `/usr` rm filter and overlay-only delete | `ui/linux-qt/finding.cpp` `isProtectedPackagedPath`, `leftoverCleanupCommand` | `rm` of packaged `/usr` paths in the Qt UI | Swift leftover `rm`; Qt commands that are not `rm` |
| `host.exec` allowlist | `core/host/hostexec.c`, `hostexec.h` | WASM spawn of destructive argv | Plugin-authored cleanup JSON; Swift `Process` path (separate, argv-array) |
| No WASI | `core/host/embed.c` | Guest file I/O | `host.exec` and findings JSON |
| Untrusted brew tap | `BrewInfo.swift` `refusedCasks`, `applyUntrustedCasks` | `brew upgrade --cask` of refused casks | Listing them; other managers |
| `HOMEBREW_NO_AUTO_UPDATE` | `Util.swift` | Surprise brew self-update during scan | `update` script, which is `brew upgrade` |
| Scan cache fingerprint + max age 24h | `Cache.swift` | Stale cache after installs | Forged cache with a copied live fingerprint |
| Atomic settings/cache writes | `Settings.swift`, `Cache.swift` | Torn JSON | Permissions / MAC |
| SHA-256 of build tools | `scripts/dep-checksums.sha256` | Zig, Wasmtime, linuxdeploy, appimagetool | Swift tarball |
| `runCommand` timeout | `Util.swift` | Hung package-manager query | WASM fuel; UI script `waitUntilExit` with no timeout |

### Claim vs code

`README.md` says CLI updates run immediately, while `AppAtticCLI/main.swift` `confirmLiveUpdate` prompts when stdin is a TTY and deliberately proceeds without a prompt otherwise. The CLI help accurately states “prompts on a TTY.”

`README.md` “Nothing is deleted until you review a script or confirm in the UI” matches leftover/stale/packages CLI. `update` upgrades packages rather than deleting scan findings and has the TTY-dependent behavior above.

### Single points of failure

1. **Operator confirmation** (or its absence for non-interactive CLI `update`) is the control in front of every high-impact delete/upgrade.
2. **`appattic_host_exec_allowed`** is the control in front of every WASM-spawned process.
3. **Leftover `system` name lists** are the control in front of deleting home-dot credential trees.

## Abuse cases

These are hostile-but-local scenarios. Evidence is the code path, not an exploit.

1. **Skip the confirm dialog.** Settings → `confirmDelete` false (`ContentView.swift` `confirmDeleteBinding`, Qt `m_confirmBox`). Delete/Update/Mark Manual run `runTempScript` / `runScript` on the first click.
2. **Non-interactive CLI upgrade without review.** With stdin redirected, `appattic update` → `confirmLiveUpdate` returns true → `updateScript` → `runShellScript` (`main.swift`). This supports automation but bypasses the interactive review gate.
3. **Poison `last-scan.json`.** Write a cache with the current fingerprint, `includeSystem` matching the next run, `scanned_at` within 24h, and an extra leftover path. `resolveScan` will use it (`Cache.swift`). The UI/CLI then offers that path in cleanup.
4. **Swap WASM under `APPATTIC_CORE_OUT`.** Qt loads `appattic_core.wasm` and a fixed plugin filename list (`corehost.cpp`). A replaced plugin can return findings whose `command` is copied into the script (`finding.cpp`). `host.exec` still cannot `rm`, but the *script the user confirms* can.
5. **PATH hijack.** Put a fake `brew` on `PATH`. Scan and `update` invoke it (`whichCommand`, `updateCommand`).
6. **Classifier miss.** If AWS CLI is not discovered as installed software, `.aws` classifies as `orphaned` (`homeDotData` + `classify` fallthrough). Default leftover dry-run emits `rm -rf` of that path (`leftoverRemoveCommand`).
7. **`--json` overwrite.** `--json FILE` writes scan JSON to `FILE` with no directory jail (`main.swift`). Same user, arbitrary path they can write.
8. **Disable confirm via settings file.** Directly edit `settings.json` (no integrity). Same as (1).

Client-side enforcement: the ignore list and confirm toggle are local files, not a server policy. There is no server.

## Response readiness (note only)

- Scripts run with stdout discarded (UI) and stderr kept only until the process exits; the temp file is deleted. There is no durable “what we deleted” log in-tree.
- No disclosure contact, supported-version list, or “report → fix shipped” path is published. See `SECURITY.md`.

## How to re-verify this file

Re-walk: `CLIParse.swift`, `AppAtticCLI/main.swift`, `Cleanup.swift`, `Packages.swift`, `Outdated.swift`, `Settings.swift`, `Cache.swift`, `Leftovers.swift` (`homeDotData`, `linuxSystemNames`, `classify`), `Util.swift` (`runCommand`, `shellQuote`, `whichCommand`), `Scanner.swift` `runTempScript`, `ui/linux-qt/main.cpp` `runScript`, `ui/linux-qt/finding.cpp`, `ui/linux-qt/corehost.cpp`, `core/host/embed.c`, `core/host/hostexec.c`, `scripts/linux-deps.sh`, `scripts/dep-checksums.sha256`. If an entry point, allowlist, or confirm path changes, update the matching row here in the same change.
