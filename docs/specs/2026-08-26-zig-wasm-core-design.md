# AppAttic Zig WASM core

Date: 2026-08-26
Updated: 2026-11-13
Status: Accepted. This is the Linux Qt scan path. The Swift CLI and the macOS UI still scan in `AppAtticScan` and do not load this core.

The Python-to-Swift port is the historical record [`archive/2026-08-17-swift-scan-port-design.md`](archive/2026-08-17-swift-scan-port-design.md).

## What ships

Linux Qt loads `appattic_core.wasm` through `core/host/embed.c` and refuses to scan without it. Every package manager and every Linux leftover root in scope is a WASM plugin. `core/src/core.zig` exports `core_abi_version` only (`ABI_VERSION` in `core/src/abi.zig`, integer 1). Load, unload, the argv tag passed to `plugin_query`, and the capability intercept live in `core/host/embed.c`.

The native shell owns what the Zig module does not:

- Windows, lists, the inspector, buttons, alerts, and the script sheet.
- The presence tag per plugin (`pluginTag`, `kExecRules`, `kXdgRules`, `kHomeRules` in `ui/linux-qt/corehost.cpp`). The tag decides whether a coeffect is present. It does not decide which `.wasm` files load.
- Grouping of findings the plugins already produced (`groupLinuxLeftovers` in `ui/linux-qt/finding.cpp`).
- Joining the confirmed `sh` and running it (`cleanupScript` in `ui/linux-qt/main.cpp`).

Plugin membership is `wasm_sources` in `core/build.sh`. One `core/src/<id>.zig` compiles to `core/out/<id>.wasm`. There is no manifest directory. The host argv does not switch on `apt` versus `pacman` versus `npm`. Per-manager knowledge is the plugin, the `host.exec` allowlist (`appattic_host_exec_allowed` in `core/host/hostexec.c`, declared in `core/host/hostexec.h`), and the presence tables.

`pluginWasmFiles` loads every `*.wasm` in `core/out` except `appattic_core.wasm`. A plugin with no presence rule gets tag `1`. Adding a plugin means adding it to `wasm_sources`. `scripts/lint.sh` rebuilds the argv from that list and fails when this file or `core/README.md` quotes a different `try:` line.

A missing coeffect (binary not on `PATH`, root directory absent) is tag `0`: the plugin still loads and returns empty findings. It does not fail the scan. A missing `.wasm` file is skipped.

`path-home-dot` is not in `kXdgRules` or `kHomeRules`. `pluginTag` returns 1 when `$HOME` exists and 0 otherwise. The names it reports come from the `allow` list on its `spec_table` entry (`core/src/path_listing.zig`).

Query is read-only `host.exec`. `APPATTIC_HOST_EXEC_LIVE` is checked first: `1`, `true`, `yes`, or `on` forces a live `execvp` of allowlisted queries, including on Darwin. Otherwise Darwin uses canned fixtures. Other platforms use fixtures only when `APPATTIC_HOST_EXEC_FIXTURE` is on. Linux sets that variable in `core/build.sh` and in CI, so a test run does not reach a real package manager. Any other value is read as off.

Emission (`rm`, `snap remove`, `dnf upgrade`, and the other script lines) is not `host.exec`. The shell writes a reviewed `sh` script. Whether an alert precedes the run is the `confirmDelete` setting, which defaults to on and can be turned off. See [`DESIGN.md`](../../DESIGN.md).

`AppAtticScan` keeps building. The core does not replace it. `CLIParse.swift` parses the Swift CLI. That CLI is not a WASM guest.

`scripts/linux-qt-link.sh` is the Linux link step. CI and the Dockerfiles run it. A `LINUX_QT_LINK=ok` line from it is the gate. `tests/AppAtticScanTests/PackagingTests.swift` fails a build file that hardcodes the line instead of running the check. Build on the distro you run.

Paper: Shi, Zhang, Cui, *A Programming Paradigm for Spatiotemporal Composability*, https://github.com/cordiverse/paper (PDF, 88 pages). Text taken with `pdftotext` from `paper.pdf` on 2026-08-26. Cordis is TypeScript. The rules below are the ones this core follows. The next section says where the built code stops short of the paper.

## Rules that bind

1. **Temporal composability** (ch. 1.1, 3.1). Every in-core mutation has an inverse. Unload reverts LIFO. Loading WASM is a tracked effect (ch. 6.4): drop the instance to unload.
2. **Spatial composability** (ch. 1.1, 3.2). Plugins declare what they need from the host. A missing provider is inactive, not an error loop. In the build, that state is tag 0 and empty findings.
3. **Component = fiber** (ch. 4, 5.1.3). The paper's names are `inject` plus `apply`, and LOADING / ACTIVE / UNLOADING / INACTIVE. The state that shows in output is the missing-coeffect case above.
4. **Declarative loader** (ch. 5.2). Paper entries carry `id`, `url`, `isolate`, `intercept`, `config`, `disabled`. The built loader is `wasm_sources` plus the host argv, not that entry record.
5. **Capability inject and interception** (ch. 6.3). Declared keys are all a plugin may use. Allowlists live on the host.
6. **WASM sandbox** (ch. 6.3, 6.7). Guest exports are `i32` and there is no WASI. Untrusted code sees only embedder imports.
7. **System boundary** (ch. 6.1). Disk, images, and distro packages sit outside the guest. The script is compensation for a removal, not a tracked inverse of `rm`.
8. **Key identity** (ch. 6.6). ABI integer 1. There is no `appattic.findings.<id>` namespace. A finding is identified by its own `"id"` inside the plugin JSON, and the UI prefixes the plugin id (`uid()` in `ui/linux-qt/finding.h`), so ids from two plugins do not collide.
9. **Zig comptime** (ch. 6.4). The paper uses comptime for typed inject accessors. This core does not.

The paper does not treat dialogs as plugins. Here, the plugin supplies confirm copy and script text. The native toolkit draws the alert and the sheet.

## Layers

| Layer | Owns | Does not own |
|---|---|---|
| Native shell | Windows, lists, inspector, buttons, alerts, sheet, grouping findings, the presence tag, joining `sh`, running it | CLI parsing, classify, the plugin inventory |
| C host (`core/host/embed.c`) | ABI gate, load and unload, passing the argv tag to `plugin_query`, capability intercept | Choosing the tag, manager parsers, scan roots |
| Zig core WASM (`core/src/core.zig`) | `core_abi_version` | Loading, plugins, and the shell |
| WASM plugins | One manager, one leftover root, overlay and shadow, or user-bin | Widgets |

## Plugin ABI (version 1)

Guest exports, `i32`, no WASI. `plugin_abi.bind` in `core/src/plugin_abi.zig` emits the plugin exports. `core.zig` emits `core_abi_version` itself.

| Export | Meaning |
|---|---|
| `core_abi_version` or `plugin_abi_version` | Must equal 1. A mismatch does not call `plugin_query`. |
| `plugin_id_ptr` and `plugin_id_len` | UTF-8 id |
| `plugin_query` | Arg 0 is the presence tag. `0` means the coeffect is missing and findings are empty. Any other value is plugin-defined: `1` for present, or `1` docker and `2` podman for `container-runtime`. Return 0 means ok. |
| `result_ptr` and `result_len` | UTF-8 JSON of the last query |

The host does not hard-code a plugin id.

Result JSON:

```json
{
  "plugin": "snapd",
  "engine": "snap",
  "findings": [],
  "script": null,
  "dialog": { "title": "…", "body": "…" },
  "note": "snap missing"
}
```

`note` is optional. `querynote.zig` writes it when a command did not answer or a list overflowed. A command that was refused, failed, timed out, or whose output was truncated becomes `"<cmd> did not answer: <reason>"`. Entries are separated by `"; "` and capped at 8 (`max_logged`). Further failures become `"<n> more command(s) did not answer"`. A list that hit the plugin's fixed finding array (`addTruncatedRows`) or whose render shed rows to fit `result_buf` (`addDroppedRows`) adds `"<n> list(s) hit the row limit: more rows exist than were shown"`. A run where every command answered and no list overflowed has no `note`. An empty `findings` array with no `note` is a clean scan.

`appendFindingsFromBlob` in `ui/linux-qt/finding.cpp` collects `note` at ingest. `scanNoteClause` renders it beside the scan counts. That is the scan-level place for a result whose `findings` list is empty. When the plugin also produced rows, the same note is appended to each row's `dialogBody` after the row's own `reason`, so the reason cannot hide it. Swift models the same idea as `ScanData.incomplete` on the other stack.

`script` is null when the plugin names nothing to run. The host rejects a plugin result whose JSON contains any of these substrings: `system prune`, `rmi -f`, `volume prune`, `snap remove --purge`, `rm /usr/bin/snap`, `rm -rf /usr/bin/snap`, `rm /usr/bin/flatpak` (`core/host/embed.c`).

A removal line has to survive a rerun. The script runs under `set -e`, and a manager exits nonzero when asked to remove something it already removed, so an unguarded line stops the rerun at the first target the first run took. `core/src/guarded_remove.zig` wraps a manager line in `if <present>; then <remove>; fi`. A file line uses a flag that is a no-op when the target is already gone (`rm -rf`, `rm -f` in `path_listing.zig`, `path_shadow.zig`, `path_user_bin.zig`, and the snapd orphan dirs). The presence check is a read: a package query (`dpkg -s`, `rpm -q`, `pacman -Qq`, `flatpak info`, `pip show`), a row of a listing the global tool already prints and grepped with `-qF` (`npm ls -g --depth=0`, `pnpm ls -g --depth=0`, `bun pm ls -g`, `uv tool list`, `pipx list`), a file the removal takes away (`test -e /var/lib/snapd/snaps/<name>_<rev>.snap`, `test -e ~/.deno/bin/`), or an engine query (`docker image inspect`, `docker volume inspect`, `docker container inspect`).

The pacman-family upgrade uses the same guard for a different reason. `pacman -S <name>` on a package already at the repo version reinstalls it. The check is `pacman -Qu <name>` or `paru -Qu <name>`, which exits 0 only while the package is still behind. `brew upgrade`, `flatpak update`, `apt-get --only-upgrade`, and `dnf upgrade` answer "nothing to do" when the package is current, so those lines stay unguarded.

## Inventory

Backlog ids are not in `wasm_sources`, so no `.wasm` is built for them. Query plugins call `host.exec`. Darwin leftover roots stay in Swift.

### Manager plugins

| id | Coeffect | Reports | Suggested commands (named objects only) |
|---|---|---|---|
| `apt` | `host.exec` `apt-get` or `apt` or `dpkg` | Outdated (`apt list --upgradable`, `updatable`). Orphans from `apt-get -s autoremove`. PPA files from `ls` of `/etc/apt/sources.list.d` (`parsePpaSources` in `apt.zig`). Swift has no counterpart for that PPA parser. | Never a full `apt upgrade`. Named `apt-get purge` and named `apt install --only-upgrade` after the script runs. |
| `pacman` | `host.exec` `pacman` | Outdated (`-Qu`, `updatable`). Orphans (`-Qdt`). | Named `pacman -Rns` and named `pacman -S pkg`. No `-Syu`. |
| `aur` | `host.exec` `paru` or `yay` or `pikaur` | Outdated (`-Qua`, `updatable`). | Named `paru`, `yay`, or `pikaur -S pkg`. |
| `dnf` | `host.exec` `dnf5` or `dnf` or `yum` (first found; yum is an alias, not its own id) | Outdated (`updatable`). Unneeded (`repoquery --unneeded`). | Named `dnf remove` or `yum remove`. Named `dnf upgrade pkg` or `yum upgrade pkg`. No full `dnf upgrade`. |
| `zypper` | `host.exec` `zypper` | Outdated (`list-updates`, `updatable`). Unneeded (`packages --unneeded`). | Named `zypper rm` and named `zypper update pkg`. |
| `brew` | `host.exec` `brew` | Outdated formulas and casks (`outdated --json=v2`). Every row is `updatable: true`. `brew.zig` does not read Homebrew's "Refusing to load cask" error, so a cask from an untrusted tap is offered for update. Swift `BrewInfo.swift` marks those rows `untrusted` and does not update them. No uninstall lines. | Named `brew upgrade <name>` only. No greedy auto-cask force. |
| `flatpak` | `host.exec` `flatpak` | Unused runtimes (`flatpak uninstall --unused --dry-run`). Outdated apps (`remote-ls --updates --app` plus `list --app`). Leftover `.var/app` stays on `path-var-app`. | Named `flatpak uninstall` for unused runtimes. Named `flatpak update`. Never `rm /usr/bin/flatpak`. |
| `snapd` | `host.exec` `snap` | Disabled leftover revisions. Orphan `~/snap/<name>` when the snap is not installed. Snap cache is not queried. Uninstall of a still-installed snap stays on the Swift stale and outdated lists until a later port. | `snap remove <name> --revision <n>`. `rm -rf` of a named `~/snap/<name>` only. Never a silent `snap remove`. Never `rm /usr/bin/snap`. Never `snap remove --purge '*'`. |
| `npm` | `host.exec` `npm` | User-global `-g` leftovers. Outdated (`npm outdated -g --json`) is report-only. Not every repo `node_modules`. | `npm -g uninstall` of a named package. |
| `pnpm` | `host.exec` `pnpm` | User-global leftovers. | `pnpm remove -g` of a named package. |
| `bun` | `host.exec` `bun` | User-global leftovers. | `bun remove -g` of a named package. |
| `pip` | `host.exec` `pip` or `pip3` | Top-level user-site packages (`pip list --user --not-required`). Zig also runs `pip list --user --outdated --format=json` and reports outdated rows Swift does not. Not every venv. | Named `pip uninstall` for globals. |
| `deno` | `host.exec` `deno` (globals from `ls` of `~/.deno/bin`) | User-global Deno installs. Not every project. | Named `deno uninstall --global`. |
| `pipx` | `host.exec` `pipx` | Unused pipx tools. | `pipx uninstall` of a named tool. |
| `uv` | `host.exec` `uv` | `uv tool` leftovers. | `uv tool uninstall` of a named tool. |
| `gem` | `host.exec` `gem` | User-install outdated (`gem outdated`). Report-only. `gem.zig` emits `"script":null`, so there is no `gem uninstall` line. Swift has no `gem` parser. | Named `gem update` on the row. `updatable: false` keeps it out of the update script. |
| `composer` | `host.exec` `composer` | Global outdated (`composer global outdated`). Report-only. Not every project `vendor/`. `composer.zig` emits `"script":null`. Swift has no `composer` parser. | Named `composer global update` on the row. `updatable: false` keeps it out of the update script. |
| `container-runtime` | `host.exec` `docker` or `podman` | Dangling images, dangling volumes, exited containers. Idle-days skipped. Abandoned compose projects and pods are not queried. The unnamed build cache is not queried. It is still reported as a `build-cache` finding with `"id": null`, `"status": "review"`, and no command. | Named `rmi`, `volume rm`, and `rm`. Never `system prune -af`. Never delete the engine binary. |

`~/snap` orphan directories belong to `snapd`, not a second path plugin.

### Path plugins

Linux leftover roots, plus `path-user-bin`, `path-home-dot`, and `path-shadow`. Path plugins query with `ls` on `host.exec`. `path-user-bin` also uses `test` (`-h` and `-e`). `path-shadow` also uses `realpath` (one path, no flags) and `test -f`. A missing root is tag 0 and empty findings.

| id | Coeffect (path) | Reports | Suggested commands |
|---|---|---|---|
| `path-xdg-config` | `XDG_CONFIG_HOME` or `~/.config` | Orphan dirs and files in that root | `rm -rf` of the named path |
| `path-xdg-data` | `XDG_DATA_HOME` or `~/.local/share` | Same | named `rm` |
| `path-xdg-cache` | `XDG_CACHE_HOME` or `~/.cache` | Same | named `rm` |
| `path-xdg-state` | `XDG_STATE_HOME` or `~/.local/state` | Same | named `rm` |
| `path-xdg-lib` | `~/.local/lib` | Same | named `rm` |
| `path-var-app` | `~/.var/app` | Flatpak user data when the app is gone (ids still come from `flatpak` when that plugin is active) | named `rm` of the leftover dir. Uninstall still goes through `flatpak` |
| `path-home-dot` | `$HOME`, then the allow list in `spec_table`: `.mozilla`, `.thunderbird`, `.steam`, `.wine`, `.java`, `.gradle`, `.android`, `.m2` | Those leaves at `$HOME` | named `rm`. `.steam` here is a directory leaf, not the `steam` backlog id |
| `path-shadow` | `~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.local/share/applications`, compared with `/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`, `/usr/local/bin`, `/usr/share/applications`, `/usr/local/share/applications` | User overlays that hide a same-named packaged file (`status` shadow). Cleanup removes the overlay only | named `rm` of the overlay |
| `path-user-bin` | `~/.local/bin`, `~/bin` | Broken symlinks | named `rm` of the link |

Swift `homeDotData` (`Sources/AppAtticScan/Leftovers.swift`) also lists `.docker`, `.kube`, `.aws`, `.gnupg`, `.ssh`, `.npm`, `.cargo`, and `.rustup`. The two lists are not checked against each other, so those eight leaves are scanned on the Swift side only.

The shadow overlay roots are one list in three trees: the constants in `core/src/path_shadow.zig`, the `path_shadow` entry of `kHomeRules`, and `defaultOverlayShadowRoots` (`Sources/AppAtticScan/Overlays.swift`). The plugin tag and the plugin query have to name the same roots. Otherwise a machine whose only overlay sits in a root the plugin does not read is tagged present and reports no shadows. `scripts/lint.sh` compares the Zig constants with `kHomeRules`.

Swift `listShadowingOverlays` and `ShadowTests` stay in `AppAtticScan`. The core may still group extra paths.

## Backlog

Not built. No `core/src/<id>.zig`, so the host load list never contains one.

| id | Scope |
|---|---|
| `chocolatey` | Windows Chocolatey outdated and orphan packages |
| `nuget` | User-global NuGet leftovers, not every project `packages.config` |
| `appstore` | Microsoft Store leftovers and outdated on Windows. macOS App Store and `mas` stay in Swift until a later `mas` plugin. That is a different id |
| `steam` | Steam games and leftovers on Windows. Linux and macOS Steam stay in Swift. Remaining Steam leftover work waits on this id |

## Host load list

`core/build.sh` emits `appattic_core.wasm` plus one `.wasm` per in-scope plugin and prints the argv below. Linux Qt keeps no second load registry. Tag `0` on any argument means the coeffect is missing: empty findings, plugin still loads. A missing file is skipped. `chocolatey`, `nuget`, `appstore`, and `steam` are never arguments.

`core/build.sh` also asks the host to precompile each module to `<id>.wasm.cwasm` plus a `<id>.wasm.cwasm.stamp` of the source size and mtime. The host deserializes the sidecar only when the stamp names the `.wasm` it is loading, and compiles the source otherwise. A sidecar from another build costs speed, not correctness. A precompile failure warns and does not fail the build.

```bash
./core/build.sh
./core/out/host ./core/out/appattic_core.wasm \
  ./core/out/container_runtime.wasm=2 \
  ./core/out/snapd.wasm=1 \
  ./core/out/path_xdg_config.wasm=1 \
  ./core/out/path_xdg_data.wasm=1 \
  ./core/out/path_xdg_cache.wasm=1 \
  ./core/out/path_xdg_state.wasm=1 \
  ./core/out/path_xdg_lib.wasm=1 \
  ./core/out/path_var_app.wasm=1 \
  ./core/out/path_user_bin.wasm=1 \
  ./core/out/path_home_dot.wasm=1 \
  ./core/out/path_shadow.wasm=1 \
  ./core/out/pacman.wasm=1 \
  ./core/out/aur.wasm=1 \
  ./core/out/apt.wasm=1 \
  ./core/out/dnf.wasm=1 \
  ./core/out/zypper.wasm=1 \
  ./core/out/flatpak.wasm=1 \
  ./core/out/npm.wasm=1 \
  ./core/out/pnpm.wasm=1 \
  ./core/out/bun.wasm=1 \
  ./core/out/pipx.wasm=1 \
  ./core/out/uv.wasm=1 \
  ./core/out/brew.wasm=1 \
  ./core/out/gem.wasm=1 \
  ./core/out/composer.wasm=1 \
  ./core/out/pip.wasm=1 \
  ./core/out/deno.wasm=1
```

## container-runtime

User-level docker or podman leftovers. One engine per scan. `pluginTag` in `ui/linux-qt/corehost.cpp` returns 2 when `podman` is on `PATH`, otherwise 1 when `docker` is, otherwise 0. Podman wins when both are installed. `query_impl` reads that tag and runs only that engine's three queries. Findings carry `engine` (`docker` or `podman`). There is no Settings picker and no merged list of both engines.

Queries, named objects only: `images -f dangling=true`, `volume ls -f dangling=true`, `ps -a -f status=exited`. Idle-days are skipped because the CLI `CREATED` column is relative text, not a timestamp. Abandoned compose projects and pods are not queried. The unnamed build cache is reported as the `build-cache` finding above so the omission is a row, not a clean scan. The confirm script may include named `rmi <id>`, `volume rm <name>`, and `rm <id>`. Live `host.exec` denies `rmi`, `rm`, `system prune`, and `volume prune`. Stopped containers are review-only, with a named `rm` in the script.

## snapd

Snap leftover state on Ubuntu and Debian-family hosts. Installed snap apps stay on the Swift stale and outdated lists (`snap remove <name>`, `snap refresh --list`) until a later port. This plugin queries `snap list --all` and `ls` of `~/snap`: disabled revisions and orphan `~/snap/<name>`.

The snap cache is not queried. Earlier drafts of this record described it as review-only when not user-owned, and also as review-only when unnamed. `core/src/snapd.zig` reports nothing for it. Which rule binds, if any, is undecided.

## Errors

- Missing coeffect: tag 0, empty findings.
- ABI mismatch: `plugin_query` is not called.
- No object ids: no script lines.

## Still in Swift

Linux Qt already loads the WASM plugins. These stay in Swift for the macOS UI and the `appattic` CLI:

- Discover, usage, leftovers (including shadowing and `~/snap` as a leftover root), stale, outdated (`apt`, `pacman`, `dnf`, `zypper`, `brew`, `flatpak`, `snap`, `mas`), packages, recommend, cache, cleanup
- macOS App Store and `mas` (not the backlog `appstore` id)
- Linux and macOS Steam, and CrossOver helpers
- The CLI and SwiftCrossUI
- Settings and the ignore list
- Tests under `tests/AppAtticScanTests`

The same tool-output grammars exist twice. A parser fix on one side has to land on the other. `ParserParityTests` pin the shared edges. `linux-system-names.txt` is copied the same way, and `scripts/lint.sh` fails when the copies differ. Asymmetries called out above: `gem`, `composer`, and apt PPA sources have no Swift parser. Zig `pip` reports an extra outdated query. Zig `brew` does not apply the untrusted-cask rule.

## Tests

Host exit 0 on the built plugin set. CI runs `bash scripts/linux-qt-link.sh` and then `scripts/verify-qt-link.sh`, which checks `ui/linux-qt/build/LINUX_QT_LINK.txt`. JSON plugin ids match the sources. `core/host/tests/hostexec_test.c` asserts the denied forms: no `system prune`, no `snap remove --purge '*'`, no `rm -rf /usr/bin/snap`, no `apt-get purge -y`, no `dpkg --purge`. Tag 0 yields empty findings.

## Settled

- One engine per scan: podman when it is on `PATH`, otherwise docker. The finding's `engine` field names which one ran. No Settings picker, and the two engines are not merged.
- Stopped containers are review-only, with a named `rm` in the script.
- The embedder is the Wasmtime C API. `core/build.sh` requires it and fails the build without it.

## Open

- Snap cache: see [snapd](#snapd). Undecided.
- `idleDays`: no plugin emits it. `container_runtime.zig` asserts the field is absent, and nothing is filtered by age. `Finding.idleDays` (`ui/linux-qt/finding.h`) is filled from `mtime` for the row label only. A default is undecided.
- podman-docker shim versus Docker Desktop: undecided.
