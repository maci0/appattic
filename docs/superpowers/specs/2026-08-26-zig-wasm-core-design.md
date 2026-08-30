# AppAttic Zig WASM core

Date: 2026-08-26

Replace in-process Swift scan logic with a Zig core compiled to WebAssembly. **Every package manager and every leftover scan path is a WASM plugin.** Native SwiftCrossUI stays on macOS (AppKit) in `src/macos`. Linux UI is C++ Qt 6 Widgets (`src/linux`), matching TMOG Linux. Do not silent-delete. Distro upgrades stay report-only. Qt-on-Linux is not claimed proven until `scripts/linux-qt-link.sh` succeeds on a real Linux host.

Paper: Shi, Zhang, Cui, *A Programming Paradigm for Spatiotemporal Composability*, https://github.com/cordiverse/paper (PDF, 88 pages). Text taken with `pdftotext` from `paper.pdf` on 2026-08-26. Cordis is TypeScript. AppAttic follows the same composability rules in Zig + WASM.

## Rule

The Zig WASM core is a loader: ABI, inject/coeffects, capability intercept, leftover *grouping* of findings plugins already produced, script concatenation, confirm boundary. Core has no switch on `apt` vs `pacman` vs `npm`. Core does not own filesystem roots. A manager or path that is missing its coeffect (binary not on PATH, root dir absent) stays INACTIVE. It does not crash the scan. Native UI is widgets only. Query is read-only. Emission (`rm`, `snap remove`, `dnf upgrade`) waits for confirm + reviewed `sh`.

`AppAtticScan` keeps building until a later port copies its tests into Zig. This spike does not delete it. Live CLI parsers are not in this spike. Findings WASM that exists today is canned.

## Paper principles that bind AppAttic

1. **Temporal composability** (ch. 1.1, 3.1). Every in-core mutation has an inverse. Unload reverts LIFO. Loading WASM is a tracked effect (ch. 6.4): drop the instance to unload.
2. **Spatial composability** (ch. 1.1, 3.2). Plugins declare `inject`. Missing provider: INACTIVE, not an error loop.
3. **Component = fiber** (ch. 4, 5.1.3). `inject` + `apply`. LOADING / ACTIVE / UNLOADING / INACTIVE.
4. **Declarative loader** (ch. 5.2). Entries: `id`, `url`, `isolate`, `intercept`, `config`, `disabled`.
5. **Capability inject + interception** (ch. 6.3). Declared keys are all a plugin may use. Allowlists live on the host.
6. **WASM sandbox** (ch. 6.3, 6.7). Untrusted code sees only embedder imports.
7. **System boundary** (ch. 6.1). Disk, images, distro packages sit outside Γ. Withhold emission until confirm. Script is compensation, not a tracked inverse of `rm`.
8. **Key identity** (ch. 6.6). Namespace `appattic.findings.<id>`. ABI integer 1.
9. **Zig comptime** (ch. 6.4). Later, for typed inject accessors. Not the spike.

The paper does not treat dialogs as plugins. Adaptation: plugin supplies confirm copy and script text. Native toolkit draws the alert and the sheet.

## Core vs plugin vs native

| Layer | Owns | Does not own |
|---|---|---|
| Native shell | Windows, lists, inspector, buttons, alerts, sheet, running confirmed `sh` | CLI parsing, classify, root lists |
| Zig core WASM | ABI, load/unload, intercept, merge/group findings, join scripts | Manager names, scan roots, brew/apt/snap parsers |
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
  "dialog": { "title": "…", "body": "…" }
}
```

`script` is null when nothing named. Host intercept rejects bulk wipes (`system prune`, `rmi -f`, `volume prune`, `snap remove --purge '*'`, `rm /usr/bin/snap`).

## Inventory (in scope)

Manifest dir: `core/plugins/<id>/manifest.json`. `url` is set only for WASM built in this spike. Others are manifest-only stubs (`url` null). No live query.

### Manager plugins

| id | Coeffect | Reports | Suggested commands (named objects only) |
|---|---|---|---|
| `apt` | `host.exec` `apt` | Outdated (report-only). Leaves/orphans later on Packages. | Never silent `apt upgrade`. Named `apt-get purge` only after confirm. Distro upgrade stays comment-only. |
| `pacman` | `host.exec` `pacman` | Outdated report-only. Orphans (`-Qtd`) later. | Named `pacman -Rns`. No `-Syu` in cleanup. |
| `dnf` | `host.exec` `dnf5` or `dnf` or `yum` (first found; yum is an alias, not its own id) | Outdated report-only. Leaves later. | Named `dnf remove`. No `dnf upgrade`. |
| `zypper` | `host.exec` `zypper` | Outdated report-only. | Named `zypper rm`. Distro upgrade report-only. |
| `brew` | `host.exec` `brew` | Outdated formulas/casks. Untrusted casks listed, not updated. Uninstall lines. | `brew uninstall` / `brew uninstall --cask` named. No greedy auto-cask force. |
| `flatpak` | `host.exec` `flatpak` | Outdated (updatable after confirm). Unused runtimes. User leftover dirs under `.var/app` when the app id is gone. | `flatpak uninstall` named. Never `rm /usr/bin/flatpak`. |
| `snapd` | `host.exec` `snap` | Disabled leftover **revisions**. Orphan `~/snap/<name>` when the snap is not installed. Snap cache: review-only if not user-owned. Not the uninstall of still-installed snap apps (that stays Swift Stale/Outdated until the core port). | `snap remove <name> --revision <n>` named. `rm -rf` named `~/snap/<name>` only. Never silent `snap remove`. Never `rm /usr/bin/snap`. Never `snap remove --purge '*'`. |
| `npm` | `host.exec` `npm` | User-global `-g` leftovers. Not every repo `node_modules`. | `npm -g uninstall` named. |
| `pnpm` | `host.exec` `pnpm` | User-global leftovers. | `pnpm remove -g` named. |
| `bun` | `host.exec` `bun` | User-global leftovers. | `bun remove -g` named. |
| `pip` | `host.exec` `pip` or `pip3` | User-site leftovers. Not walking every venv. | `pip uninstall` named. |
| `pipx` | `host.exec` `pipx` | Unused pipx tools. | `pipx uninstall` named. |
| `uv` | `host.exec` `uv` | `uv tool` leftovers. | `uv tool uninstall` named. |
| `gem` | `host.exec` `gem` | User-install gem leftovers. | `gem uninstall` named. |
| `composer` | `host.exec` `composer` | Global composer leftovers. Not every project `vendor/`. | `composer global remove` named. |
| `container-runtime` | `host.exec` `docker` and/or `podman` | Dangling images, idle images, unused volumes, stopped containers, abandoned pods/compose, unnamed build cache (review, no command). | Named `rmi` / `volume rm` / `rm` / `pod rm` / `compose -p … down`. Never `system prune -af`. Never delete the engine binary. |

`~/snap` orphan dirs belong to `snapd`, not a second path plugin.

### Path plugins

Each leftover root that Swift `scanRootsForPlatform` / `homeDataLeaves` / overlay helpers walk today. Classify (owned / system / orphaned) stays in the plugin later. Spike: canned WASM for Linux leftover roots (`path-xdg-config`, `path-xdg-data`, `path-xdg-cache`, `path-xdg-state`, `path-xdg-lib`, `path-var-app`) plus `path-shadow`. Other path ids stay manifest-only.

| id | Coeffect (path) | Reports | Suggested commands |
|---|---|---|---|
| `path-xdg-config` | `XDG_CONFIG_HOME` or `~/.config` | Orphan dirs/files in that root | `rm -rf` named path after confirm |
| `path-xdg-data` | `XDG_DATA_HOME` or `~/.local/share` | Same | named `rm` |
| `path-xdg-cache` | `XDG_CACHE_HOME` or `~/.cache` | Same | named `rm` |
| `path-xdg-state` | `XDG_STATE_HOME` or `~/.local/state` | Same | named `rm` |
| `path-xdg-lib` | `~/.local/lib` | Same | named `rm` |
| `path-var-app` | `~/.var/app` | Flatpak user data when the app is gone (ids still come from `flatpak` when that plugin is ACTIVE) | named `rm` of leftover dir; uninstall still via `flatpak` |
| `path-application-support` | `~/Library/Application Support` | macOS leftover dirs | named `rm` |
| `path-caches` | `~/Library/Caches` | Same | named `rm` |
| `path-preferences` | `~/Library/Preferences` | Orphan `.plist` | named `rm` of that plist |
| `path-saved-state` | `~/Library/Saved Application State` | Orphan `.savedState` | named `rm` |
| `path-containers` | `~/Library/Containers` | Orphan bundle-id containers | named `rm` |
| `path-group-containers` | `~/Library/Group Containers` | Orphan group containers | named `rm` |
| `path-logs` | `~/Library/Logs` | Orphan logs | named `rm` |
| `path-webkit` | `~/Library/WebKit` | Orphan WebKit data | named `rm` |
| `path-httpstorages` | `~/Library/HTTPStorages` | Orphan HTTP storage | named `rm` |
| `path-launchagents` | `~/Library/LaunchAgents` and `/Library/LaunchAgents` | Agents whose program is gone | named `rm` of the plist only |
| `path-home-dot` | listed `homeDotData` leaves (`.mozilla`, `.wine`, …) | Leaf leftovers at `$HOME` | named `rm`. `.steam` here is a dir leaf, not the `steam` backlog plugin |
| `path-overlay-shadow` | overlay dirs vs packaged dirs | User overlays that hide a same-named packaged file (`status` shadow). Cleanup removes the overlay only | named `rm` of overlay path |
| `path-user-bin` | `~/.local/bin`, `~/bin` | Broken symlinks | named `rm` of the link |

## Backlog

Not in this spike. No WASM. No `core/plugins/<id>/` manifest this turn. Not on the host load list.

| id | Scope |
|---|---|
| `chocolatey` | Windows Chocolatey outdated/orphan packages |
| `nuget` | User-global NuGet leftovers (not every project `packages.config`) |
| `appstore` | Microsoft Store leftovers and outdated on Windows. macOS App Store / `mas` stays in Swift until a later `mas` plugin; that is a different id |
| `steam` | Steam games/leftovers on Windows. Linux/macOS Steam stays in Swift for now. Remaining Steam leftover work as this plugin later |

## Spike host load list

Only these WASM modules, plus core:

1. `container-runtime` (`container_runtime.wasm`)
2. `snapd` (`snapd.wasm`)
3. `path-xdg-config` (`path_xdg_config.wasm`)

```bash
./core/build.sh
./core/out/host ./core/out/appattic_core.wasm \
  ./core/out/container_runtime.wasm=2 \
  ./core/out/snapd.wasm=1 \
  ./core/out/path_xdg_config.wasm=1
```

Tag `0` on any of them: coeffect missing, empty findings, plugin still loads. Missing file: host skips that argv (INACTIVE). `chocolatey`, `nuget`, `appstore`, `steam` are not arguments and must not be added.

## container-runtime (fixture parsers)

User-global docker/podman leftovers. Both engines: tag findings with `engine`, do not merge IDs. Safety: never `system prune -af`, never unnamed bulk prune. Spike: `plugin_query` 0/1/2 = none/docker/podman.

Queries (named objects only): `images -f dangling=true`, `volume ls -f dangling=true`, `ps -a -f status=exited`. Idle-days skipped (CLI CREATED is relative text, not a timestamp). Unnamed build cache is review-only (`command` null). Abandoned compose/pods not queried this turn. Confirm script may include named `rmi <id>`, `volume rm <name>`, `rm <id>`. Live `host.exec` denies `rmi`, `rm`, `system prune`, `volume prune`.

## snapd (canned)

Ubuntu/Debian-family snap leftover *state*. Installed snap apps stay on Swift Stale Apps / Outdated (`snap remove <name>` / `snap refresh --list`) until the core port. This plugin: disabled revisions, orphan `~/snap/<name>`, review-only cache if unnamed.

## path-xdg-config (canned)

One leftover-root plugin so the host proves a path stub, not only managers.

## Shadowing

Moves to plugin `path-overlay-shadow`, not a special case in core. Swift `listShadowingOverlays` and `ShadowTests` stay until that plugin is implemented for real. Core may still group extra paths.

## Errors

- Missing coeffect: INACTIVE or query tag 0, empty findings.
- ABI mismatch: do not run `plugin_query`.
- No object ids: no script lines.

## What stays Swift until ported

- `AppAtticScan` discover, usage, leftovers (including shadowing and `~/snap` as a leftover root), stale, outdated (`apt`/`pacman`/`dnf`/`zypper`/`brew`/`flatpak`/`snap`/`mas`), recommend, cache, cleanup
- macOS App Store / `mas` (not the backlog `appstore` id)
- Linux/macOS Steam and CrossOver helpers
- CLI and SwiftCrossUI
- Settings, ignore list
- Tests under `tests/AppAtticScanTests`

## Tests

Host exit 0 loading the three WASM plugins. JSON plugin ids match. No `system prune`, no `snap remove --purge '*'`, no `rm /usr/bin/snap`. Tag 0 yields empty findings.

## Open questions

- Both docker and podman: dual tagged lists vs Settings picker?
- Stopped containers: default cleanup vs review-only?
- `idleDays` default 30?
- Shipping Wasmtime vs another embedder?
- podman-docker shim vs Docker Desktop?
