# AppAttic Zig WASM core

Date: 2026-08-26
Updated: 2026-09-27
Status: Accepted

## Context

Follow-on to [`2026-08-17-swift-scan-port-design.md`](archive/2026-08-17-swift-scan-port-design.md) (that port is implemented; `AppAtticScan` remains until a later Zig copy of its tests). This record is the decision that has been made, not a proposal.

## Decision

Replace in-process Swift scan logic with a Zig core compiled to WebAssembly. **Every package manager and every leftover scan path is a WASM plugin.** Native SwiftCrossUI stays on macOS (AppKit). Linux UI is C++ Qt 6 Widgets (`ui/linux-qt`), matching TMOG Linux. Do not silent-delete. Named distro upgrades (`apt install --only-upgrade pkg`, `pacman -S pkg`, `dnf upgrade pkg`) wait for confirm. No full `apt upgrade` / `pacman -Syu`. `scripts/linux-qt-link.sh` is the Linux link step; CI and the Dockerfiles run it, and a `LINUX_QT_LINK=ok` line from it is the gate (`tests/AppAtticScanTests/PackagingTests.swift` fails a build file that hardcodes the line instead of running the check). Build on the distro you run.

Paper: Shi, Zhang, Cui, *A Programming Paradigm for Spatiotemporal Composability*, https://github.com/cordiverse/paper (PDF, 88 pages). Text taken with `pdftotext` from `paper.pdf` on 2026-08-26. Cordis is TypeScript. AppAttic follows the same composability rules in Zig + WASM.

## Rule

The core is a loader: ABI, inject/coeffects, capability intercept, leftover *grouping* of findings plugins already produced, script concatenation, confirm boundary. As built those parts sit around the Zig module rather than inside it: `core/src/core.zig` exports only `core_abi_version` (`core/src/abi.zig`), `core/host/embed.c` owns load/unload, passes each plugin's argv tag to `plugin_query`, and capability intercept, and the native shell owns grouping (`groupLinuxLeftovers`, `ui/linux-qt/finding.cpp:744`) and script concatenation (`cleanupScript`, `ui/linux-qt/main.cpp:2769`) behind the confirm boundary. Which plugins exist lives in one place (`wasm_sources`, `core/build.sh`), so no part of the load path switches on `apt` vs `pacman` vs `npm`. Per-manager knowledge is one plugin per manager, the `host.exec` allowlist (`core/host/hostexec.h:35`), and the native shell's presence table (`kExecRules`, `ui/linux-qt/corehost.cpp:84`), which decides only the presence tag, never what gets loaded. A path plugin declares the root it queries and tags 0 when the root is absent (`spec_table`, `core/src/path_listing.zig:31`); the shell repeats those presence roots in `kXdgRules` (`corehost.cpp:109`) and `kHomeRules` (`corehost.cpp:120`) to compute that tag, so a new path root is a second entry as well. `path-home-dot` has no table entry: `pluginTag` special-cases it on `$HOME` existing (`corehost.cpp:135`). A manager or path that is missing its coeffect (binary not on PATH, root dir absent) stays INACTIVE. It does not crash the scan. Native UI is widgets only. Query is read-only (`host.exec`; Darwin and CI may inject fixtures via `APPATTIC_HOST_EXEC_FIXTURE`). Emission (`rm`, `snap remove`, `dnf upgrade`) waits for confirm + reviewed `sh`.

`AppAtticScan` keeps building until a later port copies its tests into Zig. The core does not delete it. The Swift CLI (`appattic`) parses in `AppAtticScan` (`CLIParse.swift`); it is not a WASM guest. Linux Qt loads `appattic_core.wasm` through `core/host/embed.c`, and refuses to scan without it.

## Paper principles that bind AppAttic

1. **Temporal composability** (ch. 1.1, 3.1). Every in-core mutation has an inverse. Unload reverts LIFO. Loading WASM is a tracked effect (ch. 6.4): drop the instance to unload.
2. **Spatial composability** (ch. 1.1, 3.2). Plugins declare `inject`. Missing provider: INACTIVE, not an error loop.
3. **Component = fiber** (ch. 4, 5.1.3). `inject` + `apply`. LOADING / ACTIVE / UNLOADING / INACTIVE are the paper's names; the built form of the one state that shows in output is a plugin whose coeffect is missing: tag 0, empty findings.
4. **Declarative loader** (ch. 5.2). Entries: `id`, `url`, `isolate`, `intercept`, `config`, `disabled`.
5. **Capability inject + interception** (ch. 6.3). Declared keys are all a plugin may use. Allowlists live on the host.
6. **WASM sandbox** (ch. 6.3, 6.7). Untrusted code sees only embedder imports.
7. **System boundary** (ch. 6.1). Disk, images, distro packages sit outside Γ. Withhold emission until confirm. Script is compensation, not a tracked inverse of `rm`.
8. **Key identity** (ch. 6.6). ABI integer 1 (`ABI_VERSION`, `core/src/abi.zig:1`). No `appattic.findings.<id>` namespace exists: a finding is identified by its own `"id"` inside the plugin's result JSON, and the UI prefixes it with the plugin id, so ids from two plugins never collide (`uid()`, `ui/linux-qt/finding.h:52`).
9. **Zig comptime** (ch. 6.4). Later, for typed inject accessors. Not in this record.

The paper does not treat dialogs as plugins. Adaptation: plugin supplies confirm copy and script text. Native toolkit draws the alert and the sheet.

## Core vs plugin vs native

| Layer | Owns | Does not own |
|---|---|---|
| Native shell | Windows, lists, inspector, buttons, alerts, sheet, grouping findings, presence tag per plugin, joining the confirmed `sh`, running it | CLI parsing, classify, the plugin inventory |
| C host (`core/host/embed.c`) | ABI gate, load/unload, passing the argv tag to `plugin_query`, capability intercept | Deciding the tag, manager parsers, scan roots, brew/apt/snap parsers |
| Zig core WASM (`core/src/core.zig`) | `core_abi_version` only | Everything else; the loading parts live in the C host and the native shell |
| WASM plugins | Each manager, each leftover root, overlay/shadow, user-bin | Widgets |

## Plugin ABI (freeze = 1)

Guest exports, `i32`, no WASI:

| export | meaning |
|---|---|
| `core_abi_version` / `plugin_abi_version` | must equal 1 |
| `plugin_id_ptr` / `plugin_id_len` | UTF-8 id |
| `plugin_query` | arg0 = presence tag. `0` = coeffect missing (empty findings). Non-zero is plugin-defined (`1` present, or `1` docker / `2` podman for `container-runtime`). Return 0 = ok |
| `result_ptr` / `result_len` | UTF-8 JSON of last query |

Host does not hard-code a plugin id. Missing `.wasm` file: skip that plugin (INACTIVE).

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

`note` is optional and present whenever the result is short of the machine. Two causes, same signal. A query command that did not answer (refused, failed, timed out, or output truncated): `"<cmd> did not answer: <reason>"` per command, `; ` separated, capped at 8. Or a list that hit the plugin's row limit: `"<n> list(s) hit the row limit: more rows exist than were shown"`. The row limit is the plugin's fixed finding array (`querynote.Log.addTruncatedRows`) and the rows a render sheds to fit `result_buf` (`addDroppedRows`). A run where every command answered and no list overflowed has no `note`, so an empty `findings` list means a clean scan rather than a silent one. Every row of a plugin carrying a `note` gets the note in its `dialogBody` (`ui/linux-qt/finding.cpp`), appended after the row's own `reason` so the reason cannot bury it: a user confirms a deletion from this list, and a list that is quietly incomplete must say so next to the checkbox.

The `note` is a fact about the whole plugin result, not about one row. It travels in `dialogBody` because that is the one field every row of a plugin shares and the one the confirm sheet shows.

`script` is null when nothing named. Host intercept rejects bulk wipes (`system prune`, `rmi -f`, `volume prune`, `snap remove --purge '*'`, `rm /usr/bin/snap`, `rm -rf /usr/bin/snap`, `rm /usr/bin/flatpak`; `core/host/embed.c:559`).

## Inventory (in scope)

Plugin membership lives in one place: the `wasm_sources` list in `core/build.sh`. One `core/src/<id>.zig` compiles to `core/out/<id>.wasm`; there is no manifest directory. Backlog ids are not in `wasm_sources`, so no `.wasm` is built for them. Query plugins call `host.exec`. Darwin leftover roots stay in Swift `AppAtticScan`.

### Manager plugins

| id | Coeffect | Reports | Suggested commands (named objects only) |
|---|---|---|---|
| `apt` | `host.exec` `apt` | Outdated (`apt list --upgradable`, `updatable`). Orphans from `apt-get -s autoremove`. | Never silent `apt upgrade`. Named `apt-get purge` and named `apt install --only-upgrade` after confirm. |
| `pacman` | `host.exec` `pacman` | Outdated (`-Qu`, `updatable`). Orphans (`-Qdt`). | Named `pacman -Rns` and named `pacman -S pkg` after confirm. No `-Syu`. |
| `aur` | `host.exec` `paru`/`yay`/`pikaur` | Outdated (`-Qua`, `updatable`). | Named `paru/yay/pikaur -S pkg` after confirm. |
| `dnf` | `host.exec` `dnf5` or `dnf` or `yum` (first found; yum is an alias, not its own id) | Outdated (`updatable`). Unneeded packages (`repoquery --unneeded`). | Named `dnf remove` / `yum remove`. Named `dnf upgrade pkg` / `yum upgrade pkg` after confirm. No full `dnf upgrade`. |
| `zypper` | `host.exec` `zypper` | Outdated (`list-updates`, `updatable`). Unneeded (`packages --unneeded`). | Named `zypper rm` and named `zypper update pkg` after confirm. |
| `brew` | `host.exec` `brew` | Outdated formulas/casks. Untrusted casks listed, not updated. Uninstall lines. | `brew uninstall` / `brew uninstall --cask` named. No greedy auto-cask force. |
| `flatpak` | `host.exec` `flatpak` | Unused runtimes (`flatpak uninstall --unused --dry-run`). Outdated apps (`remote-ls --updates --app` plus `list --app`). Leftover `.var/app` stays on `path-var-app`. | Named `flatpak uninstall` unused runtimes. Named `flatpak update` after confirm. Never `rm /usr/bin/flatpak`. |
| `snapd` | `host.exec` `snap` | Disabled leftover **revisions**. Orphan `~/snap/<name>` when the snap is not installed. Snap cache: review-only if not user-owned. Not the uninstall of still-installed snap apps (that stays Swift Stale/Outdated until the core port). | `snap remove <name> --revision <n>` named. `rm -rf` named `~/snap/<name>` only. Never silent `snap remove`. Never `rm /usr/bin/snap`. Never `snap remove --purge '*'`. |
| `npm` | `host.exec` `npm` | User-global `-g` leftovers. Outdated (`npm outdated -g --json`) report-only. Not every repo `node_modules`. | `npm -g uninstall` named. |
| `pnpm` | `host.exec` `pnpm` | User-global leftovers. | `pnpm remove -g` named. |
| `bun` | `host.exec` `bun` | User-global leftovers. | `bun remove -g` named. |
| `pip` | `host.exec` `pip` or `pip3` | Top-level user-site packages (`pip list --user --not-required`). Outdated report-only. Not walking every venv. | Named `pip uninstall` for globals. |
| `deno` | `host.exec` `ls` of `~/.deno/bin` | User-global Deno installs. Not every project. | Named `deno uninstall --global`. |
| `pipx` | `host.exec` `pipx` | Unused pipx tools. | `pipx uninstall` named. |
| `uv` | `host.exec` `uv` | `uv tool` leftovers. | `uv tool uninstall` named. |
| `gem` | `host.exec` `gem` | User-install outdated (`gem outdated`). Report-only. | `gem uninstall` named. |
| `composer` | `host.exec` `composer` | Global outdated (`composer global outdated`). Report-only. Not every project `vendor/`. | `composer global remove` named. |
| `container-runtime` | `host.exec` `docker` and/or `podman` | Dangling images, dangling volumes, exited containers. Idle-days skipped. Abandoned compose/pods and unnamed build cache not queried this turn. | Named `rmi` / `volume rm` / `rm`. Never `system prune -af`. Never delete the engine binary. |

`~/snap` orphan dirs belong to `snapd`, not a second path plugin.

### Path plugins

Linux leftover roots plus `path-user-bin`, `path-home-dot`, and `path-shadow`. Darwin leftover roots stay in Swift. Path plugins query via `ls` on `host.exec`. `path-user-bin` also uses `test` (`-h` / `-e`). `path-shadow` also uses `realpath` (one path, no flags) and `test -f`.

| id | Coeffect (path) | Reports | Suggested commands |
|---|---|---|---|
| `path-xdg-config` | `XDG_CONFIG_HOME` or `~/.config` | Orphan dirs/files in that root | `rm -rf` named path after confirm |
| `path-xdg-data` | `XDG_DATA_HOME` or `~/.local/share` | Same | named `rm` |
| `path-xdg-cache` | `XDG_CACHE_HOME` or `~/.cache` | Same | named `rm` |
| `path-xdg-state` | `XDG_STATE_HOME` or `~/.local/state` | Same | named `rm` |
| `path-xdg-lib` | `~/.local/lib` | Same | named `rm` |
| `path-var-app` | `~/.var/app` | Flatpak user data when the app is gone (ids still come from `flatpak` when that plugin is ACTIVE) | named `rm` of leftover dir; uninstall still via `flatpak` |
| `path-home-dot` | listed `homeDotData` leaves (`.mozilla`, `.wine`, …) | Leaf leftovers at `$HOME` | named `rm`. `.steam` here is a dir leaf, not the `steam` backlog plugin |
| `path-shadow` | overlay dirs vs packaged dirs | User overlays that hide a same-named packaged file (`status` shadow). Cleanup removes the overlay only | named `rm` of overlay path |
| `path-user-bin` | `~/.local/bin`, `~/bin` | Broken symlinks | named `rm` of the link |

## Backlog

Not built. No `core/src/<id>.zig`, so no `.wasm` is built and the host load list never contains one.

| id | Scope |
|---|---|
| `chocolatey` | Windows Chocolatey outdated/orphan packages |
| `nuget` | User-global NuGet leftovers (not every project `packages.config`) |
| `appstore` | Microsoft Store leftovers and outdated on Windows. macOS App Store / `mas` stays in Swift until a later `mas` plugin; that is a different id |
| `steam` | Steam games/leftovers on Windows. Linux/macOS Steam stays in Swift for now. Remaining Steam leftover work as this plugin later |

## Host load list

`core/build.sh` emits `appattic_core.wasm` plus one `.wasm` per in-scope plugin, and prints the argv below. Linux Qt (`pluginWasmFiles`, `ui/linux-qt/corehost.cpp:170`) keeps no second load registry: it loads every `.wasm` in `core/out` except the core. So a new plugin reaches both sides by being added to `wasm_sources` in `core/build.sh`, never by being listed in a second place; the shell then tags it from the presence table, and a plugin with no rule there gets tag `1`. Tag `0` on any of them: coeffect missing, empty findings, plugin still loads. Missing file: host skips that argv (INACTIVE). `chocolatey`, `nuget`, `appstore`, `steam` are backlog: no `.wasm` is built for them, so they are never arguments. `core/build.sh` also precompiles each module to a `<id>.wasm.cwasm` sidecar; the host deserializes it when it is at least as new as the `.wasm` and compiles the source otherwise, so a stale sidecar costs speed, never correctness.

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

User-global docker/podman leftovers. Both engines: tag findings with `engine`, do not merge IDs. Safety: never `system prune -af`, never unnamed bulk prune. `plugin_query` 0/1/2 = none/docker/podman.

Queries (named objects only): `images -f dangling=true`, `volume ls -f dangling=true`, `ps -a -f status=exited`. Idle-days skipped (CLI CREATED is relative text, not a timestamp). Abandoned compose/pods are not queried this turn. The unnamed build cache is not queried either, but it is still reported as a `build-cache` finding with `"id": null`, `"status": "review"`, and no command, so the omission is visible in the list instead of reading as a clean scan. Confirm script may include named `rmi <id>`, `volume rm <name>`, `rm <id>`. Live `host.exec` denies `rmi`, `rm`, `system prune`, `volume prune`.

## snapd

Ubuntu/Debian-family snap leftover *state*. Installed snap apps stay on Swift Stale Apps / Outdated (`snap remove <name>` / `snap refresh --list`) until the core port. This plugin queries `snap list --all` and `ls` of `~/snap`: disabled revisions, orphan `~/snap/<name>`, review-only cache if unnamed.

## path leftover roots

Each path plugin is a leftover-root guest (not a manager). Linux Qt and the host CLI load them with the manager plugins. Query is `ls` on `host.exec`. `path-user-bin` also uses `test` (`-h` / `-e`). `path-shadow` also uses `realpath` (one path, no flags) and `test -f`. Missing root: tag 0, empty findings.

## Shadowing

Overlay-vs-packaged findings are plugin `path-shadow` (`path_shadow.wasm`), not a special case in core. Swift `listShadowingOverlays` and `ShadowTests` remain in `AppAtticScan` until the Swift scan is ported. Core may still group extra paths.

## Errors

- Missing coeffect: INACTIVE or query tag 0, empty findings.
- ABI mismatch: do not run `plugin_query`.
- No object ids: no script lines.

## Consequences: what stays Swift until ported

Linux Qt already loads the WASM plugins. These remain in Swift for the macOS UI and the `appattic` CLI:

- `AppAtticScan` discover, usage, leftovers (including shadowing and `~/snap` as a leftover root), stale, outdated (`apt`/`pacman`/`dnf`/`zypper`/`brew`/`flatpak`/`snap`/`mas`), packages, recommend, cache, cleanup
- macOS App Store / `mas` (not the backlog `appstore` id)
- Linux/macOS Steam and CrossOver helpers
- CLI and SwiftCrossUI
- Settings, ignore list
- Tests under `tests/AppAtticScanTests`

## Tests

Host exit 0 loading the built plugin set (`core/build.sh` builds it; CI runs `bash scripts/linux-qt-link.sh` and then `scripts/verify-qt-link.sh`, which asserts the `ui/linux-qt/build/LINUX_QT_LINK.txt` proof). JSON plugin ids match. No `system prune`, no `snap remove --purge '*'`, no `rm -rf /usr/bin/snap`, no `apt-get purge -y` / `dpkg --purge` (`core/host/tests/hostexec_test.c` asserts those). Tag 0 yields empty findings.

## Settled and open questions

Settled by this record, kept here only so a later change knows what was decided: both docker and podman are listed and tagged by `engine` (no Settings picker); stopped containers are review-only with a named `rm` after confirm; the embedder is the Wasmtime C API, which `core/build.sh` requires and fails the build without.

Still open, and deliberately undecided by this record:

- `idleDays` default 30? No plugin emits `idleDays` (`core/src/container_runtime.zig:355` pins its absence) and nothing is filtered by age today. The native `Finding.idleDays` (`ui/linux-qt/finding.h:47`) is filled from `mtime` for the row label only, so a default is still undecided.
- podman-docker shim vs Docker Desktop?
