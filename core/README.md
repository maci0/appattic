# Zig WASM core

The scan core the Linux window runs on: a `wasm32` ABI marker module, one plugin per package manager or leftover root, and a C Wasmtime loader/host. The Linux Qt 6 window (`ui/linux-qt`) links `core/host/embed.c` and loads `appattic_core.wasm` through it. The Swift scan library (`AppAtticScan`), the CLI, and the macOS window do not use this directory.

Design, the **Host load list**, the per-manager **Inventory**, and the **Backlog**: [`docs/specs/2026-08-26-zig-wasm-core-design.md`](../docs/specs/2026-08-26-zig-wasm-core-design.md).

## Build and test

Needs exactly Zig 0.17.0 (`.zig-version`) and, to run the host, the Wasmtime C API. On Linux, use `scripts/linux-deps.sh --install-zig --install-wasmtime`. On macOS, `brew install wasmtime` supplies the C API; install the pinned Zig release separately if Homebrew's Zig version does not match. The build rejects other Zig versions.

```bash
./core/build.sh                               # every module, into core/out/
./core/build.sh test brew.zig                 # one plugin's tests
./core/build.sh test jsonbuf.zig isSafeIdent  # one test, from the module that declares it
./core/build.sh test-core                     # the whole core, no Wasmtime or Qt
```

Test filters and job count: [CONTRIBUTING.md](../CONTRIBUTING.md#tests-and-gates).

## Plugins

Each plugin is one `src/<id>.zig` compiled to `<id>.wasm`. `core.zig` exports only `core_abi_version` and lands as `appattic_core.wasm`; `core/host/embed.c` loads the modules. `wasm_sources` in `core/build.sh` is the list that gets built, and it matches the spec's Host load list; a missing `.wasm` file is skipped by the host.

Query plugins call `host.exec`. Which argv the host will run, and which findings it refuses outright, is `appattic_host_exec_allowed` in `core/host/hostexec.h` together with the spec's Inventory table. The host passes each plugin a presence tag (`pluginTag` in `ui/linux-qt/corehost.cpp`, `=N` in the argv below). Tag `0` means the coeffect is missing (binary not on `PATH`, root directory absent): the plugin still loads and returns no findings. Other values are plugin-defined. For `container_runtime`, the Qt host picks tag `2` for Podman when present, otherwise `1` for Docker, otherwise `0`. The plugin queries only the chosen engine. On Darwin the host serves fixtures unless `APPATTIC_HOST_EXEC_LIVE` is on, so tests need none of the Linux package managers.

The overlay plugin is `path-shadow`: it reads its one path with `realpath` and no flags, then `test -f`. Darwin leftover roots stay in Swift `AppAtticScan`.

Running the host by hand:

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

`core/build.sh` prints this argv as its `try:` line, and `scripts/lint.sh` fails when the block above or the spec's copy drifts from it.

## What the host refuses

The host rejects plugin output naming `system prune`, `rmi -f`, `volume prune`, `snap remove --purge`, `rm /usr/bin/snap`, `rm -rf /usr/bin/snap`, or `rm /usr/bin/flatpak`, and `host.exec` denies those as argv. The named removals `rmi <id>`, `volume rm <name>`, and `rm <id>` (images and containers by id, volumes by name) are never run through the host either: they appear only in the confirm-script JSON and in each finding's `command` field, for the window to put in a script you confirm.

## Mirror rule

Read this before changing a parser. The same tool-output grammars are implemented twice: here, in `core/src/<id>.zig`, and in Swift, in `Sources/AppAtticScan/{Outdated,Packages,BrewInfo}.swift`. A grammar fix on one side must land on the other, and a new edge case goes into the Swift `ParserParityTests` too.

`linux-system-names.txt` is mirrored the same way. `core/src/linux-system-names.txt` is the declaration; `@embedFile` and a SwiftPM resource each need the file inside their own tree, and `scripts/lint.sh` fails when the two copies differ.

Where the two sides differ on purpose:

- `gem.zig`, `composer.zig`, and `apt.zig`'s `parsePpaSources` have no Swift counterpart yet.
- Zig runs a second `pip list --user --outdated --format=json` query on top of the `--not-required` listing both sides run, so it also reports outdated pip rows Swift does not.
- `BrewInfo.swift` reads Homebrew's "Refusing to load cask ... from untrusted tap" error and marks those rows report-only; `brew.zig` does not, so every outdated cask it finds is updatable.

## Benchmarks

`bash core/bench.sh [filter-substr]` times the parsers in `core/bench/bench.zig` natively: the path listing, the system-name check (a hit and a miss), the apt outdated parser, the JSON buffer, and the JSON dependency scanner. Run it on demand to compare two changes; it is not part of `core/build.sh` and not a gate. Linux only, with the `.zig-version` toolchain.
