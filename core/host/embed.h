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
   `host.exec` allowlist is `appattic_host_exec_allowed` in hostexec.h:
   snap, pacman, apt-get/apt, ls, readlink, realpath, test, dnf/dnf5/yum, zypper,
   flatpak, npm, pnpm, bun, pipx, pip/pip3, uv, brew, gem, composer,
   docker/podman. Query argv only (see hostexec.h). Destructive argv is denied.
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
