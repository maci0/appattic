# Threat model

Last reviewed: 2026-11-13.

AppAttic is a local cleanup utility: a Swift CLI and macOS UI, plus a Linux Qt UI backed by Zig WASM plugins. It has no authentication, remote API, or network listener. The OS account is the security boundary. A compromised process running as that account can already modify its settings, cache, and user-installed tools.

The main assets are user files, installed software, container data, credentials in configuration directories, and the paths and usage metadata in scan results. Package-manager operations can also request root privileges. No disclosure contact or review cadence is published; see [SECURITY.md](../SECURITY.md).

## Main risks

| Risk | Existing control | Remaining exposure |
|---|---|---|
| A wrong finding becomes a destructive script | Selection, preview, default UI confirmation, quoted arguments, path and identifier checks | Classification is heuristic. Confirmation can be disabled; valid names and paths can still identify valuable data. A script stopped midway is not rolled back. |
| The Linux disk page trashes a valuable path | Separate confirmation; one-filesystem walk by default | It can scan `/` or a network mount. `trashSelected` has no leftover packaged-path filter. Trash recovery depends on the filesystem and desktop. |
| A cache or plugin supplies false findings | Owner-only cache, freshness fingerprint, JSON checks; Qt command filtering | No cache authentication or plugin signature. A valid finding can still be false; an allowed plugin command can still be destructive. |
| A configuration directory is misclassified as orphaned | System-name list and discovered-app aliases | `.mozilla` and `.thunderbird` are not in the system-name list. Ownership depends on discovery and aliases; missing an app can expose its profile to cleanup. |
| A dangling container volume is removed | Identifier validation, existence guard, confirmed script | `volume ls -f dangling=true` is a reference check, not a check that contents are disposable. `volume rm` can destroy retained data. This scan is in the Qt/WASM build. |
| A substituted executable runs during a query or script | Swift scripts use a fixed `PATH`; WASM queries are allowlisted | Scan queries and Qt scripts search user directories. Fixed Swift paths include Homebrew and `/usr/local/bin`; their permissions still matter. A malicious executable runs before any useful output can be validated. |
| A plugin or filesystem scan hangs | Subprocess timeouts and cooperative disk cancellation | WASM has no fuel/epoch deadline. A blocked network filesystem call can outlast cooperative cancellation. |
| A compromised build input reaches a release | Download checksums, pinned actions/base images, dependency checks, reproducibility gates | Distro packages, branch-pinned Flatpak runtimes, and host-collected Qt libraries are not all content-pinned or inventoried. Reproducibility is not source authenticity. |

## Entry points and untrusted inputs

- **CLI and UI:** argv, selected findings, settings toggles, and disk roots. Disk roots are used as supplied. Debug Qt builds also accept `--dev-check`; its screenshot mode writes unredacted PNGs to a supplied directory. Release builds reject that flag.
- **Filesystem:** desktop entries, app bundles, symlinks, manifests, XDG directories, Steam VDF files, usage databases, and shell history. Steam library paths and absolute XDG overrides can redirect discovery beyond the home directory.
- **Package managers:** stdout supplies names, versions, ownership, and removal candidates. Manager configuration can select remote repositories or engines.
- **State:** `settings.json`, `settings.json.bak`, `settings.json.bad`, and `last-scan.json`. All can contain private paths. The Qt UI scans live and only invalidates the shared scan cache; it does not persist its own scan snapshot.
- **WASM modules:** `corehost.cpp` discovers plugins by a `*.wasm` glob in the core output directory. ABI/export checks reject incompatible modules, not malicious compatible ones. `APPATTIC_CORE_OUT` changes that directory.
- **Environment:** `PATH` selects query tools; `HOME` and XDG variables select inventory roots. `FLATPAK_ID` selects host execution. Android SDK variables influence classification. Display variables affect output rather than privileges. `appattic config` prints the effective values without path redaction.

## Trust boundaries and controls

### User to script execution

CLI scan commands report findings. Their dry-run mode prints scripts for review. `update` forces a live scan and executes named upgrades for Homebrew, Flatpak, apt, pacman, AUR, dnf, yum, and zypper; it does not perform a full distro upgrade. It prompts on a terminal, refuses non-terminal stdin with exit 2, and accepts `--yes` as explicit unattended consent (`Sources/AppAtticCLI/main.swift`, `confirmUpdate`).

Desktop cleanup, update, and mark-manual actions run generated `/bin/sh` scripts. `confirmDelete` defaults to true but can be disabled. A package removal's presence guard only establishes that its target exists. Manager flags such as `-y` can suppress any further prompt.

Swift lists untrusted Homebrew casks without offering updates. The Zig `brew` plugin does not apply that trust check, so Qt offers every outdated cask for update. Upgrade support and removal support differ. App Store, Snap, and language-global findings have no automatic upgrade path, but package cleanup supports language-global removals and the Qt Snap plugin emits revision removals. Do not interpret “report-only updates” as “cannot uninstall.”

`erase` deletes the fixed scan-cache path; `restore` validates the backup before replacing the fixed settings path. Both run before settings load and bypass `confirmDelete`. Restore preserves readable, nonempty differing current bytes as `settings.json.bad`. They are state-management operations, not user-file cleanup.

Evidence: `Sources/AppAtticScan/Cleanup.swift`, `Packages.swift`, `Outdated.swift`; `ui/linux-qt/main.cpp`; `core/src/guarded_remove.zig`, `snapd.zig`, `container_runtime.zig`.

### Filesystem and parsed findings to commands

`shellQuote` escapes generated arguments. `isRemovableLeftoverPath` requires absolute removal paths; packaged-path checks block protected prefixes and traversal. `/etc/apt/sources.list.d` is deliberately permitted for root-marked source cleanup. These filters do not apply to the disk page's `QFile::moveToTrash`.

Qt rejects plugin commands containing disallowed shell bytes before scripting them. Its closed leftover-status enum blocks unknown statuses on leftover rows; an absent status retains legacy behavior, and package statuses follow separate command rules. Neither check authenticates a finding or proves a path is unwanted.

Package-name checks reject option-shaped or unsafe identifiers. Swift sanitizes control/bidi scalars; Qt and Zig reject them. Steam uninstall IDs are separately gated before URI construction. Directory listings use `ls -b`, split escaped lines, then decode each entry and validate its identifier; embedded newlines cannot create extra rows through these listing parsers.

Evidence: `Sources/AppAtticScan/ShellScript.swift`, `Cleanup.swift`, `Identity.swift`; `ui/linux-qt/finding.cpp`; `core/src/jsonbuf.zig`, `path_store.zig`, `linux-system-names.txt`.

### Process execution and privilege

Swift generated scripts receive `scriptSafePathDirectories()`, replacing the inherited `PATH`. It includes system directories, `/opt/homebrew/bin`, `/usr/local/bin`, and `/home/linuxbrew/.linuxbrew/bin`, but excludes home bin directories. Scan-side tool discovery still searches user paths.

Qt `scriptRunEnvironment()` augments the user `PATH` through `appattic_host_apply_user_path`. Its scripts therefore trust user-installed binaries as well as system tools. `rootcmd` resolves `pkexec`, then falls back to `sudo`; review both executable resolution and the privilege request. A fake executable does not acquire root merely by having that name.

Queries generally have 60-second subprocess limits. Generated scripts have a 600-second limit in Swift and Qt; termination targets their process groups where available. Timeout, cancellation, or package-manager failure can leave a partially completed operation. Temporary scripts are removed on normal completion and failure; a crash or removal failure can leave artifacts. There is no durable action audit log.

Evidence: `Sources/AppAtticScan/Process.swift`, `Paths.swift`, `Cleanup.swift`; `ui/linux-qt/scriptproc.cpp`; `core/host/hostexec.c`.

### WASM guest to host

The host provides `host.exec`, with no WASI filesystem access. `appattic_host_exec_allowed` restricts query shapes, rejects shell metacharacters, destructive tokens, and manager configuration switches that could inject commands. It executes argv rather than a guest-provided shell script. Each live query has a timeout and process-group cleanup.

`APPATTIC_HOST_EXEC_LIVE` enables live allowlisted queries on all platforms and takes precedence over fixture mode. Otherwise macOS uses fixtures; Linux can opt into them with `APPATTIC_HOST_EXEC_FIXTURE`. Boolean switches are parsed explicitly. Live mode does **not** bypass the allowlist.

There is no Wasmtime fuel/epoch bound for a guest that spins without calling the host. Plugin-generated cleanup JSON also crosses a different boundary: it reaches the UI script builder rather than `host.exec`, so the query allowlist does not cover it.

Evidence: `core/host/embed.c`, `hostexec.c`; `ui/linux-qt/corehost.cpp`, `finding.cpp`.

### Desktop packaging to host

The macOS build is ad-hoc signed, with no App Sandbox entitlement. AppImage has ordinary user permissions.

Flatpak requests `--filesystem=host:ro`, display/IPC access, and permission to talk to Flatpak and the file manager. This is broad read access, not confinement of cleanup: queries use `flatpak-spawn --host`, and scripts use `flatpak-spawn --host -- /bin/sh` with the script on stdin. Host queries forward `PATH`; Qt scripts use the augmented environment described above. Trash uses the file-manager integration.

Evidence: `packaging/flatpak/org.appattic.AppAttic.yml`, `build.sh`, `ui/linux-qt/scriptproc.cpp`, `core/host/hostexec.c`.

### Local state to reports and recovery

Swift writes private files using `mkstemp` at `0600`, file `fsync`, and atomic rename. Qt settings use `QSaveFile` with owner-only permissions and a file sync after commit. Both attempt a directory sync but do not report its failure. App state directories are narrowed to `0700`; caller-selected export parents are left alone. Permissions are not an integrity check against the same OS account.

Settings and cache JSON are checked before Swift decoding, including control characters in strings. Settings reject unknown keys and invalid types/paths. Cache reads have a 256 MiB size check, a fingerprint, and a 24-hour validity limit. These are parsing and freshness controls, not authentication; they do not prove findings are correct.

Scan exports retain real paths. `config` prints full settings paths, ignored paths, and environment values. Home-path replacement in diagnostic text is useful but is not complete anonymization. See [privacy](privacy.md) for retention and [state recovery](runbooks/state-recovery.md) for backup limitations.

### Build and CI to release

`scripts/dep-checksums.sha256` pins downloaded tool archives; fetch scripts verify hashes before use. `scripts/deps.sh check` checks dependency/version drift, vendored files, and inventory consistency; `sbom` emits the release CycloneDX inventory. CI actions and Docker base images are digest-pinned. Pull-request jobs execute checked-out code as root inside their build containers with read-only repository permissions.

The inventory does not fully cover distro packages or the Qt libraries collected from the AppImage build host. Flatpak runtime/SDK branches can move. WASM, Swift, and Qt reproducibility scripts compare independent builds, but identical output does not establish that the source or toolchain is trustworthy. AppImage is not signed in-tree.

Evidence: `.github/workflows/linux.yml`, `.github/workflows/release.yml`, `Dockerfile`, `Dockerfile.arch`; `scripts/deps.sh`, `verify-reproducible.sh`, `verify-swift-reproducible.sh`, `verify-qt-reproducible.sh`, `linux-appimage.sh`.

## How to re-verify this file

For a changed entry point, follow input parsing through selection, script construction, executable resolution, confirmation, execution, and failure cleanup. Compare Swift and Qt separately. Check the cited functions and the matching tests; a parser test establishes accepted syntax, not data safety. Update this model when a boundary changes rather than appending a history of documentation fixes.
