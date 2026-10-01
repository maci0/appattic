# Zig WASM core

Design: [`docs/specs/2026-08-26-zig-wasm-core-design.md`](../docs/specs/2026-08-26-zig-wasm-core-design.md).

Needs `zig` 0.16 (`.zig-version`) and, to run the host, the Wasmtime C API (`brew install zig wasmtime`, or `scripts/linux-deps.sh --install-wasmtime` on Linux). Test one plugin with `./core/build.sh test brew.zig`.

Every manager and leftover path is a plugin: one `<id>.zig` compiled to `<id>.wasm`, except `core.zig`, which is the loader and lands as `appattic_core.wasm`. Built WASM matches the spec **Host load list**.

> **Mirror rule — read before changing a parser.** The same tool-output
> grammars are implemented twice: here (`core/src/<id>.zig`, loaded by the
> Linux Qt UI) and in Swift (`Sources/AppAtticScan/{Outdated,Packages,BrewInfo}.swift`,
> used by the CLI and macOS UI), which never loads this core. A grammar fix on
> one side must land on the other. The Swift
> `ParserParityTests` pin edge behavior; mirror new
> edges there too. `linux-system-names.txt` is mirrored the same way, with
> `core/src/linux-system-names.txt` as the declaration: `@embedFile` and a
> SwiftPM resource each need the file inside their own tree, and
> `scripts/lint.sh` fails when the two copies differ.
>
> Which argv the host will run, and which findings it refuses to run at all,
> is `appattic_host_exec_allowed` (`core/host/hostexec.h`) and the
> per-manager Inventory table in the spec. Read those rather than a list
> restated here.
>
> Two asymmetries a table of pairs would hide: `gem.zig`, `composer.zig` and
> `apt.zig`'s `parsePpaSources` have no Swift counterpart yet, and Zig adds a
> second `pip list --user --outdated --format=json` query on top of the
> `--not-required` listing both sides run, so it also reports outdated rows
> Swift does not. `BrewInfo.swift` reads Homebrew's "Refusing to load
> cask ... from untrusted tap" error and marks those rows report-only;
> `brew.zig` does not, so every outdated cask it finds is updatable.
>
> Overlay findings are `path-shadow`, which reads its one path with `realpath`
> and no flags, then `test -f`. Darwin leftover roots stay in Swift
> `AppAtticScan`. Query plugins call `host.exec`. Tag `0` means the coeffect is
> missing (plugin inactive). Darwin injects fixtures so tests do not need those
> daemons.

```bash
./core/build.sh test brew.zig
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

Tag `0` = missing coeffect (empty findings). Missing `.wasm` file: host skips that plugin.

Host intercept rejects `system prune`, `rmi -f`, `volume prune`, `snap remove --purge`, `rm /usr/bin/snap`, `rm -rf /usr/bin/snap`, `rm /usr/bin/flatpak`. `host.exec` also denies those as argv. The named forms `rmi <id>`, `volume rm <id>` and `rm <id>` (containers and volumes are removed by id, the finding also carries the name) are never executable through the host: they appear in the confirm-script JSON and in each finding's `command` field.

The Linux Qt 6 window (`ui/linux-qt`) links `core/host/embed.c` and the same Wasmtime C API. It is not Gtk.

## Benchmarks

`bash core/bench.sh [filter-substr]` times the parsers in
`core/bench/bench.zig` natively: the path listing, the system-name check (a hit
and a miss), the apt outdated parser, the JSON buffer, and the JSON dependency
scanner. It is not part of `core/build.sh` and not a gate; run it on demand to
compare two changes. Linux only, and it needs the `.zig-version` toolchain.

## Backlog

Not built. Not on the host load list. See spec heading **Backlog** for the
ids and their scope.

The Swift scan library (`AppAtticScan`) and macOS UI are not linked to this directory. Linux Qt 6 loads `appattic_core.wasm` through `embed.c`.
