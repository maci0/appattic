#ifndef APPATTIC_HOSTEXEC_H
#define APPATTIC_HOSTEXEC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define APPATTIC_HOST_EXEC_DENY (-1)
#define APPATTIC_HOST_EXEC_FAIL (-2)
#define APPATTIC_HOST_EXEC_BAD (-3)

/* 1 if argv0 is snap/pacman/apt-get/apt/ls/readlink/realpath/test/dnf/dnf5/yum/zypper/flatpak
   /npm/pnpm/bun/pipx/pip/pip3/uv/brew/gem/composer/docker/podman and argv is a read-only query.
   docker/podman: images -f dangling=true, volume ls -f dangling=true,
   ps -a -f status=exited only.
   ls: -1/-a/-A (glued ok) and at most one path. No -R/-l/--*.
   brew: outdated with --json / --json=v2 only.
   gem: outdated only. composer: global outdated only.
   pip/pip3: list --user --format=json (optional --outdated).
   pacman: -Q* queries including -Qu. apt: -s autoremove, list --upgradable.
   dnf: repoquery --unneeded, list --upgrades, check-update.
   zypper: packages --unneeded, list-updates.
   flatpak: uninstall/remove --unused with --dry-run/--simulate/-s only.
   0 if missing, unknown binary, metacharacters, or destructive argv
   (rm, rmi, snap remove, system prune, volume prune, purge, upgrade, install, -y,
    pacman -Syu/-R*, dnf leaves/remove/upgrade, zypper rm/dup/update, flatpak uninstall -y,
    npm/pnpm/bun uninstall/remove/add, pipx uninstall, uv tool uninstall,
    pip/pip3 install/uninstall, pip list without --user, brew uninstall/upgrade/--greedy,
    gem uninstall/update/install, composer global update/remove). Language queries must be
    user-global (-g / tool list / composer global / pip --user). */
int appattic_host_exec_allowed(const char *cmdline);

/* 1 when FLATPAK_ID is set. Live exec then uses flatpak-spawn --host so
   package-manager queries reach the host, not the sandbox PATH. */
int appattic_host_in_flatpak(void);

/* Prepend ~/.local/bin, ~/.bun/bin, ~/.deno/bin, nvm, volta, cargo, and
   similar user tool dirs to PATH. Idempotent. Desktop launches often have
   only /usr/bin, so pip/uv/bun/node/deno would otherwise be invisible. */
void appattic_host_apply_user_path(void);

/* Run an allowlisted query. Denied commands return APPATTIC_HOST_EXEC_DENY
   and write nothing. Darwin (and APPATTIC_HOST_EXEC_FIXTURE=1) injects
   canned stdout so tests do not need snap/pacman/apt daemons.
   APPATTIC_HOST_EXEC_LIVE=1 forks execvp when the binary is on PATH.
   Live exec is capped at 60s; a hang returns FAIL and the child is killed.
   Returns nbytes written, or a negative APPATTIC_HOST_EXEC_* code. */
int appattic_host_exec(const char *cmdline, char *out, size_t cap);

/* Cooperative cancel for a live scan. request_cancel aborts the current
   host.exec child and remaining plugins. The embedder calls clear_cancel at
   the start of a new scan. wasm_run does not clear a pending cancel. */
void appattic_host_exec_request_cancel(void);
void appattic_host_exec_clear_cancel(void);
int appattic_host_exec_cancelled(void);

#ifdef __cplusplus
}
#endif

#endif
