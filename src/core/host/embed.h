#ifndef APPATTIC_EMBED_H
#define APPATTIC_EMBED_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*appattic_json_fn)(const char *json, size_t json_len, void *user);

/* Load core.wasm, then each plugin spec ("path.wasm" or "path.wasm=tag").
   tag 0 = missing coeffect; default 1. container-runtime: 1 docker, 2 podman.
   Missing plugin files are skipped. Returns 0 on success, 1 on plugin/abi error, 2 on usage.
   Host intercept rejects `system prune`, `rmi -f`, `volume prune`,
   `snap remove --purge`, `rm /usr/bin/snap`.
   `host.exec` allowlist: snap, pacman (-Qdt/-Qu), apt-get -s autoremove,
   apt list --upgradable, dnf repoquery --unneeded, dnf list --upgrades /
   check-update, zypper packages --unneeded, zypper list-updates, ls,
   test -e/-h/-L, brew outdated --json, pip/pip3 list --user --outdated --format=json,
   docker/podman query shapes.
   Destructive argv (rm, rmi, snap remove, system prune, volume prune, purge,
   upgrade, pacman -Syu/-R*, dnf upgrade, zypper update, apt-get upgrade,
   pip install/uninstall, brew uninstall/upgrade) is denied.
   Darwin injects fixtures (no daemons). APPATTIC_HOST_EXEC_LIVE=1 runs execvp. */
int appattic_wasm_run(
    const char *core_wasm,
    char **plugin_specs,
    int plugin_count,
    appattic_json_fn on_json,
    void *user,
    char *err,
    size_t errlen
);

#ifdef __cplusplus
}
#endif

#endif
