# Threat model: AppAttic

Last reviewed: 2026-09-27.

No owner or review cadence is published. This file is the living model of the attack surface. Point fixes belong in application code reviews, not here.

AppAttic is a local cleanup utility (CLI `appattic`, macOS AppKit UI, Linux Qt 6 UI, Zig WASM scan core). It is not a network service. There is no login, tenant isolation, or remote API. The process runs as the OS user who launched it. The blast radius is that user's files, packages, and any privilege those package managers can obtain (polkit/sudo).

## Risk-ranked summary

| Rank | Risk | Boundary | Impact | Existing control | Gap |
|---|---|---|---|---|---|
| 1 | A generated `/bin/sh` script runs `rm -rf`, `brew uninstall`, `flatpak uninstall -y`, `snap remove`, or distro `purge`/`-Rns` against scan results | User → app (script execution) | Permanent loss of apps, leftover data, or packages | UI confirm dialog when `confirmDelete` is true; interactive CLI `update` prompt; `shellQuote`; KEEP/system leftovers excluded from default CLI dry-run; Qt refuses a plugin command carrying shell metacharacters (`finding.cpp` `commandIsShellSafe`, `main.cpp` `scriptLine`) | Non-interactive CLI `update` deliberately proceeds without a prompt. UI confirm can be turned off. Scripts are the only gate between a bad finding and a destructive argv. The script inherits `cleanupPathDirectories()` ahead of `PATH` (`Process.swift:79`, `Paths.swift:201`), so `rm`, `pkexec`, and `sudo` inside a confirmed script resolve from `~/.local/bin` and `~/bin` first. `rootcmd` (`Cleanup.swift:378`) is what turns a fake `pkexec` into root. |
| 2 | Disk page trashes any path the walk reached, with no packaged-path filter | Qt disk page → filesystem | Irreversible loss of arbitrary files, including `/etc` children, after a "Move to Trash" confirm | One `QMessageBox` confirm; walk is one-filesystem by default | `trashSelected` calls `QFile::moveToTrash` on the selected node with no `isProtectedPackagedPath` check and no scope limit, and `scanFilesystem` starts the walk at `/` (`diskpage.cpp:575`, `:803`). The `/usr` deny used for leftover `rm` (`finding.cpp:419`) does not apply here at all. |
| 3 | Scan cache or WASM plugin JSON is treated as a trusted finding list and becomes cleanup commands | Build/runtime plugins; cache file → app | Attacker-chosen paths or package names in the script the user is asked to run | Cache fingerprint + 24h age and owner-only mode (`Cache.swift`). WASM `host.exec` query allowlist (`hostexec.c`). Qt drops `rm` of `/usr`, `/etc`, `/System`, and friends (`finding.cpp` `commandRemovesProtectedPath`) and refuses metacharacters (`commandIsShellSafe`). Cache and settings are owner-only, so a cache edit needs the same user. | Cache has no MAC. Plugin `.wasm` is unsigned, and the plugin list is a `*.wasm` glob of the core-out directory, so any file dropped there is loaded. `APPATTIC_HOST_EXEC_LIVE` downgrades the macOS fixture default to live `execvp` (`hostexec.c:459`), and a plugin command made only of allowlisted bytes runs verbatim. Swift leftover `rm` has no `/usr` deny, and `/etc/apt/sources.list.d` rows are re-permitted past it on purpose (`Cleanup.swift:324`, `core/src/apt.zig:189`), so those rows prompt for root. |
| 4 | Leftover classifier lists a credential or config tree as orphaned (`rm -rf ~/.m2` and similar) | Filesystem → leftover model | Secret loss | `linuxSystemNames` marks `aws`, `docker`, `kube`, `ssh`, `gnupg`, `npm`, `cargo`, `rustup` as `system`, and `classify` compares the dot-stripped name, so `.aws`/`.ssh`/`.gnupg` stay out of the script (`Leftovers.swift:35`, `:1814`, `classifyLinuxSystemName:230`) | `mozilla`, `thunderbird`, `m2`, `gradle`, `java` and `android` are scanned home leaves with no entry in the system-name set. If the owning app is not discovered (a Flatpak or store build, not the `firefox`/`wine` name the alias table knows), `.mozilla` and `.thunderbird` classify `orphaned`, and those trees hold `logins.json` / `key4.db`; `.m2/settings.xml` and `.gradle/gradle.properties` hold repository and cloud credentials. |
| 5 | `host.exec` is the only host import; a bug there is WASM breakout to process spawn | WASM guest → host | Arbitrary subprocess if allowlist fails | Allowlist + metacharacter reject + destructive-token deny (`hostexec.c:161`, `:38`, `:152`). No WASI filesystem. 60s cap per spawn, own process group, SIGTERM then SIGKILL to the group (`hostexec.c:24`, `reap_child:808`). | No Wasmtime fuel/epoch, so a spinning guest is bounded only by the operator cancelling. `APPATTIC_CORE_OUT` loads whatever `.wasm` files are there. `APPATTIC_HOST_EXEC_LIVE` is checked before the Darwin default (`hostexec.c:459`), so on macOS it turns the shipped fixture mode into live `execvp` for the whole core, and `flatpak-spawn --host` forwards the rewritten `PATH` to the host (`hostexec.c:859`). |
| 6 | Outdated / brew / Flatpak talk to the network; answers are parsed as versions and names | App → internet | Wrong upgrade target; attacker who owns the tap/index influences `brew upgrade` / `flatpak update` | Untrusted Homebrew casks listed, not updated (`BrewInfo.swift` `refusedCasks`, `Outdated.swift` `applyUntrustedCasks`). Named distro upgrades run only after confirm as `/bin/sh`, never via `host.exec`. App Store stays report-only. `HOMEBREW_NO_AUTO_UPDATE=1` for a resolved `brew` binary (`Process.swift:115`). | iTunes lookup is HTTPS with no pinning. Package-manager stdout is trusted JSON/text. |
| 7 | Build scripts download toolchains | Build → runtime | Compromised zig/wasmtime/Swift/linuxdeploy becomes the binary you ship | SHA-256 pins in `scripts/dep-checksums.sha256` for Zig, Wasmtime, Swift, linuxdeploy, appimagetool. Dockerfiles copy that file and `verify-sha256.sh` next to `linux-deps.sh` before `--install`. `scripts/deps.sh check` runs in `scripts/lint.sh` and fails if a pin, a download URL, or a Flatpak `sha256:` drifts. | No GPG. `swift:5.10.1-jammy` and `archlinux:base-devel` are tag-pinned, not digest-pinned. The distro package layer (Qt 6, cmake, ninja, clang, patchelf, shellcheck) is not hashed at all, and `linux.yml` runs the checked-out tree as root in a container on every `pull_request`. |

## Attack surface inventory

No TCP/HTTP listener, webhook, or `serve` command. `parseCLIArguments(["serve"])` is an unknown command (`CLIParse.swift`, `ScanTests.swift`).

### Process entry points

| Entry | Where | What it accepts |
|---|---|---|
| CLI argv | `Sources/AppAtticCLI/main.swift`, `Sources/AppAtticScan/CLIParse.swift` | Commands `config`, `report`, `leftovers`, `stale`, `outdated`, `packages`, `update`, `disk`. Flags `--json FILE`, `--include-system`, `--fresh`, `--dry-run`, `--top N`, `--category`, `--leftovers-only`, `--stale-only`, `--no-color`, `--all-file-systems`, `--allocated`, `--yes`/`-y`, `--version`/`-v`, `--help`/`-h`; the value flags also take `--json=FILE`, `--top=N`, `--category=NAME` (`CLIParse.swift:294`, `:315`, `:335`). `disk` takes an optional positional root, used as given: `appattic disk /etc` walks and reports `/etc` (`CLIParse.swift:357`, `main.swift:162`). `config` prints the settings path, cache path, all four XDG homes, and `XDG_DATA_DIRS` unredacted, and with `--json FILE` writes the same to an operator-chosen path (`main.swift:142`, `Settings.swift:163`). |
| Linux Qt argv | `ui/linux-qt/main.cpp` | `--version`, `--help`, `--smoke`, then `QApplication`. Debug builds also take `--dev-check <table|stream|disk|shot>` for CI gates and offscreen renders; `NDEBUG` drops it (`main.cpp:3238`). |
| WASM host stub | `core/host/stub.c` | Paths to `core.wasm` and plugin `.wasm[=tag]`, passed straight through (`stub.c:58`). |
| macOS UI | `Sources/AppAttic/App.swift`, `ContentView.swift`, `DiskUsageView.swift` | Clicks, search, selection, Settings toggles, Preview/Delete/Update, and a free-text "Folder path" field that is scanned as given (`DiskUsageView.swift:47`, `:170`). |
| Linux Qt UI | `ui/linux-qt/main.cpp`, `diskpage.cpp` | Same jobs as macOS UI against WASM findings, plus the disk page: scan folder, scan filesystem (`/`), scan mounted network folder under `XDG_RUNTIME_DIR/gvfs`, open selected, copy path, move selected to Trash (`diskpage.cpp:565`, `:575`, `:577`, `:790`, `:797`, `:803`). |

### Environment

| Variable | Where | Role |
|---|---|---|
| `APPATTIC_CORE_OUT` | `ui/linux-qt/corehost.cpp`, `run.sh` | Directory of `appattic_core.wasm` and plugins. AppImage and `./run.sh --ui` set this. Untrusted if an attacker can write that directory or the variable. |
| `APPATTIC_PAGE` | `ContentView.swift`, `ui/linux-qt/main.cpp` | Initial sidebar page (`overview`, `leftovers`, `stale`, `outdated`, `packages`, `disk`, `settings`). Not a privilege control. |
| `APPATTIC_HOST_EXEC_LIVE` | `core/host/hostexec.c:531` | Checked *before* the Darwin default, so it forces `execvp` of allowlisted queries even on macOS, where fixtures are otherwise the shipped mode. A sandbox-downgrade switch, not a debug toggle. |
| `APPATTIC_HOST_EXEC_FIXTURE` | `core/host/hostexec.c:535` | Injects canned stdout. Default on Darwin, opt-in elsewhere. Both switches are read by `env_flag`: `1`/`true`/`yes`/`on` is on, `0`/`false`/`no`/`off`/empty/unset is off, and any other value is reported on stderr and read as off, so the variable that picks live exec cannot be turned on by a value that reads as false. |
| `FLATPAK_ID` | `core/host/hostexec.c`, `ui/linux-qt/corehost.cpp` | Set by Flatpak. Live `host.exec` wraps `flatpak-spawn --host` and forwards `--env=PATH=` across the sandbox boundary (`hostexec.c:859`). Plugin tags also search `/run/host/usr/bin`. |
| `XDG_CONFIG_HOME` / `XDG_DATA_HOME` / `XDG_CACHE_HOME` / `XDG_STATE_HOME` | `Paths.swift:9`, `Cache.swift`, `Settings.swift`, `Leftovers.swift:259` | Settings and scan-cache location, and leftover *scan roots*: any absolute value is walked and its children become leftover rows, so `XDG_CONFIG_HOME=/etc` puts `/etc` children in the cleanup script. |
| `XDG_DATA_DIRS` | `Paths.swift:50`, `Discover.swift:135` | Adds `<dir>/applications` to the parsed desktop-file set. |
| `XDG_RUNTIME_DIR` | `ui/linux-qt/diskpage.cpp:578` | Selects the gvfs mount directory the remote disk scan starts from. |
| `ANDROID_HOME`, `ANDROID_SDK_ROOT` | `Sources/AppAtticScan/Leftovers.swift:1766` | Decides whether a real Android SDK is present, which suppresses the `.android` leftover row. |
| `HOME` | `core/host/hostexec.c:403` | Prepends `~/.local/bin`, `~/bin`, `~/.bun/bin` and friends to the child `PATH`, and rewrites plugin argv tokens starting `/home/<user>`. |
| `PATH`, `USER`, `LOGNAME`, `LANG`, `NO_COLOR`, `COLORFGBG`, `TERM` | `Process.swift`, `CLIParse.swift:248`, `:266`, `Paths.swift:201` | Binary resolution and display. `whichCommand` searches `PATH` plus user bin dirs first, and `augmentedProcessEnvironment` hands the generated script the same order, so `PATH` decides what `rm` and `pkexec` mean inside a confirmed script. |
| `HOMEBREW_NO_AUTO_UPDATE` | set by `runCommand` in `Process.swift:115` | Set only when the resolved binary's basename is `brew`. Stops brew from self-updating during scans. |

### Files parsed (untrusted relative to the process)

| File | Where | Trust |
|---|---|---|
| `settings.json` | `Sources/AppAtticScan/Settings.swift`, `ui/linux-qt/settings.cpp` | Local. Unknown keys / bad types are errors. Missing file → defaults (`confirmDelete` true, `includeSystem` false). |
| `last-scan.json` | `Sources/AppAtticScan/Cache.swift` | Trusted if fingerprint, `includeSystem`, and age match. No signature. Becomes leftover/stale/outdated rows. |
| Homebrew / apt / pacman / paru / yay / dnf / yum / zypper / Flatpak / Snap / npm / pipx stdout | `Outdated.swift`, `Packages.swift`, `BrewInfo.swift`, WASM plugins | Treated as structured inventory. |
| iTunes Lookup JSON | `Outdated.swift` `itunesRequest` | HTTPS `https://itunes.apple.com/lookup`, 12s timeout. Used for App Store version/title/description only (report-only). |
| Desktop files, plists, XBEL, shell history | `Discover.swift`, `Leftovers.swift`, `Usage.swift` | Local FS. History capped at 500_000 lines. |
| Plugin `.wasm` | `core/host/embed.c`, `ui/linux-qt/corehost.cpp` `pluginWasmFiles` | Loaded if the file exists. ABI 1 required (`embed.c` `plugin_abi_version`). The list is a `*.wasm` glob of the core-out directory minus `appattic_core.wasm`, not a fixed list, so a file dropped in that directory is a loaded plugin. Not signed. |

### Spawned processes

| Spawn | Where | Notes |
|---|---|---|
| `Process` of package managers | `Process.swift` `runCommand` | argv array, stdin `/dev/null`, 60s timeout then SIGTERM/SIGKILL. Absolute path or `whichCommand`. |
| `/bin/sh` on a temp `.sh` | `AppAtticCLI/main.swift` `runShellScript`; `Sources/AppAttic/Scanner.swift` `runTempScript`; `ui/linux-qt/main.cpp` `runScript` | This is the destructive path. CLI uses it for `update`. UIs use it for delete/update/mark-manual. Owner-only file; only the Qt path creates the file exclusively. No timeout on any of the three: `waitUntilExit` until the script ends. |
| `host.exec` → `execvp` | `core/host/hostexec.c` | Query allowlist only. |
| `/usr/bin/open -R` / `xdg-open` | `ContentView.swift` `revealPath` | Reveals a listed path. |
| `QProcess` | `ui/linux-qt/main.cpp` `runScript` | Same as `/bin/sh` script runner, but on the raw `QProcessEnvironment::systemEnvironment()` `PATH` (`main.cpp:2848`). |
| `QFile::moveToTrash`, `QDesktopServices::openUrl` | `ui/linux-qt/diskpage.cpp:803`, `:792` | Any path the disk walk reached, with no packaged-path filter. |
| `flatpak-spawn --host <manager>` | `core/host/hostexec.c:859` | Runs an allowlisted query on the host from inside the sandbox, carrying `PATH` across. |

### Not present

No HTTP server, no RPC, no message consumer, no webhook, no scheduled job inside the app, no IPC *server*, no admin port, no debug endpoint in the shipped binaries. `--smoke` is a Qt widget smoke test (`ui/linux-qt/smoke.cpp:264`), not a network probe. The one IPC *client* surface is the Flatpak session bus and the file-manager portal, granted by the manifest (see boundary 8).

### Build and CI surface

`scripts/linux-deps.sh`, `scripts/linux-appimage.sh`, `Package.swift`, and `.github/workflows/linux.yml` fetch Zig, Wasmtime, linuxdeploy, the Swift tarball, and `swift-cross-ui` 0.2.1. The hashed subset is listed under boundary 7. Two things are not covered by any pin: the distro package layer (Qt 6, cmake, ninja, clang, patchelf, `shellcheck`) installs from whatever mirror the runner trusts, and `linux.yml` runs `on: pull_request` in a `swift:5.10.1-jammy` / `archlinux:base-devel` container as root over the checked-out tree. It is bounded by `permissions: contents: read`, `persist-credentials: false`, and SHA-pinned actions (`.github/workflows/linux.yml:4`, `:8`). `release.yml` runs on tags and `workflow_dispatch` with `contents: write`; its `VERSION` is passed as an env var, not interpolated into a shell line. `Dockerfile` and `Dockerfile.arch` have no `USER` directive.

## Trust boundaries and data flow

### 1. User → app (no authentication)

There is no app identity. Whoever can run `appattic` or the UI is the operator. Confirmation is a UI setting, not authn.

Privilege transition: the process is the user. Generated scripts call `pacman`, `apt-get`, `dnf`, `zypper`, `snap`, `flatpak`, `brew`, `launchctl bootout` (`Cleanup.swift` `leftoverRemoveCommand`, `Packages.swift` `packageRemoveCommand`). Those tools may prompt for root. AppAttic never spells `sudo` itself, but it emits `rootcmd`, which does `$(id -u)`, `command -v pkexec`, then `sudo "$@"` or `pkexec` (`Cleanup.swift:378`), so the privilege step is delegated to whatever `pkexec` the script's `PATH` finds first.

That `PATH` is AppAttic's own: both Swift script runners hand `/bin/sh` the environment from `augmentedProcessEnvironment` (`Process.swift:79`, `Scanner.swift:486`, `AppAtticCLI/main.swift:456`), which puts `cleanupPathDirectories()` ahead of the inherited value, and that list contains `~/.local/bin` and `~/bin` before `/usr/bin` (`Paths.swift:201`). A `pkexec` or `rm` in either directory is what a confirmed script runs. This is the sharpest undocumented boundary in the project: the script is the trust boundary, and the script's own `PATH` is attacker-writable.

CLI `--include-system` can only turn *on* including OS apps; it cannot turn a true `settings.json` value off (`Settings.swift` `effectiveIncludeSystem`).

### 2. App → filesystem (home and system inventory)

Scan roots are user XDG/Library trees plus listed home dots (`Leftovers.swift` `scanRootsForPlatform`, `homeDotData`), and the XDG roots come from the environment, so they are whatever the user or a launcher points them at.

The disk page is a second, wider door into the same filesystem. `appattic disk <path>` and the macOS "Folder path" field scan the path as given, validated only as an existing directory (`DiskUsage.swift:182`); the Qt page can walk `/` outright and can walk a gvfs/sshfs/SMB mount (`diskpage.cpp:575`, `:577`). Nothing on this path is limited to home. Overlay scan also looks at `/usr/bin` and similar as *package* dirs to detect shadows, and must not `rm` those packaged paths (Qt `isProtectedPackagedPath`; Swift leftover commands quote the overlay path, not `/usr/bin/flatpak`, per README and `DESIGN.md`). One packaged prefix is deliberately reachable anyway: `/etc/apt/sources.list.d` rows come back as `review` findings (`core/src/apt.zig:189`) and `isPpaSourcesPath` re-permits them past `isProtectedPackagedPath` (`Cleanup.swift:324`), so a root-prompting `rm` under `/etc` is a first-class output, not an accident.

### 3. App → package managers (stdout is data)

`runCommand` / `host.exec` collect text. Parsers (`parseBrewOutdatedJSON`, `parsePacmanOrphans`, `parseAptAutoremove`, plugin JSON) turn that text into names that later become `shellQuote(name)` in uninstall/upgrade lines. A compromised `brew` on `PATH` is a compromised inventory, and `whichCommand` looks in `~/.local/bin`, `~/bin`, `~/.bun/bin`, `~/.cargo/bin` before `/usr/bin` (`Process.swift:14`), so a user bin dir wins even when `PATH` does not list it early.

### 4. App → internet

- macOS App Store outdated: `URLSession` to `itunes.apple.com/lookup` (`Outdated.swift`).
- Homebrew and Flatpak commands may hit their own CDNs when `update` runs, and during `brew outdated` / `flatpak` queries.
- No other in-process HTTP client.

### 5. Plugin WASM → host

Plugins import only `host.exec` (`embed.c` `wasmtime_linker_define_func`). Default Wasmtime engine: no WASI, so no direct open/read of the host FS. Findings JSON is copied out and parsed by Qt (`finding.cpp` `appendFindingsFromBlob`). `command` / `updateCommand` fields flow into the script.

Linux default: live `execvp` (`hostexec.c` `use_fixture`). Darwin default: fixtures.

### 6. Secrets → code

AppAttic does not store service credentials. It *reads* user files that may contain them (`.aws`, `.docker`, `.kube`, `.ssh`, `.gnupg`, plus the mail and build trees listed under risk 4; shell history for usage) and can print any of it through `--json FILE`, `config`, and the cache. `settings.json` and `last-scan.json` are written atomically and then owner-only: `restrictPrivateDataFile` sets `0600` and `0700` on a parent directory named `appattic` (`FilePermissions.swift`, `Settings.swift:244`, `Cache.swift:75`). Generated temp scripts are owner-only too: Swift writes them with `writeOwnerOnlyFile` (`Scanner.swift:473`, `AppAtticCLI/main.swift:443`), Qt with `QTemporaryFile`, which creates the file exclusively, then narrows it to `rwx` for the owner (`ui/linux-qt/main.cpp` `runScript`). `--json FILE` is written with `writeOwnerOnlyFile` too, but through a caller-supplied path, so the parent directory is not the appattic one (`main.swift:74`).

The residual risk is the parent, not the file: `FileManager.default.temporaryDirectory` and `QDir::temp()` are the shared world-writable temp directory, so a name is visible to other local users between write and `/bin/sh` execution. The Qt path is closed against that (exclusive create); the Swift path is not, only the `0600` mode stands between it and a same-host account that can watch the directory. Mode bits are the whole control there.

### 7. Flatpak sandbox → host

The Linux Flatpak build is not confined the way a sandbox is expected to be. `finish-args` grants `--filesystem=host` (read *and write* on every host path), `--share=ipc`, `--talk-name=org.freedesktop.Flatpak`, `--talk-name=org.freedesktop.FileManager1`, `--socket=wayland`, `--socket=fallback-x11`, `--device=dri` (`packaging/flatpak/org.appattic.AppAttic.yml:9`). The manifest comment says the host filesystem is needed because the scans walk real paths, but the grant is bidirectional and covers system paths, which is wider than the app's own behavior needs. `host.exec` leaves the sandbox through `flatpak-spawn --host` and passes its `PATH` with it (`hostexec.c:859`), and `moveToTrash` leaves through the file-manager portal.

The macOS build has no equivalent confinement: `packaging/Info.plist` declares no `com.apple.security.app-sandbox` and no hardened-runtime exceptions, and `build.sh` only ad-hoc signs. An unsandboxed macOS app is bounded by the login session, which is a wider blast radius than the Flatpak description implies for the same scan.

### 8. Build → runtime

Pinned SHA-256 for Zig, Wasmtime C API, Swift Linux tarball, linuxdeploy, and appimagetool (`scripts/dep-checksums.sha256`, `verify-sha256.sh`). `scripts/deps.sh check` keeps those pins, the download URLs in the scripts, and the `sha256:` fields in `packaging/flatpak/` in agreement, and fails when a script, a manifest or a workflow spells a Zig or Wasmtime version other than the pinned one, or when CI installs a `uv tool` without the exact version `scripts/deps.sh` declares. Zig is installed from the checksummed tarball on every distro, so no unpinned package manager can supply the compiler. `scripts/deps.sh sbom` writes a CycloneDX 1.5 inventory of those artifacts and of the `Package.resolved` pins next to each release artifact. macOS app is ad-hoc codesigned (`build.sh` `codesign --force --sign -`). AppImage is not signed in-tree. Docker base images are version tags, not digests.

## Assets and impact

| Asset | Where it lives | If stolen / corrupted / denied |
|---|---|---|
| User leftover dirs and overlay binaries | Home, `~/Library`, XDG, `~/.local/bin` | `rm -rf` of the listed path. Wrong row → wrong delete. |
| Installed apps / brew casks / Flatpak / Snap | Paths from discover + package managers | Uninstall via generated script. Steam/CrossOver are comments, not `rm` (`Cleanup.swift`). |
| Distro packages and language globals | `Packages.swift` / WASM plugins | `apt-get purge -y`, `pacman -Rns`, `npm -g uninstall`, etc. |
| Cloud and tool credentials on disk | `.aws`, `.docker`, `.kube`, `.ssh`, `.gnupg` classify `system`; `.mozilla`, `.thunderbird`, `.m2`, `.gradle`, `.android` do not | Delete or disclose via `--json` / cache. The mail profiles hold `logins.json` and `key4.db`; `.m2/settings.xml` and `.gradle/gradle.properties` hold repository and cloud secrets. |
| Scan cache and settings | `last-scan.json`, `settings.json` | Hide leftovers (ignore list), skip confirm, poison findings. |
| Host `PATH` binaries | `whichCommand` for scan queries; `augmentedProcessEnvironment` for the generated script | Fake `brew`/`flatpak` during scan or update; fake `rm`/`pkexec`/`sudo` inside a script the user already confirmed. |
| WASM modules | `APPATTIC_CORE_OUT` / `usr/share/appattic` | Fake findings and `command` strings. |
| Host filesystem under Flatpak | `--filesystem=host` (`org.appattic.AppAttic.yml:15`) | Read and write of every host path from inside the sandbox. |
| Availability of the user session | scan workers, `du`, plugin loops, a wedged network mount in a disk walk | Local DoS (CPU/IO), not a remote amp. |

Impact is local and user-scoped, not a multi-tenant data breach. The concrete worst cases are irreversible delete of the operator's software and leftover data (including credential directories the classifier failed to mark `system`), a trashed system path from the disk page, and a confirmed script whose `pkexec` resolved to a user-writable directory, which is the one path in this project from a local file to root.

## Threats per boundary

### User → app

- **Spoofing:** none at app layer; OS user is the principal.
- **Tampering:** `settings.json` `confirmDelete: false` removes the UI stop. `ignoredLeftoverPaths` hides real leftovers (availability of the warning, not of the files). Both are `0600` files with no integrity check, so the trust boundary is the OS account, not the file.
- **Repudiation:** no audit log of scripts that ran. Temp `.sh` is deleted after use (`Scanner.swift`, Qt `QFile::remove`).
- **Disclosure:** `--json FILE` writes the full scan (paths, versions) to an operator-chosen path (`main.swift`). Cache holds the same.
- **DoS:** `--top` is bounded; leftover measurement uses `pmap` workers and `duSize` timeouts (`Leftovers.swift`). Unbounded: size of cache JSON, number of leftover rows, history file up to 500k lines (`Usage.swift`).
- **Elevation:** CLI `update` without `--dry-run` prompts when stdin is a TTY and exits 2 without one, unless `--yes` says the run is unattended (`AppAtticCLI/main.swift` `confirmUpdate`). Distro remove scripts may ask for root via the package manager, not via AppAttic.

### App → filesystem / leftover model

- **Tampering / elevation of “delete me”:** `Identity.classify` returns `orphaned` for unknown names (`Leftovers.swift:255`, `:1412`). Home-dot leaves are classified by their dot-stripped name, so `.aws`, `.docker`, `.kube`, `.ssh`, `.gnupg`, `.npm`, `.cargo`, `.rustup` all hit `linuxSystemNames` and stay `system`; `.mozilla`, `.thunderbird`, `.m2`, `.gradle`, `.java`, `.android` have no entry and can reach the script as `orphaned` when the owning app is not discovered. A future rename of a system dir that is not on the list will show up as leftover. Default CLI dry-run includes orphaned leftovers (`Cleanup.swift` `cleanupScript`).
- **Elevation:** `isPpaSourcesPath` re-permits `/etc/apt/sources.list.d` past the packaged-path filter and the command is root-marked (`Cleanup.swift:324`, `:354`), so one class of leftover delete is a root prompt by design.
- **Tampering (disk page):** `trashSelected` moves any selected node to Trash with only a dialog in front of it, including a child of `/` (`diskpage.cpp:803`). `isProtectedPackagedPath` guards `rm` in `finding.cpp` and nothing else.
- **DoS:** `probeActivityMtime` caps entries/depth/time. `duSize` 6s timeout. The disk walk has no per-entry deadline, only a cooperative cancel, so a hung sshfs or SMB mount blocks its worker indefinitely (`diskpage.cpp:577`, `diskusage.cpp:249`).

### App → package managers / internet

- **Spoofing:** `whichCommand` prefers extras then `PATH`. A user-writable directory earlier on `PATH` wins for `brew`/`flatpak`.
- **Tampering:** `parseBrewOutdatedJSON` and friends take names from stdout. Those names are `shellQuote`d into `brew upgrade` / `flatpak update -y`.
- **Disclosure:** iTunes description text is shown (truncated `shortDesc`). No TLS pin.
- **DoS:** `runCommand` 60s per process; iTunes 12s + 15s wait.

### WASM guest → host

- **Elevation:** only if `appattic_host_exec_allowed` returns true for a dangerous argv. Current deny includes `rm`, `rmi`, `remove`, `purge`, `-y`, `install`, `upgrade`, pacman `-R*`, etc. (`hostexec.c` `destructive_token`). Metacharacters `;|&\`$<>` rejected in `parse_argv`.
- **Tampering:** plugin JSON `command` is used by Qt `leftoverCleanupCommand` after a `/usr`-rooted `rm` filter (`commandRemovesProtectedPath`), and `scriptLine` then runs it through a byte allowlist that refuses `; | & $ \`` , redirect, and newline outside single quotes (`finding.cpp:445`, `main.cpp:2707`). A plugin can still emit `rm -rf /home/user/.aws`, which passes both. Which plugins exist is a directory listing, not an allowlist (`pluginWasmFiles`).
- **DoS:** `wasm_engine_new()` with no fuel (`embed.c`). A guest instruction loop that never calls `host.exec` runs until the operator cancels (`requestCoreWasmCancel` sets the flag the host checks between spawns, not a guest interrupt). An allowlisted spawn is capped at 60s and its process group is killed.
- **Disclosure:** allowlisted `ls` / package queries return host inventory into guest memory, then into the UI.

### Flatpak sandbox → host

- **Tampering / elevation:** `--filesystem=host` is read *and* write on every host path, so anything the app, a loaded plugin, or a spawned host command does writes to the real filesystem with no portal in between. `moveToTrash` is the one action that does go through a portal.
- **Spoofing:** `flatpak-spawn --host` forwards the sandbox `PATH` to the host (`hostexec.c:859`), so a user-writable directory that got into the in-sandbox `PATH` is also the host's resolution order for the query that runs there.
- **DoS:** a query that is allowlisted in-sandbox can be expensive on the host, where it is not bounded by the sandbox's own cgroup.

### Build → runtime / CI

- **Tampering:** Swift tarball `curl | tar` (`linux-deps.sh` `install_swift_tarball`). Zig/Wasmtime/AppImage tools are hashed. The distro layer (Qt 6, cmake, ninja, clang, patchelf, shellcheck) is not hashed and resolves from the runner's mirror, and `Dockerfile` / `Dockerfile.arch` have no `USER` directive.
- **Elevation:** `linux.yml` runs `on: pull_request` as root in a container against the checked-out tree. Bounded by `permissions: contents: read`, `persist-credentials: false`, and SHA-pinned actions (`.github/workflows/linux.yml:4`, `:8`).
- **Repudiation / spoofing:** `release.yml` takes `contents: write` on `workflow_dispatch` and can be dispatched on a non-tag ref, so the artifact's provenance is the selected ref, not a tag. `VERSION` is passed as an env var, not interpolated into `run:`.
- **Spoofing:** ad-hoc macOS signature only (`build.sh`).

## Mitigations mapping

| Control | File | Covers | Does not cover |
|---|---|---|---|
| No network listener | CLI parse + absence of bind/listen | Remote unauthn | Local user and local files |
| UI `confirmDelete` default true; CLI `confirmUpdate` on a TTY, `--yes` otherwise | `Settings.swift`, `ContentView.swift`, `ui/linux-qt/main.cpp`, `AppAtticCLI/main.swift` | Accidental click or interactive CLI update | Disabled UI setting; a caller that passes `--yes` on purpose |
| `--dry-run` prints, does not run (except it short-circuits before `update` run) | `CLIParse.swift`, `main.swift` | Review of leftover/stale/package scripts | Operator pasting the script into a root shell |
| `shellQuote` | `ShellScript.swift` | Metacharacters in paths/names inside generated `sh` | A finding that should not have been listed at all |
| Qt `commandIsShellSafe` byte allowlist over plugin `command` before it reaches a script line | `ui/linux-qt/finding.cpp:445`, `ui/linux-qt/main.cpp:2707` | A plugin using `;`, `\|`, `&`, `$`, backtick, redirect, or newline to append its own command | A plugin command built only from allowed bytes, and any command the app itself writes. The Swift CLI and macOS UI have no equivalent check on plugin-supplied text. |
| Qt `isProtectedPackagedPath` / `commandRemovesProtectedPath` | `ui/linux-qt/finding.cpp:419` | `rm` of `/usr`, `/etc`, `/System`, `/lib`, `/boot` and friends in a leftover command | `QFile::moveToTrash` on the disk page; Swift leftover `rm`; `/etc/apt/sources.list.d`, which is re-permitted on purpose |
| Disk-page "Move to Trash" confirm dialog | `ui/linux-qt/diskpage.cpp:803` | An accidental click on a selected node | Any path the walk reached, including outside the home tree; there is no packaged-path filter on this path |
| `shellComment` flattens newlines in untrusted text used in `#` comments | `ShellScript.swift`, `Cleanup.swift`, `Packages.swift`, `Scanner.swift` | A folder named `Game\nrm -rf ~` adding a command line to a generated script; `shellQuote` does not help because the value is unquoted in a comment | Comment text that is not a name or manager label |
| KEEP / `system` / untrusted-cask / no full distro upgrade | `Recommend.swift`, `Leftovers.swift`, `Outdated.swift`, `Packages.swift` | Default CLI script omits KEEP and system leftovers; no `apt upgrade` / `-Syu`; named upgrades only after confirm | REVIEW-tier if the UI user opts in; home dots with no system-name entry (`.mozilla`, `.m2`, `.gradle`); plugin `command` |
| Steam/CrossOver not deleted | `Cleanup.swift` `uninstallCommand` | Steam library `rm` | User running a hand-edited script |
| Qt `/usr` rm filter and overlay-only delete | `ui/linux-qt/finding.cpp` `isProtectedPackagedPath`, `leftoverCleanupCommand` | `rm` of packaged `/usr` paths in the Qt UI | Swift leftover `rm`; Qt commands that are not `rm` |
| `host.exec` allowlist | `core/host/hostexec.c`, `hostexec.h` | WASM spawn of destructive argv | Plugin-authored cleanup JSON; Swift `Process` path (separate, argv-array) |
| `host.exec` 60s cap, own process group, SIGTERM then SIGKILL to the group | `core/host/hostexec.c` `HOST_EXEC_TIMEOUT_MS`, `reap_child` | A wedged or runaway allowlisted query, and the children it spawned | A guest that spins without calling `host.exec`; no fuel or epoch deadline |
| No WASI | `core/host/embed.c` | Guest file I/O | `host.exec` and findings JSON |
| Untrusted brew tap | `BrewInfo.swift` `refusedCasks`, `applyUntrustedCasks` | `brew upgrade --cask` of refused casks | Listing them; other managers |
| `HOMEBREW_NO_AUTO_UPDATE` | `Process.swift:115`, set only when the resolved binary is `brew` | Surprise brew self-update during scan | `update` script, which is `brew upgrade`; any other binary |
| Scan cache fingerprint + max age 24h | `Cache.swift` | Stale cache after installs | Forged cache with a copied live fingerprint |
| Atomic settings/cache writes, then owner-only mode (`0600`, `0700` on an `appattic` parent) | `Settings.swift`, `Cache.swift`, `FilePermissions.swift` `restrictPrivateDataFile` | Torn JSON; another local account reading or editing the state file | A MAC: nothing stops the same user rewriting the cache or turning `confirmDelete` off |
| Generated scripts written owner-only; Qt creates them with `QTemporaryFile` (exclusive) | `FilePermissions.swift` `writeOwnerOnlyFile`, `Scanner.swift` `runTempScript`, `AppAtticCLI/main.swift` `runShellScript`, `ui/linux-qt/main.cpp` `runScript` | Another local account executing a script through a wider mode in the shared temp dir | The Swift path: the name is visible in a world-writable temp dir and only `0600` protects the content |
| SHA-256 of build tools | `scripts/dep-checksums.sha256` | Zig, Wasmtime, linuxdeploy, appimagetool | Swift tarball |
| `runCommand` timeout | `Process.swift` | Hung package-manager query (SIGTERM, then SIGKILL to the child) | Wasmtime fuel; the UI and CLI script runners, which `waitUntilExit` with no timeout |

### Claim vs code

`README.md` says CLI updates run after you confirm. `AppAtticCLI/main.swift` `confirmUpdate` prompts when stdin is a TTY and exits 2 without one, so an unattended `appattic update` needs the explicit `--yes`. The CLI help states both.

`README.md` “Nothing is deleted until you review a script or confirm in the UI” matches leftover/stale/packages CLI. `update` upgrades packages rather than deleting scan findings and has the TTY-dependent behavior above. The same sentence holds only while `confirmDelete` is true, and the UI offers to turn it off, so "confirm in the UI" is a setting, not a control.

`README.md` “Move to Trash from Disk Usage asks first” is accurate about the dialog and silent about the scope: the walk can start at `/`, the trash path has no packaged-path filter, and the path is whatever the walk reached (`diskpage.cpp:575`, `:803`). The claim is about the prompt, not the reach.

### Single points of failure

1. **Operator confirmation** (a TTY prompt, or `--yes` for an unattended CLI `update`) is the control in front of every high-impact delete/upgrade, and it is one checkbox away from being off.
2. **`PATH` resolution inside the generated script** is the control in front of "the delete is the one the user read". One user-writable directory in front of `/usr/bin` defeats it, and it is the only path here that can reach root through a confirmed action.
3. **`appattic_host_exec_allowed`** is the control in front of every WASM-spawned process, and it is bypassed wholesale by one environment variable on macOS.
4. **Leftover `system` name lists** are the control in front of deleting home-dot credential trees; the list is a text file, not a rule, and mail and build trees are missing from it.

## Abuse cases

These are hostile-but-local scenarios. Evidence is the code path, not an exploit.

1. **Skip the confirm dialog.** Settings → `confirmDelete` false (`ContentView.swift` `confirmDeleteBinding`, Qt `m_confirmBox`). Delete/Update/Mark Manual run `runTempScript` / `runScript` on the first click.
2. **Non-interactive CLI upgrade without review.** With stdin redirected, `appattic update --yes` → `confirmUpdate` returns true on the flag → `updateScript` → `runShellScript` (`main.swift:425`). Automation is a flag away, and the flag is the record that it was deliberate; without it the run stops at exit 2.
3. **Poison `last-scan.json`.** Write a cache with the current fingerprint, `includeSystem` matching the next run, `scanned_at` within 24h, and an extra leftover path. `resolveScan` will use it (`Cache.swift:97`). The UI/CLI then offers that path in cleanup. The file is `0600`, so this is the same user, not another account.
4. **Drop a plugin into the core-out directory.** `pluginWasmFiles` globs `*.wasm` in `APPATTIC_CORE_OUT` (or the `../share/appattic` next to the binary) and loads every one that exports `plugin_abi_version` 1 (`corehost.cpp:170`, `embed.c:451`). No allowlist of names, no signature, no digest: a new file is a loaded plugin. It can return findings whose `command` is copied into the script (`finding.cpp:550`, `main.cpp:2707`). `host.exec` still cannot `rm`, but the *script the user confirms* can. On macOS, `APPATTIC_HOST_EXEC_LIVE=1` next to it turns the fixture default into live `execvp` for the whole core (`hostexec.c:459`).
5. **PATH hijack during a scan.** Put a fake `brew` on `PATH`. Scan and `update` invoke it (`whichCommand`, `updateCommand`). `whichCommand` searches user bin dirs (`~/.local/bin`, `~/bin`, `~/.bun/bin`, `~/.cargo/bin`, and the rest of the list in `Process.swift:14`) *before* `/usr/bin`, so those win even when `PATH` does not list them early.
6. **PATH hijack inside the script the user already confirmed.** This is the same directories, one step later and without any UI. Both Swift runners pass `augmentedProcessEnvironment` to `/bin/sh` (`Scanner.swift:486`, `AppAtticCLI/main.swift:456`), which prepends `cleanupPathDirectories()`, `~/.local/bin` and `~/bin` included (`Paths.swift:201`). A `pkexec` placed there is what `rootcmd` runs when the script escalates a distro removal (`Cleanup.swift:378`). The user reviews a script that reads `pkexec` and gets a different program. The Qt runner uses the raw system environment (`main.cpp:2848`), so it inherits whatever `PATH` the session already had.
7. **Trash a system path from the disk page.** "Scan filesystem" walks `/` (`diskpage.cpp:575`). Select `/etc`, or any directory under it, click Move to Trash, confirm the dialog, and the node is gone (`diskpage.cpp:803`). There is no `isProtectedPackagedPath` check on this path; that guard only ever wrapped `rm` in a leftover command (`finding.cpp:419`). "Scan mounted network folder" points the same walk at a gvfs/sshfs/SMB mount, where a hung mount blocks the worker with no per-entry timeout.
8. **Classifier miss.** `.m2`, `.gradle`, `.mozilla`, `.thunderbird`, `.java`, `.android` are scanned home-dot leaves with no `linuxSystemNames` entry, and `.mozilla`/`.thunderbird` only classify `owned` when the alias table recognises the app name (`firefox` → `mozilla`, `Leftovers.swift:9`). Install mail from the store or a Flatpak and `.thunderbird` classifies `orphaned`; the default leftover dry-run emits `rm -rf` of a tree holding `key4.db` (`Cleanup.swift` `leftoverRemoveCommand`).
9. **`--json` overwrite and `config` disclosure.** `--json FILE` writes scan JSON to `FILE` with no directory jail (`main.swift:74`). Same user, arbitrary path they can write; the file is created `0600` (`writeOwnerOnlyFile`), but the parent directory is not tightened the way the app's own state directory is. `appattic config` prints the settings path, cache path, four XDG homes, and `XDG_DATA_DIRS` unredacted, and `--json` writes the same to a file (`main.swift:142`, `Settings.swift:163`).
10. **Disable confirm via settings file.** Directly edit `settings.json` (no integrity). Same as (1).
11. **Race the generated script in the shared temp dir.** The CLI and macOS UI write `appattic-*.sh` into the world-writable temp directory under a UUID name, `0600`, and hand the path to `/bin/sh`. Another local account can watch that directory and win the moment before execution; only the mode stands in the way, and the Qt path is not exposed because `QTemporaryFile` creates exclusively (`Scanner.swift:473`, `AppAtticCLI/main.swift:443`, `ui/linux-qt/main.cpp` `runScript`).
12. **Point the scanner at a system root.** `appattic disk /etc` (or the macOS free-text folder field) walks and reports the path as given; only existence and directory-ness are checked (`DiskUsage.swift:182`). `XDG_CONFIG_HOME=/etc` does the same through the leftover scanner (`Leftovers.swift:259`), which then offers `rm -rf` lines for `/etc` children.

Client-side enforcement: the ignore list and confirm toggle are local files, not a server policy. There is no server.

## Response readiness (note only)

- Scripts run with stdout discarded (UI) and stderr kept only until the process exits; the temp file is deleted. There is no durable “what we deleted” log in-tree.
- No disclosure contact, supported-version list, or “report → fix shipped” path is published. See `SECURITY.md`.

## How to re-verify this file

Re-walk: `CLIParse.swift` (`cliCommands`, flag table, `disk` positional), `AppAtticCLI/main.swift` (`confirmUpdate`, `runConfigCommand`, `runShellScript`, `--json` writes), `Cleanup.swift` (`leftoverRemoveCommand`, `rootcmd`, `isPpaSourcesPath`), `Packages.swift`, `Outdated.swift` (`itunesRequest`, `applyUntrustedCasks`), `Settings.swift` (`effectiveIncludeSystem`, `EffectiveConfig`), `Cache.swift` (`isScanCacheStale`), `Leftovers.swift` (`homeDotData`, `linuxSystemNames`, `classify`, `classifyLinuxSystemName`, `xdgScanRoots`, `defaultAndroidSdkDirs`), `Process.swift` (`runCommand`, `whichCommand`, `augmentedProcessEnvironment`), `Paths.swift` (`norm`, `cleanupPathDirectories`, XDG roots), `ShellScript.swift` (`shellQuote`, `shellComment`, `guardedRemoveCommand`), `FilePermissions.swift` (`writeOwnerOnlyFile`, `restrictPrivateDataFile`), `DiskUsage.swift` (`validateDiskRoot`, `scanDiskUsage`), `DiskUsageView.swift`, `Scanner.swift` `runTempScript`, `ui/linux-qt/main.cpp` (`runScript`, `scriptLine`, `cleanupScript`, arg parsing), `ui/linux-qt/finding.cpp` (`commandIsShellSafe`, `commandRemovesProtectedPath`, `leftoverCleanupCommand`, `isSafePackageName`), `ui/linux-qt/diskpage.cpp` (`scanFilesystem`, `scanRemote`, `trashSelected`), `ui/linux-qt/corehost.cpp` (`pluginWasmFiles`), `core/host/embed.c` (`plugin_abi_version`, linker imports), `core/host/hostexec.c` (`use_fixture`, `appattic_host_exec_allowed`, `destructive_token`, `parse_argv`, `reap_child`, `HOST_EXEC_TIMEOUT_MS`, `appattic_host_apply_user_path`, `flatpak-spawn`), `core/src/apt.zig`, `packaging/flatpak/org.appattic.AppAttic.yml` (`finish-args`), `packaging/Info.plist`, `scripts/linux-deps.sh`, `scripts/dep-checksums.sha256`, `.github/workflows/linux.yml`, `.github/workflows/release.yml`. If an entry point, allowlist, or confirm path changes, update the matching row here in the same change.
