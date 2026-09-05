# Zig WASM core (spike)

Design: [`docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md`](../docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md).

Needs `zig` 0.16 (`.zig-version`) and, to run the host, the Wasmtime C API (`brew install zig wasmtime`, or `scripts/linux-deps.sh --install-wasmtime` on Linux). Test one plugin with `./core/build.sh test brew.zig`.

Every manager and leftover path is a plugin. Manifests live in `core/plugins/<id>/manifest.json`. Built WASM matches the spec **Host load list**: every in-scope id except `path-overlay-shadow` (`url` null; overlay findings are `path-shadow`). Query plugins call `host.exec`. The embedder allowlists `snap`, `pacman` (`-Qdt` / `-Qu`), `apt-get -s autoremove` / `apt list --upgradable`, `dnf`/`dnf5`/`yum` (`repoquery --unneeded`, `list --upgrades`, `check-update`), `zypper` (`packages --unneeded`, `list-updates`), `flatpak` (`uninstall --unused` / `remove --unused`), `npm`, `pnpm`, `bun`, `pipx`, `uv`, `brew` (`outdated` with json flags), `gem outdated`, `composer global outdated`, `pip`/`pip3` (`list --user --outdated --format=json`), `docker`/`podman` (dangling images, dangling volumes, exited containers), `ls`, `readlink` (`-f` / `-n`), `realpath` (one path, no flags), and `test` (`-e` / `-f` / `-h` / `-L`), and denies destructive argv (`rm`, `rmi`, `snap remove`, `system prune`, `volume prune`, `purge`, `upgrade`, `install`, `-y`, `pacman -Syu`/`-R*`, `dnf leaves`/`remove`/`upgrade`, `zypper rm`/`dup`/`update`, `apt-get upgrade`, `flatpak uninstall -y`, `npm uninstall`, `pnpm remove`, `bun remove`, `pipx uninstall`, `uv tool uninstall`, `pip install`/`pip uninstall`, `pip list` without `--user`, `brew uninstall`/`brew upgrade`, `gem uninstall`/`gem update`, `composer global update`/`composer global remove`). Distro outdated findings are report-only (`kind` outdated, named upgrade in confirm JSON only, never live-exec). Language queries are user-global only (`npm ls -g` / `npm outdated -g`, `pnpm ls -g` / `pnpm outdated -g`, `bun pm ls -g`, `pipx list`, `uv tool list`, `gem outdated`, `composer global outdated`, `pip list --user --outdated`). Homebrew reports user-global outdated formulae/casks. Gem, Composer globals, and pip user-site are report-only (`updatable` false). Darwin injects fixtures so tests do not need those daemons. Tag `0` means the coeffect is missing (plugin inactive).

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
  ./core/out/path_application_support.wasm=1 \
  ./core/out/path_caches.wasm=1 \
  ./core/out/path_preferences.wasm=1 \
  ./core/out/path_saved_state.wasm=1 \
  ./core/out/path_containers.wasm=1 \
  ./core/out/path_group_containers.wasm=1 \
  ./core/out/path_logs.wasm=1 \
  ./core/out/path_webkit.wasm=1 \
  ./core/out/path_httpstorages.wasm=1 \
  ./core/out/path_launchagents.wasm=1 \
  ./core/out/path_shadow.wasm=1 \
  ./core/out/pacman.wasm=1 \
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
  ./core/out/pip.wasm=1
```

Tag `0` = missing coeffect (empty findings). Missing `.wasm` file: host skips that plugin.

Host intercept rejects `system prune`, `rmi -f`, `volume prune`, `snap remove --purge`, `rm /usr/bin/snap`. `host.exec` also denies those as argv. Named `rmi <id>` / `volume rm <name>` / `rm <id>` appear only in confirm-script JSON.

The Linux Qt 6 window (`ui/linux-qt`) links `core/host/embed.c` and the same Wasmtime C API. It is not Gtk.

## Backlog

Not built. Not on the host load list. See spec heading **Backlog**.

| id | Scope |
|---|---|
| `chocolatey` | Windows Chocolatey outdated/orphan packages |
| `nuget` | User-global NuGet leftovers (not every project `packages.config`) |
| `appstore` | Microsoft Store leftovers and outdated (Windows). macOS App Store / `mas` stays in Swift; different id |
| `steam` | Steam leftovers on Windows. Linux/macOS Steam stays in Swift for now |

The Swift scan library (`AppAtticScan`) and macOS UI are not linked to this directory. Linux Qt 6 loads `appattic_core.wasm` through `embed.c`.
