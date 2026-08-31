# Zig WASM core (spike)

Design: [`docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md`](../docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md).

Needs `zig` (0.16 used here) and, to run the host, the Wasmtime C API (`brew install zig wasmtime`, or `scripts/linux-deps.sh --install-wasmtime` on Linux).

Every manager and leftover path is a plugin. Manifests live in `src/core/plugins/<id>/manifest.json`. Builds WASM for `container-runtime`, `snapd`, `path-xdg-config`, `path-xdg-data`, `path-xdg-cache`, `path-xdg-state`, `path-xdg-lib`, `path-var-app`, `path-shadow`, `pacman`, `apt`, `dnf`, `zypper`, `flatpak`, `npm`, `pnpm`, `bun`, `pipx`, `uv`, `brew`, `gem`, `composer`, and `pip`. Other in-scope ids are manifest stubs. Query plugins call `host.exec`. The embedder allowlists `snap`, `pacman` (`-Qdt` / `-Qu`), `apt-get -s autoremove` / `apt list --upgradable`, `dnf`/`dnf5`/`yum` (`repoquery --unneeded`, `list --upgrades`, `check-update`), `zypper` (`packages --unneeded`, `list-updates`), `flatpak`, `npm`, `pnpm`, `bun`, `pipx`, `uv`, `brew` (`outdated` with json flags), `gem outdated`, `composer global outdated`, `pip`/`pip3` (`list --user --outdated --format=json`), `docker`/`podman` (dangling images, dangling volumes, exited containers), and `ls`, and denies destructive argv (`rm`, `rmi`, `snap remove`, `system prune`, `volume prune`, `purge`, `upgrade`, `install`, `-y`, `pacman -Syu`/`-R*`, `dnf leaves`/`remove`/`upgrade`, `zypper rm`/`dup`/`update`, `apt-get upgrade`, `flatpak uninstall -y`, `npm uninstall`, `pnpm remove`, `bun remove`, `pipx uninstall`, `uv tool uninstall`, `pip install`/`pip uninstall`, `pip list` without `--user`, `brew uninstall`/`brew upgrade`, `gem uninstall`/`gem update`, `composer global update`/`composer global remove`). Distro outdated findings are report-only (`kind` outdated, named upgrade in confirm JSON only, never live-exec). Language queries are user-global only (`npm ls -g` / `npm outdated -g`, `pnpm ls -g` / `pnpm outdated -g`, `bun pm ls -g`, `pipx list`, `uv tool list`, `gem outdated`, `composer global outdated`, `pip list --user --outdated`). Homebrew reports user-global outdated formulae/casks. Gem, Composer globals, and pip user-site are report-only (`updatable` false). Darwin injects fixtures so tests do not need those daemons. Tag `0` means the coeffect is missing (plugin inactive).

```bash
./src/core/build.sh
./src/core/out/host ./src/core/out/appattic_core.wasm \
  ./src/core/out/container_runtime.wasm=2 \
  ./src/core/out/snapd.wasm=1 \
  ./src/core/out/path_xdg_config.wasm=1 \
  ./src/core/out/path_xdg_data.wasm=1 \
  ./src/core/out/path_xdg_cache.wasm=1 \
  ./src/core/out/path_xdg_state.wasm=1 \
  ./src/core/out/path_xdg_lib.wasm=1 \
  ./src/core/out/path_var_app.wasm=1 \
  ./src/core/out/path_shadow.wasm=1 \
  ./src/core/out/pacman.wasm=1 \
  ./src/core/out/apt.wasm=1 \
  ./src/core/out/dnf.wasm=1 \
  ./src/core/out/zypper.wasm=1 \
  ./src/core/out/flatpak.wasm=1 \
  ./src/core/out/npm.wasm=1 \
  ./src/core/out/pnpm.wasm=1 \
  ./src/core/out/bun.wasm=1 \
  ./src/core/out/pipx.wasm=1 \
  ./src/core/out/uv.wasm=1 \
  ./src/core/out/brew.wasm=1 \
  ./src/core/out/gem.wasm=1 \
  ./src/core/out/composer.wasm=1 \
  ./src/core/out/pip.wasm=1
```

Tag `0` = missing coeffect (empty findings). Missing `.wasm` file: host skips that plugin.

Host intercept rejects `system prune`, `rmi -f`, `volume prune`, `snap remove --purge`, `rm /usr/bin/snap`. `host.exec` also denies those as argv. Named `rmi <id>` / `volume rm <name>` / `rm <id>` appear only in confirm-script JSON.

The Linux Qt 6 window (`src/linux`) links `src/core/host/embed.c` and the same Wasmtime C API. It is not Gtk.

## Backlog

Not built. Not on the host load list. See spec heading **Backlog**.

| id | Scope |
|---|---|
| `chocolatey` | Windows Chocolatey outdated/orphan packages |
| `nuget` | User-global NuGet leftovers (not every project `packages.config`) |
| `appstore` | Microsoft Store leftovers and outdated (Windows). macOS App Store / `mas` stays in Swift; different id |
| `steam` | Steam leftovers on Windows. Linux/macOS Steam stays in Swift for now |

Swift UI (`AppAtticScan`) is not linked to this directory. Linux Qt 6 loads `appattic_core.wasm` through `embed.c`.
