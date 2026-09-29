/* pipe2, for the close-on-exec flag the two ends of a query's pipe need
   without a window in which a concurrent fork could inherit them. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "hostexec.h"

#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_CMD 512
#define MAX_TOK 16
#define HOST_EXEC_TIMEOUT_MS 60000
#define HOST_EXEC_KILL_GRACE_MS 1000
/* Post-EOF wait backs off from 1 ms to this, so a child that closes stdout and
   keeps working is not billed a flat tick per probe. Reaping a signalled child
   polls at REAP_POLL_MS instead: that wait is bounded by the grace period, so
   a coarse tick only adds latency to a result the caller already gave up on. */
#define HOST_EXEC_POLL_MIN_MS 1
#define HOST_EXEC_POLL_MAX_MS 50
#define HOST_EXEC_REAP_POLL_MS 2
#define HOST_EXEC_POLL_SLICE_MS 100

static int eq(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}

static const char *base_of(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

static int destructive_token(const char *t) {
    return eq(t, "rm") || eq(t, "rmi") || eq(t, "rmdir") || eq(t, "remove") ||
           eq(t, "purge") || eq(t, "prune") || eq(t, "upgrade") || eq(t, "dist-upgrade") ||
           eq(t, "full-upgrade") || eq(t, "-Syu") || eq(t, "-Syyu") ||
           eq(t, "-Rns") || eq(t, "-Rnsc") || eq(t, "-Rn") || eq(t, "-R") ||
           eq(t, "uninstall") || eq(t, "erase") || eq(t, "system") ||
           eq(t, "-rf") || eq(t, "-fr") || eq(t, "--force") || eq(t, "--purge") ||
           eq(t, "-y") || eq(t, "--assumeyes") || eq(t, "--yes") ||
           eq(t, "install") || eq(t, "update") || eq(t, "dup") || eq(t, "leaves") ||
           eq(t, "add") || eq(t, "upgrade-all") || eq(t, "inject");
}

/* Config injection: a token that hands the manager a setting whose value is run
   as a command. `apt list --upgradable -o APT::Update::Pre-Invoke::=id` is a
   listing-shaped argv that `destructive_token` never sees, and apt runs the
   Pre-Invoke value through the shell, so the allowlist returned true and the
   guest got a subprocess of its own. None of the real queries need any of
   these switches, so the whole family is denied. */
static int config_injection_token(const char *t) {
    return eq(t, "-o") || strncmp(t, "-o", 2) == 0 ||
           eq(t, "-c") || eq(t, "--config") || strncmp(t, "--config", 8) == 0 ||
           eq(t, "--opt") || strncmp(t, "--opt", 5) == 0 ||
           eq(t, "--setopt") || strncmp(t, "--setopt", 8) == 0 ||
           strncmp(t, "--pre-invoke", 12) == 0 ||
           strncmp(t, "--post-invoke", 13) == 0 ||
           strncmp(t, "--pre-remove-invoke", 19) == 0 ||
           strncmp(t, "--post-remove-invoke", 20) == 0 ||
           eq(t, "--hook") || eq(t, "--root") || strncmp(t, "--root", 6) == 0 ||
           eq(t, "--load-profile") || eq(t, "--admindir") ||
           eq(t, "--dbpath") || strncmp(t, "--dbpath", 8) == 0 ||
           eq(t, "--logfile") || strncmp(t, "--logfile", 9) == 0 ||
           eq(t, "--sysroot") || strncmp(t, "--sysroot", 8) == 0;
}

/* ls: listing flags only (-1/-a/-A, glued). One optional path. No -R/-l/--*. */
static int ls_listing_flag(const char *t) {
    if (!t || t[0] != '-' || t[1] == '\0' || t[1] == '-') return 0;
    for (const char *p = t + 1; *p; p++) {
        if (*p != '1' && *p != 'a' && *p != 'A') return 0;
    }
    return 1;
}

static int ls_query_ok(char **tok, int n) {
    int has_path = 0;
    for (int i = 1; i < n; i++) {
        const char *t = tok[i];
        if (t[0] == '-') {
            if (!ls_listing_flag(t)) return 0;
            continue;
        }
        if (has_path) return 0;
        has_path = 1;
    }
    return 1;
}

/* test -e / -f / -h / -L only. No -w/-x/-d or other predicates. */
static int test_query_ok(char **tok, int n) {
    int has_flag = 0;
    int has_path = 0;
    for (int i = 1; i < n; i++) {
        const char *t = tok[i];
        if (t[0] == '-') {
            if (!eq(t, "-e") && !eq(t, "-f") && !eq(t, "-h") && !eq(t, "-L")) return 0;
            has_flag = 1;
            continue;
        }
        if (has_path) return 0;
        has_path = 1;
    }
    return has_flag && has_path;
}

/* docker/podman query shapes only: images -f dangling=true, volume ls -f dangling=true,
   ps -a -f status=exited. Never rmi, rm, prune, system. */
static int ctr_query_ok(char **tok, int n) {
    int has_images = 0, has_volume = 0, has_ls = 0, has_ps = 0;
    int has_a = 0, has_dangling = 0, has_exited = 0;
    for (int i = 1; i < n; i++) {
        const char *t = tok[i];
        if (eq(t, "images")) {
            has_images = 1;
            continue;
        }
        if (eq(t, "volume")) {
            has_volume = 1;
            continue;
        }
        if (eq(t, "ls")) {
            has_ls = 1;
            continue;
        }
        if (eq(t, "ps")) {
            has_ps = 1;
            continue;
        }
        if (eq(t, "-a") || eq(t, "--all")) {
            has_a = 1;
            continue;
        }
        if (eq(t, "-f") || eq(t, "--filter")) continue;
        if (eq(t, "dangling=true") || eq(t, "dangling=1")) {
            has_dangling = 1;
            continue;
        }
        if (eq(t, "status=exited")) {
            has_exited = 1;
            continue;
        }
        if (strncmp(t, "--filter=", 9) == 0) {
            const char *v = t + 9;
            if (eq(v, "dangling=true") || eq(v, "dangling=1")) has_dangling = 1;
            else if (eq(v, "status=exited")) has_exited = 1;
            else return 0;
            continue;
        }
        return 0;
    }
    if (has_images && !has_volume && !has_ps && has_dangling) return 1;
    if (has_volume && has_ls && !has_images && !has_ps && has_dangling) return 1;
    if (has_ps && has_a && has_exited && !has_images && !has_volume) return 1;
    return 0;
}

/* Overflow: keep complete lines only. A truncated last name must not become a leftover. */
static int take_complete_output(char *out, size_t n, int truncated) {
    if (n > (size_t)INT_MAX) n = (size_t)INT_MAX;
    if (!truncated) return (int)n;
    while (n > 0 && out[n - 1] != '\n') n--;
    if (n == 0) return APPATTIC_HOST_EXEC_BAD;
    return (int)n;
}

static int parse_argv(const char *cmdline, char *buf, size_t bufn, char **argv, int maxn) {
    if (!cmdline || !cmdline[0] || strlen(cmdline) >= bufn) return -1;
    if (strpbrk(cmdline, ";|&`$<>\n\r()")) return -1;
    snprintf(buf, bufn, "%s", cmdline);
    int n = 0;
    /* strtok_r, not strtok: the cursor in strtok is process-global, so two
     * threads tokenizing at once hand each other's pointers back and the
     * allowlist can judge a different argv than the one execvp runs. */
    char *save = NULL;
    for (char *p = strtok_r(buf, " \t", &save); p && n < maxn; p = strtok_r(NULL, " \t", &save)) {
        argv[n++] = p;
    }
    return n;
}

int appattic_host_exec_allowed(const char *cmdline) {
    char buf[MAX_CMD];
    char *tok[MAX_TOK];
    int n = parse_argv(cmdline, buf, sizeof buf, tok, MAX_TOK);
    if (n < 1) return 0;

    const char *base = base_of(tok[0]);
    const int is_snap = eq(base, "snap");
    const int is_pacman = eq(base, "pacman");
    const int is_aur = eq(base, "paru") || eq(base, "yay") || eq(base, "pikaur");
    const int is_apt = eq(base, "apt-get") || eq(base, "apt");
    const int is_dpkg = eq(base, "dpkg");
    const int is_ls = eq(base, "ls");
    const int is_readlink = eq(base, "readlink");
    const int is_realpath = eq(base, "realpath");
    const int is_test = eq(base, "test");
    const int is_dnf = eq(base, "dnf") || eq(base, "dnf5") || eq(base, "yum");
    const int is_zypper = eq(base, "zypper");
    const int is_flatpak = eq(base, "flatpak");
    const int is_npm = eq(base, "npm");
    const int is_pnpm = eq(base, "pnpm");
    const int is_bun = eq(base, "bun");
    const int is_pipx = eq(base, "pipx");
    const int is_pip = eq(base, "pip") || eq(base, "pip3");
    const int is_uv = eq(base, "uv");
    const int is_brew = eq(base, "brew");
    const int is_gem = eq(base, "gem");
    const int is_composer = eq(base, "composer");
    const int is_ctr = eq(base, "docker") || eq(base, "podman");
    if (!is_snap && !is_pacman && !is_aur && !is_apt && !is_dpkg && !is_ls && !is_readlink &&
        !is_realpath && !is_test && !is_dnf && !is_zypper && !is_flatpak && !is_npm && !is_pnpm &&
        !is_bun && !is_pipx && !is_pip && !is_uv && !is_brew && !is_gem && !is_composer && !is_ctr) {
        return 0;
    }

    if (is_test) return test_query_ok(tok, n);
    if (is_ls) return ls_query_ok(tok, n);

    if (is_realpath) {
        int has_path = 0;
        for (int i = 1; i < n; i++) {
            if (tok[i][0] == '-') return 0;
            if (has_path) return 0;
            has_path = 1;
        }
        return has_path;
    }

    if (is_readlink) {
        int has_path = 0;
        for (int i = 1; i < n; i++) {
            const char *t = tok[i];
            if (t[0] == '-') {
                if (!eq(t, "-f") && !eq(t, "-n")) return 0;
            } else {
                has_path = 1;
            }
        }
        return has_path;
    }

    if (strstr(cmdline, "system prune") || strstr(cmdline, "snap remove")) return 0;

    int has_s = 0, has_autoremove = 0, has_list = 0, has_Q = 0;
    int has_repoquery = 0, has_unneeded = 0, has_packages = 0;
    int has_uninstall = 0, has_unused = 0;
    int has_g = 0, has_outdated = 0, has_pm = 0, has_tool = 0, has_json = 0;
    int has_upgradable = 0, has_upgrades = 0, has_check_update = 0, has_list_updates = 0;
    int has_user = 0, has_format_json = 0, has_dpkg_list = 0;
    int has_remote_ls = 0, has_app = 0, has_updates_flag = 0;
    for (int i = 1; i < n; i++) {
        const char *t = tok[i];
        if (is_flatpak && (eq(t, "uninstall") || eq(t, "remove"))) {
            has_uninstall = 1;
            continue;
        }
        if (is_brew && (eq(t, "--greedy") || eq(t, "--greedy-latest") ||
                        eq(t, "--greedy-auto-updates"))) {
            return 0;
        }
        if (is_pip && (eq(t, "--path") || strncmp(t, "--path=", 7) == 0)) return 0;
        if (is_pip && (eq(t, "-t") || eq(t, "--target") || strncmp(t, "--target=", 9) == 0)) return 0;
        if (eq(t, "--prefix") || strncmp(t, "--prefix=", 9) == 0) return 0;
        if (eq(t, "--working-dir") || strncmp(t, "--working-dir=", 14) == 0) return 0;
        if (destructive_token(t)) return 0;
        if (config_injection_token(t)) return 0;
        if (eq(t, "-s") || eq(t, "--simulate") || eq(t, "--dry-run")) has_s = 1;
        if (eq(t, "autoremove")) has_autoremove = 1;
        if (eq(t, "list") || eq(t, "ls")) has_list = 1;
        if (t[0] == '-' && t[1] == 'Q') has_Q = 1;
        if (eq(t, "repoquery")) has_repoquery = 1;
        if (eq(t, "--unneeded")) has_unneeded = 1;
        if (eq(t, "packages")) has_packages = 1;
        if (eq(t, "--unused")) has_unused = 1;
        if (eq(t, "-g") || eq(t, "--global") || eq(t, "global")) has_g = 1;
        if (eq(t, "outdated") || eq(t, "--outdated")) has_outdated = 1;
        if (eq(t, "--json") || strncmp(t, "--json=", 7) == 0) has_json = 1;
        if (eq(t, "pm")) has_pm = 1;
        if (eq(t, "tool")) has_tool = 1;
        if (eq(t, "--upgradable")) has_upgradable = 1;
        if (eq(t, "--upgrades")) has_upgrades = 1;
        if (eq(t, "check-update")) has_check_update = 1;
        if (eq(t, "list-updates")) has_list_updates = 1;
        if (eq(t, "--user")) has_user = 1;
        if (eq(t, "--format=json")) has_format_json = 1;
        if (eq(t, "--format") && i + 1 < n && eq(tok[i + 1], "json")) has_format_json = 1;
        if (eq(t, "-l") || eq(t, "--list")) has_dpkg_list = 1;
        if (eq(t, "remote-ls")) has_remote_ls = 1;
        if (eq(t, "--app")) has_app = 1;
        if (eq(t, "--updates")) has_updates_flag = 1;
    }

    if (is_snap) return has_list;
    if (is_pacman || is_aur) return has_Q;
    if (is_dpkg) return has_dpkg_list && n == 2;
    if (is_apt) {
        if (has_autoremove) return has_s;
        return has_list && has_upgradable;
    }
    if (is_dnf) {
        return (has_repoquery && has_unneeded) || (has_list && has_upgrades) || has_check_update;
    }
    if (is_zypper) return (has_packages && has_unneeded) || has_list_updates;
    if (is_flatpak) {
        if (has_uninstall && has_unused && has_s) return 1;
        if (has_remote_ls && has_updates_flag && has_app) return 1;
        if (has_list && has_app && !has_uninstall) return 1;
        return 0;
    }
    if (is_npm || is_pnpm) return has_g && (has_list || has_outdated);
    if (is_bun) return has_pm && has_list && has_g;
    if (is_pipx) return has_list;
    if (is_pip) return has_list && has_user && has_format_json;
    if (is_uv) return has_tool && has_list;
    if (is_brew) return has_outdated && has_json;
    if (is_gem) return has_outdated;
    if (is_composer) return has_g && has_outdated;
    if (is_ctr) return ctr_query_ok(tok, n);
    return 0;
}

static atomic_int g_host_exec_cancel;

void appattic_host_exec_request_cancel(void) {
    atomic_store(&g_host_exec_cancel, 1);
}

void appattic_host_exec_clear_cancel(void) {
    atomic_store(&g_host_exec_cancel, 0);
}

int appattic_host_exec_cancelled(void) {
    return atomic_load(&g_host_exec_cancel) != 0;
}

/* Presence, not a boolean: FLATPAK_ID is an application ID, so any non-empty
   value means flatpak, which is also what the Qt shell reads. The switches
   below get env_flag instead. */
static int env_set(const char *name) {
    const char *e = getenv(name);
    return e && e[0];
}

static int eq_ignore_case(const char *a, const char *b) {
    return a && b && strcasecmp(a, b) == 0;
}

/* A named on/off switch, read strictly. Only the spellings below are on, so
   APPATTIC_HOST_EXEC_LIVE=false and APPATTIC_HOST_EXEC_FIXTURE=0 leave the
   switch off, which is the only safe direction for the variable that chooses
   between canned fixtures and a live execvp. Any other value is reported and
   read as off rather than guessed at. */
static int env_flag(const char *name) {
    static const char *const kFlags[] = {
        "APPATTIC_HOST_EXEC_LIVE", "APPATTIC_HOST_EXEC_FIXTURE"};
    static int warned[sizeof kFlags / sizeof kFlags[0]];
    static pthread_mutex_t warned_lock = PTHREAD_MUTEX_INITIALIZER;
    const char *raw = getenv(name);
    if (!raw) return 0;
    while (*raw == ' ' || *raw == '\t') raw++;
    size_t len = strlen(raw);
    while (len > 0 && (raw[len - 1] == ' ' || raw[len - 1] == '\t')) len--;
    if (len == 0) return 0;
    char buf[16];
    if (len < sizeof buf) {
        memcpy(buf, raw, len);
        buf[len] = '\0';
        if (eq_ignore_case(buf, "0") || eq_ignore_case(buf, "false") ||
            eq_ignore_case(buf, "no") || eq_ignore_case(buf, "off"))
            return 0;
        if (eq_ignore_case(buf, "1") || eq_ignore_case(buf, "true") ||
            eq_ignore_case(buf, "yes") || eq_ignore_case(buf, "on"))
            return 1;
    }
    int report = 0;
    pthread_mutex_lock(&warned_lock);
    for (size_t i = 0; i < sizeof kFlags / sizeof kFlags[0]; i++) {
        if (eq(kFlags[i], name) && !warned[i]) {
            warned[i] = 1;
            report = 1;
            break;
        }
    }
    pthread_mutex_unlock(&warned_lock);
    if (report)
        fprintf(stderr,
                "appattic: %s=\"%s\" is not a boolean; use 1, true, yes, or on "
                "(0, false, no, and off are off). Reading it as 0.\n",
                name, raw);
    return 0;
}

int appattic_host_in_flatpak(void) {
    return env_set("FLATPAK_ID");
}

#define USER_PATH_CAP 8192
static int g_user_path_applied = 0;
static char g_user_path[USER_PATH_CAP];
/* PATH as it was before apply, so the effect has an inverse. */
static char g_user_path_prev[USER_PATH_CAP];
static int g_user_path_prev_valid = 0;
/* The apply/restore pair is process-global state, and the UI calls it from the
   thread that starts a scan while a running scan restores it on the thread
   that ran it. The statics above and the setenv they drive need one owner. */
static pthread_mutex_t g_user_path_lock = PTHREAD_MUTEX_INITIALIZER;

static int dir_ok(const char *p) {
    struct stat st;
    return p && p[0] && stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int path_has_dir(const char *path, const char *dir) {
    const size_t n = strlen(dir);
    const char *p = path;
    while (p && *p) {
        const char *colon = strchr(p, ':');
        const size_t m = colon ? (size_t)(colon - p) : strlen(p);
        if (m == n && strncmp(p, dir, n) == 0) return 1;
        p = colon ? colon + 1 : NULL;
    }
    return 0;
}

static void path_prepend_dir(char *dst, size_t cap, const char *dir) {
    char tmp[USER_PATH_CAP];
    if (!dir_ok(dir) || path_has_dir(dst, dir)) return;
    if (dst[0] == '\0') {
        (void)snprintf(dst, cap, "%s", dir);
        return;
    }
    if (snprintf(tmp, sizeof tmp, "%s:%s", dir, dst) >= (int)sizeof tmp) return;
    (void)snprintf(dst, cap, "%s", tmp);
}

static void path_prepend_nvm(char *dst, size_t cap, const char *home) {
    char root[PATH_MAX];
    if (snprintf(root, sizeof root, "%s/.nvm/versions/node", home) >= (int)sizeof root) {
        return;
    }
    DIR *d = opendir(root);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        char bin[PATH_MAX];
        if (e->d_name[0] == '.') continue;
        if (snprintf(bin, sizeof bin, "%s/%s/bin", root, e->d_name) >= (int)sizeof bin) {
            continue;
        }
        path_prepend_dir(dst, cap, bin);
    }
    (void)closedir(d);
}

/* The body of the apply/restore pair. Callers either hold g_user_path_lock or
   are a forked child, where no other thread exists and the inherited
   g_user_path_lock may have been held at fork time. */
static void apply_user_path_locked(void) {
    const char *home;
    const char *old;
    static const char *const rel[] = {
        "/.local/bin",
        "/bin",
        "/.bun/bin",
        "/.deno/bin",
        "/.volta/bin",
        "/.yarn/bin",
        "/.cargo/bin",
        "/.fnm/aliases/default/bin",
        "/.local/share/pnpm",
        "/.npm-global/bin",
        NULL,
    };
    int i;
    if (g_user_path_applied) return;
    g_user_path_applied = 1;
    old = getenv("PATH");
    if (!old || !old[0]) old = "/usr/bin:/bin";
    (void)snprintf(g_user_path, sizeof g_user_path, "%s", old);
    g_user_path_prev_valid =
        snprintf(g_user_path_prev, sizeof g_user_path_prev, "%s", old) < (int)sizeof g_user_path_prev;
    home = getenv("HOME");
    if (home && home[0]) {
        path_prepend_nvm(g_user_path, sizeof g_user_path, home);
        for (i = 0; rel[i]; i++) {
            char dir[PATH_MAX];
            if (snprintf(dir, sizeof dir, "%s%s", home, rel[i]) >= (int)sizeof dir) {
                continue;
            }
            path_prepend_dir(g_user_path, sizeof g_user_path, dir);
        }
    }
    if (env_set("FLATPAK_ID")) {
        static const char *const host_dirs[] = {
            "/run/host/usr/bin",
            "/run/host/usr/local/bin",
            "/run/host/usr/sbin",
            "/run/host/bin",
            NULL,
        };
        for (i = 0; host_dirs[i]; i++) {
            path_prepend_dir(g_user_path, sizeof g_user_path, host_dirs[i]);
        }
    }
    (void)setenv("PATH", g_user_path, 1);
}

void appattic_host_apply_user_path(void) {
    pthread_mutex_lock(&g_user_path_lock);
    apply_user_path_locked();
    pthread_mutex_unlock(&g_user_path_lock);
}

static void restore_user_path_locked(void) {
    if (!g_user_path_applied) return;
    g_user_path_applied = 0;
    if (!g_user_path_prev_valid) return;
    g_user_path_prev_valid = 0;
    (void)setenv("PATH", g_user_path_prev, 1);
}

void appattic_host_restore_user_path(void) {
    pthread_mutex_lock(&g_user_path_lock);
    restore_user_path_locked();
    pthread_mutex_unlock(&g_user_path_lock);
}

/* The XDG roots the WASM path plugins name as `/home/user/<rel>`. A run that
   exports one of these variables scans a different directory than the default
   root, which is what the Swift scan library does, so without this the Linux
   core reported on `~/.config` while the CLI reported on `$XDG_CONFIG_HOME`.
   A value that is empty or relative is ignored and the default root stands,
   as the XDG Base Directory specification says and as `Sources/AppAtticScan/
   Paths.swift` does. Surrounding blanks are trimmed before the absolute check,
   because both other readers do: a `XDG_CONFIG_HOME` that arrives padded is
   one directory for the CLI and another for this host, and the report the
   window prints names the one this host did not scan. */
static const char *xdg_root_for(const char *arg, size_t *rel_len) {
    static const struct {
        const char *rel;
        const char *env;
    } kRoots[] = {
        {"/.local/share", "XDG_DATA_HOME"},
        {"/.local/state", "XDG_STATE_HOME"},
        {"/.config", "XDG_CONFIG_HOME"},
        {"/.cache", "XDG_CACHE_HOME"},
    };
    /* One buffer per root, and only ever read after fork(), from
       rewrite_home_user_argv, so a single owner is enough. */
    static char trimmed[sizeof kRoots / sizeof kRoots[0]][PATH_MAX];
    size_t i;
    if (strncmp(arg, APPATTIC_HOME_SENTINEL, APPATTIC_HOME_SENTINEL_LEN) != 0) return NULL;
    for (i = 0; i < sizeof kRoots / sizeof kRoots[0]; i++) {
        const size_t n = strlen(kRoots[i].rel);
        const char *v;
        size_t len;
        if (strncmp(arg + APPATTIC_HOME_SENTINEL_LEN, kRoots[i].rel, n) != 0) continue;
        if (arg[APPATTIC_HOME_SENTINEL_LEN + n] != '\0' &&
            arg[APPATTIC_HOME_SENTINEL_LEN + n] != '/') continue;
        v = getenv(kRoots[i].env);
        if (!v) continue;
        while (*v == ' ' || *v == '\t') v++;
        len = strlen(v);
        while (len > 0 && (v[len - 1] == ' ' || v[len - 1] == '\t')) len--;
        if (len == 0 || len >= PATH_MAX) continue;
        memcpy(trimmed[i], v, len);
        trimmed[i][len] = '\0';
        if (trimmed[i][0] != '/') continue;
        /* Trailing separators are dropped, as `ui/linux-qt/finding.cpp` drops
           them: the rest of the argument starts with one, so a root that ends
           in one would double it, and with `XDG_CONFIG_HOME=/` the argv would
           begin `//`, which POSIX leaves implementation-defined. The root
           itself is a single `/`, which is not a separator to drop. */
        while (len > 1 && trimmed[i][len - 1] == '/') trimmed[i][--len] = '\0';
        *rel_len = n;
        return trimmed[i];
    }
    return NULL;
}

static void rewrite_home_user_argv(char **argv) {
    static char storage[MAX_TOK][PATH_MAX];
    const char *home = getenv("HOME");
    int slot = 0;
    int i;
    for (i = 0; argv[i] != NULL && slot < MAX_TOK; i++) {
        const char *a = argv[i];
        const char *rest;
        size_t rel_len = 0;
        const char *xdg = xdg_root_for(a, &rel_len);
        if (xdg) {
            if (snprintf(storage[slot], PATH_MAX, "%s%s", xdg,
                         a + APPATTIC_HOME_SENTINEL_LEN + rel_len) >= PATH_MAX) continue;
            argv[i] = storage[slot];
            slot++;
            continue;
        }
        if (!home || !home[0]) continue;
        if (strncmp(a, APPATTIC_HOME_SENTINEL, APPATTIC_HOME_SENTINEL_LEN) != 0) continue;
        rest = a + APPATTIC_HOME_SENTINEL_LEN;
        if (rest[0] != '\0' && rest[0] != '/') continue;
        if (snprintf(storage[slot], PATH_MAX, "%s%s", home, rest) >= PATH_MAX) continue;
        argv[i] = storage[slot];
        slot++;
    }
}

static int use_fixture(void) {
    if (env_flag("APPATTIC_HOST_EXEC_LIVE")) return 0;
#ifdef __APPLE__
    return 1;
#else
    return env_flag("APPATTIC_HOST_EXEC_FIXTURE");
#endif
}

static const char FIXTURE_APT[] =
    "Reading package lists... Done\n"
    "The following packages will be REMOVED:\n"
    "  libfoo0 libbar1\n"
    "0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\n"
    "Remv libfoo0 [1.2.3]\n"
    "Remv libbar1 [2.0.0]\n";

static const char FIXTURE_APT_UPGRADABLE[] =
    "Listing...\n"
    "git/stable 1:2.39.5-0+deb12u2 amd64 [upgradable from: 1:2.39.2-1.1]\n"
    "code/stable 1.90.2-1718 amd64 [upgradable from: 1.90.0-1600]\n";

static const char FIXTURE_DPKG[] =
    "Desired=Unknown/Install/Remove/Purge/Hold\n"
    "| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend\n"
    "|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)\n"
    "||/ Name           Version      Architecture Description\n"
    "+++-==============-============-============-=================================\n"
    "ii  bash           5.2.15-2     amd64        GNU Bourne Again SHell\n"
    "rc  oldpkg         1.0-1        amd64        leftover config\n"
    "rc  gone-lib       2.2-3        amd64        unused leftover\n";

static const char FIXTURE_APT_SOURCES[] =
    "google-chrome.list\n"
    "deadsnakes-ubuntu-ppa-noble.list\n"
    "nodesource.list\n"
    "ubuntu.sources\n";

static const char FIXTURE_PACMAN[] =
    "libfoo 1.2.3-1\n"
    "libbar 2.0.0-1\n";

static const char FIXTURE_PACMAN_OUTDATED[] =
    "coreutils 9.5-1 -> 9.5-2\n"
    "firefox 129.0-1 -> 129.0.1-1\n";

static const char FIXTURE_SNAP[] =
    "Name     Version                     Rev    Tracking         Publisher     Notes\n"
    "bare     1.0                         5      latest/stable    canonical**   base\n"
    "core22   20240111                    1122   latest/stable    canonical*    base\n"
    "core22   20231123                    1033   latest/stable    canonical*    disabled\n"
    "chromium 120.0.6099.224              1846   latest/stable    canonical**   disabled\n"
    "core20   20230622                    1974   latest/stable    canonical**   base,disabled\n"
    "firefox  129.0                       4336   latest/stable    mozilla**     -\n";

static const char FIXTURE_LS[] =
    "gone-app\n"
    "orphan-cfg\n"
    "dconf\n";

static const char FIXTURE_LS_USER_BIN[] =
    "gone-app\n"
    "dconf\n"
    "herdr\n"
    "herdr-link\n"
    "python3\n";

static const char FIXTURE_LS_USR_BIN[] =
    "python3\n";

static const char FIXTURE_LS_USER_HOME_BIN[] = "";

static const char FIXTURE_LS_SNAP[] =
    "gone-app\n"
    "chromium\n"
    "firefox\n"
    "bare\n";

static const char FIXTURE_LS_DOT[] =
    ".mozilla\n"
    ".wine\n"
    "dconf\n";

static const char FIXTURE_DNF[] =
    "Last metadata expiration check: 1:23:45 ago on Wed 26 Aug 2026.\n"
    "libfoo\n"
    "python3-bar\n";

static const char FIXTURE_DNF_UPGRADES[] =
    "Last metadata expiration check: 0:12:00 ago on Tue 25 Aug 2026.\n"
    "Available Upgrades\n"
    "git.x86_64                    2.45.1-1.fc40           updates\n"
    "firefox.x86_64                129.0-1.fc40            updates\n";

static const char FIXTURE_ZYPPER[] =
    "S | Name   | Type    | Version | Arch   | Repository\n"
    "--+--------+---------+---------+--------+-----------\n"
    "i | libfoo | package | 1.2.3-1 | x86_64 | repo\n"
    "i | libbar | package | 2.0.0-1 | x86_64 | repo\n";

static const char FIXTURE_ZYPPER_UPDATES[] =
    "Loading repository data...\n"
    "S | Repository | Name | Current Version | Available Version | Arch\n"
    "--+------------+------+-----------------+-------------------+-------\n"
    "v | Update     | git  | 2.43.0-1.1      | 2.45.1-1.1        | x86_64\n"
    "v | OSS        | vim  | 9.1-1           | 9.1-2             | x86_64\n";

static const char FIXTURE_FLATPAK[] =
    "Looking for unused runtimes to uninstall...\n"
    "\n"
    "        ID                                             Branch    Op\n"
    " 1.     org.freedesktop.Platform.GL.default            23.08     r\n"
    " 2.     org.freedesktop.Platform.Locale                23.08     r\n";

static const char FIXTURE_FLATPAK_UPDATES[] =
    "Application\tVersion\n"
    "org.mozilla.firefox\t130.0\n";

static const char FIXTURE_FLATPAK_LIST[] =
    "Application\tVersion\n"
    "org.mozilla.firefox\t128.0\n"
    "org.gnome.Calculator\t46.0\n";

static const char FIXTURE_NPM[] =
    "{\"name\":\"lib\",\"dependencies\":{\"typescript\":{\"version\":\"5.4.5\"},"
    "\"prettier\":{\"version\":\"3.3.0\"}}}\n";

static const char FIXTURE_NPM_OUTDATED[] =
    "{\"typescript\":{\"current\":\"5.4.5\",\"wanted\":\"5.5.0\",\"latest\":\"5.5.0\"}}\n";

static const char FIXTURE_PNPM[] =
    "{\"dependencies\":{\"nx\":{\"version\":\"19.0.0\"}}}\n";

static const char FIXTURE_BUN[] =
    "/home/user/.bun/install/global/node_modules\n"
    "├── typescript@5.4.5\n"
    "└── prettier@3.3.0\n";

static const char FIXTURE_PIPX[] =
    "{\"venvs\":{\"httpie\":{\"metadata\":{\"main_package\":"
    "{\"package\":\"httpie\",\"package_version\":\"3.2.2\"}}}}}\n";

static const char FIXTURE_PIP[] =
    "[{\"name\":\"requests\",\"version\":\"2.28.1\",\"latest_version\":\"2.32.3\","
    "\"latest_filetype\":\"wheel\"},"
    "{\"name\":\"urllib3\",\"version\":\"1.26.18\",\"latest_version\":\"2.2.2\"}]\n";

static const char FIXTURE_PIP_LIST[] =
    "[{\"name\":\"httpie\",\"version\":\"3.2.2\"},"
    "{\"name\":\"requests\",\"version\":\"2.28.1\"}]\n";

static const char FIXTURE_PIP_NOT_REQUIRED[] =
    "[{\"name\":\"httpie\",\"version\":\"3.2.2\"}]\n";

static const char FIXTURE_LS_DENO[] =
    "deno\n"
    "file_server\n"
    "deployctl\n";

static const char FIXTURE_UV[] =
    "ruff v0.6.8\n"
    "- ruff\n"
    "httpie v3.2.2\n"
    "- http\n";

static const char FIXTURE_BREW[] =
    "{\"formulae\":[{\"name\":\"wget\",\"installed_versions\":[\"1.21.4\"],"
    "\"current_version\":\"1.24.5\",\"pinned\":false,\"pinned_version\":null}],"
    "\"casks\":[{\"name\":\"visual-studio-code\",\"installed_versions\":[\"1.90.0\"],"
    "\"current_version\":\"1.92.1\",\"pinned\":false,\"pinned_version\":null}]}\n";

static const char FIXTURE_GEM[] =
    "*** LOCAL GEMS ***\n"
    "\n"
    "sass (3.7.4 < 3.7.5)\n"
    "nokogiri (1.16.0 < 1.16.7)\n";

static const char FIXTURE_COMPOSER[] =
    "laravel/installer 5.8.0 ! 5.10.0 Laravel application installer\n"
    "phpunit/phpunit 9.6.19 ~ 11.3.0 The PHP Unit Testing framework.\n";

static const char FIXTURE_CTR_IMAGES[] =
    "REPOSITORY   TAG       IMAGE ID       CREATED        SIZE\n"
    "<none>       <none>    a1b2c3d4e5f6   2 weeks ago    12MB\n"
    "<none>       <none>    b9e8d7c6b5a4   3 months ago   8MB\n";

static const char FIXTURE_CTR_VOLUME[] =
    "DRIVER    VOLUME NAME\n"
    "local     orphvol\n"
    "local     leftover_data\n";

static const char FIXTURE_CTR_PS[] =
    "CONTAINER ID   IMAGE     COMMAND   CREATED        STATUS                      PORTS     NAMES\n"
    "c0ffee123456   nginx     nginx     3 weeks ago    Exited (0) 3 weeks ago                web\n"
    "deadbeef0001   alpine    sh        2 months ago   Exited (1) 2 months ago               oldjob\n";

/* Canned test -e/-f/-h/-L for path-user-bin dangling symlink fixtures. */
static int test_fixture_ok(const char *cmdline) {
    char buf[MAX_CMD];
    char *tok[MAX_TOK];
    int n = parse_argv(cmdline, buf, sizeof buf, tok, MAX_TOK);
    if (n < 2) return 0;
    const char *path = tok[n - 1];
    int want_symlink = 0;
    int want_exists = 0;
    int want_file = 0;
    for (int i = 1; i < n - 1; i++) {
        const char *t = tok[i];
        if (eq(t, "-h") || eq(t, "-L")) want_symlink = 1;
        else if (eq(t, "-e")) want_exists = 1;
        else if (eq(t, "-f")) want_file = 1;
        else return 0;
    }
    const int is_gone = strstr(path, "gone-app") != NULL;
    const int is_link = strstr(path, "herdr-link") != NULL;
    const int is_regular =
        strstr(path, "dconf") != NULL ||
        (strstr(path, "herdr") != NULL && strstr(path, "herdr-link") == NULL) ||
        strstr(path, "python3") != NULL;
    if (want_symlink) {
        if (is_gone || is_link) return 1;
        return 0;
    }
    if (want_file) {
        if (is_regular) return 1;
        return 0;
    }
    if (want_exists) {
        if (is_link) return 1;
        return 0;
    }
    return 0;
}

/* Writes a synthesized result into `scratch` and points `*out` at it, so the
 * buffer is on the caller's frame: a static one would be shared by every
 * thread that reaches the fixture path. */
static int fixture_for(const char *cmdline, char *scratch, size_t scratchn, const char **out) {
    char buf[MAX_CMD];
    char *tok[MAX_TOK];
    int n = parse_argv(cmdline, buf, sizeof buf, tok, MAX_TOK);
    if (n < 1) return 0;
    *out = NULL;
    const char *base = base_of(tok[0]);
    if (eq(base, "realpath") || eq(base, "readlink")) {
        const char *path = tok[n - 1];
        if (!path || !path[0] || path[0] == '-') return 0;
        snprintf(scratch, scratchn, "%s\n", path);
        *out = scratch;
        return 1;
    }
    if (eq(base, "apt-get") || eq(base, "apt")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "--upgradable")) { *out = FIXTURE_APT_UPGRADABLE; return 1; }
        }
        *out = FIXTURE_APT; return 1;
    }
    if (eq(base, "dpkg")) { *out = FIXTURE_DPKG; return 1; }
    if (eq(base, "paru") || eq(base, "yay") || eq(base, "pikaur")) {
        *out = FIXTURE_PACMAN_OUTDATED; return 1;
    }
    if (eq(base, "pacman")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "-Qu") || eq(tok[i], "-Qua")) { *out = FIXTURE_PACMAN_OUTDATED; return 1; }
        }
        *out = FIXTURE_PACMAN; return 1;
    }
    if (eq(base, "test")) { *out = test_fixture_ok(cmdline) ? "" : NULL; return 1; }
    if (eq(base, "ls")) {
        for (int i = 1; i < n; i++) {
            const char *t = tok[i];
            if (strstr(t, "/snap") != NULL) { *out = FIXTURE_LS_SNAP; return 1; }
            if (strstr(t, "/.deno/bin") != NULL) { *out = FIXTURE_LS_DENO; return 1; }
            if (strstr(t, "/.local/bin") != NULL) { *out = FIXTURE_LS_USER_BIN; return 1; }
            if (eq(t, APPATTIC_HOME_SENTINEL "/bin") ||
                strstr(t, APPATTIC_HOME_SENTINEL "/bin/") != NULL) {
                *out = FIXTURE_LS_USER_HOME_BIN; return 1;
            }
            if (strstr(t, "/usr/bin") != NULL) { *out = FIXTURE_LS_USR_BIN; return 1; }
            if (strstr(t, "sources.list.d") != NULL) { *out = FIXTURE_APT_SOURCES; return 1; }
            if (eq(t, "-A") || eq(t, "-a") || eq(t, "-1A") || eq(t, "-A1")) { *out = FIXTURE_LS_DOT; return 1; }
        }
        *out = FIXTURE_LS; return 1;
    }
    if (eq(base, "snap")) { *out = FIXTURE_SNAP; return 1; }
    if (eq(base, "dnf") || eq(base, "dnf5") || eq(base, "yum")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "--upgrades") || eq(tok[i], "check-update")) { *out = FIXTURE_DNF_UPGRADES; return 1; }
        }
        *out = FIXTURE_DNF; return 1;
    }
    if (eq(base, "zypper")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "list-updates")) { *out = FIXTURE_ZYPPER_UPDATES; return 1; }
        }
        *out = FIXTURE_ZYPPER; return 1;
    }
    if (eq(base, "flatpak")) {
        int has_updates = 0, has_list = 0, has_remote_ls = 0;
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "--updates") || eq(tok[i], "remote-ls")) {
                if (eq(tok[i], "remote-ls")) has_remote_ls = 1;
                else has_updates = 1;
            }
            if (eq(tok[i], "list") || eq(tok[i], "ls")) has_list = 1;
        }
        if (has_remote_ls || has_updates) { *out = FIXTURE_FLATPAK_UPDATES; return 1; }
        if (has_list) { *out = FIXTURE_FLATPAK_LIST; return 1; }
        *out = FIXTURE_FLATPAK; return 1;
    }
    if (eq(base, "pnpm")) { *out = FIXTURE_PNPM; return 1; }
    if (eq(base, "npm")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "outdated")) { *out = FIXTURE_NPM_OUTDATED; return 1; }
        }
        *out = FIXTURE_NPM; return 1;
    }
    if (eq(base, "bun")) { *out = FIXTURE_BUN; return 1; }
    if (eq(base, "pipx")) { *out = FIXTURE_PIPX; return 1; }
    if (eq(base, "pip") || eq(base, "pip3")) {
        int has_outdated = 0, has_not_required = 0;
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "--outdated")) has_outdated = 1;
            if (eq(tok[i], "--not-required")) has_not_required = 1;
        }
        if (has_outdated) { *out = FIXTURE_PIP; return 1; }
        if (has_not_required) { *out = FIXTURE_PIP_NOT_REQUIRED; return 1; }
        *out = FIXTURE_PIP_LIST; return 1;
    }
    if (eq(base, "uv")) { *out = FIXTURE_UV; return 1; }
    if (eq(base, "brew")) { *out = FIXTURE_BREW; return 1; }
    if (eq(base, "gem")) { *out = FIXTURE_GEM; return 1; }
    if (eq(base, "composer")) { *out = FIXTURE_COMPOSER; return 1; }
    if (eq(base, "docker") || eq(base, "podman")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "volume")) { *out = FIXTURE_CTR_VOLUME; return 1; }
            if (eq(tok[i], "images")) { *out = FIXTURE_CTR_IMAGES; return 1; }
            if (eq(tok[i], "ps")) { *out = FIXTURE_CTR_PS; return 1; }
        }
        return 0;
    }
    return 0;
}

static long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    if (ts.tv_sec > LONG_MAX / 1000L - 1L) return LONG_MAX;
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void reap_child(pid_t pid) {
    if (kill(-pid, SIGTERM) != 0) {
        (void)kill(pid, SIGTERM);
    }
    int waited = 0;
    while (waited < HOST_EXEC_KILL_GRACE_MS) {
        int st = 0;
        if (waitpid(pid, &st, WNOHANG) == pid) return;
        struct timespec sl;
        sl.tv_sec = 0;
        sl.tv_nsec = (long)HOST_EXEC_REAP_POLL_MS * 1000L * 1000L;
        (void)nanosleep(&sl, NULL);
        waited += HOST_EXEC_REAP_POLL_MS;
    }
    if (kill(-pid, SIGKILL) != 0) {
        (void)kill(pid, SIGKILL);
    }
    /* Polled, not blocking. SIGKILL cannot be caught, but a child in
       uninterruptible sleep (a query on a hung FUSE, CIFS or NFS mount) does
       not reach a zombie for it, and a blocking wait there parks the calling
       thread for good: the scan thread never returns and the whole teardown in
       the shell runs behind a drain it can pass. The child is left to init to
       reap once the kernel unblocks it, which is the only thing that can. */
    int st = 0;
    waited = 0;
    while (waited < HOST_EXEC_KILL_GRACE_MS) {
        if (waitpid(pid, &st, WNOHANG) == pid) return;
        struct timespec sl;
        sl.tv_sec = 0;
        sl.tv_nsec = (long)HOST_EXEC_REAP_POLL_MS * 1000000L;
        (void)nanosleep(&sl, NULL);
        waited += HOST_EXEC_REAP_POLL_MS;
    }
}

/* A pipe whose ends carry O_CLOEXEC. Every host query forks, and the process
   that is left behind is the app's own lifetime, so an end inherited by an
   unrelated concurrent fork keeps the other end open inside a package manager
   that outlives the query that made it. pipe2 where it exists, the two fcntl
   calls where it does not. */
static int pipe_cloexec(int fds[2]) {
#ifdef O_CLOEXEC
    if (pipe2(fds, O_CLOEXEC) == 0) return 0;
    if (errno != ENOSYS) return -1;
#endif
    if (pipe(fds) != 0) return -1;
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(fds[i], F_GETFD);
        if (flags < 0 || fcntl(fds[i], F_SETFD, flags | FD_CLOEXEC) < 0) {
            int saved = errno;
            close(fds[0]);
            close(fds[1]);
            errno = saved;
            return -1;
        }
    }
    return 0;
}

/* The analyzer pass in scripts/lint.sh reads the dup2 below as a leaked
   descriptor: the child closes fds[1] and keeps the copy on STDOUT_FILENO,
   which is stdout and is meant to survive into the exec'd program. The only
   ways out of the child branch are that exec and _exit, and the parent's
   close(fds[1]) does not reach the child's descriptor table. Scoped to this
   function so an fd leak anywhere else in the file still fails the gate.
   Guarded because clang has no -Wanalyzer-fd-leak and, under the -Werror the
   compile loop also uses, rejects the pragma as an unknown warning group. */
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wanalyzer-fd-leak"
#endif
static int run_live_forked(char **argv, char *out, size_t cap) {
    int fds[2];
    if (pipe_cloexec(fds) != 0) return APPATTIC_HOST_EXEC_FAIL;
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return APPATTIC_HOST_EXEC_FAIL;
    }
    if (pid == 0) {
        static char env_path[USER_PATH_CAP + 16];
        (void)setpgid(0, 0);
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0) _exit(127);
        /* dup2 leaves the flag clear on the new descriptor, but it is a no-op
           when the pipe end already is fd 1, so the flag is cleared here for
           that case: stdout has to survive the exec below. */
        (void)fcntl(STDOUT_FILENO, F_SETFD, 0);
        close(fds[1]);
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            (void)dup2(devnull, STDIN_FILENO);
            (void)dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        /* Forked child: one thread, and g_user_path_lock may have been held by
           another thread at fork time, so the body runs without taking it. */
        apply_user_path_locked();
        rewrite_home_user_argv(argv);
        if (appattic_host_in_flatpak()) {
            char *spawn_argv[MAX_TOK + 6];
            const char *path = getenv("PATH");
            int i = 0;
            int off = 3;
            spawn_argv[0] = "flatpak-spawn";
            spawn_argv[1] = "--host";
            if (path && path[0]
                && snprintf(env_path, sizeof env_path, "--env=PATH=%s", path)
                    < (int)sizeof env_path) {
                spawn_argv[2] = env_path;
                off = 4;
            } else {
                spawn_argv[2] = "--";
            }
            if (off == 4) spawn_argv[3] = "--";
            for (; argv[i] != NULL && i < MAX_TOK; i++) {
                spawn_argv[i + off] = argv[i];
            }
            spawn_argv[i + off] = NULL;
            execvp(spawn_argv[0], spawn_argv);
        } else {
            execvp(argv[0], argv);
        }
        _exit(127);
    }
    (void)setpgid(pid, pid);
    close(fds[1]);

    long start = monotonic_ms();
    int timed_out = 0;
    size_t n = 0;
    while (n < cap) {
        if (appattic_host_exec_cancelled()) {
            timed_out = 1;
            break;
        }
        int wait_ms = HOST_EXEC_TIMEOUT_MS;
        if (start >= 0) {
            long now = monotonic_ms();
            if (now < 0 || now - start >= (long)HOST_EXEC_TIMEOUT_MS) {
                timed_out = 1;
                break;
            }
            long left = (long)HOST_EXEC_TIMEOUT_MS - (now - start);
            if (left < 1L) left = 1L;
            if (left > (long)HOST_EXEC_TIMEOUT_MS) left = (long)HOST_EXEC_TIMEOUT_MS;
            wait_ms = (int)left;
        }
        if (wait_ms > HOST_EXEC_POLL_SLICE_MS) wait_ms = HOST_EXEC_POLL_SLICE_MS;
        struct pollfd pfd;
        pfd.fd = fds[0];
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, wait_ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            close(fds[0]);
            reap_child(pid);
            return APPATTIC_HOST_EXEC_FAIL;
        }
        if (pr == 0) continue;
        ssize_t r = read(fds[0], out + n, cap - n);
        if (r < 0) {
            if (errno == EINTR) continue;
            close(fds[0]);
            reap_child(pid);
            return APPATTIC_HOST_EXEC_FAIL;
        }
        if (r == 0) break;
        n += (size_t)r;
    }
    close(fds[0]);
    if (timed_out) {
        reap_child(pid);
        return APPATTIC_HOST_EXEC_FAIL;
    }
    const int truncated = (n == cap);
    if (truncated) {
        reap_child(pid);
        return take_complete_output(out, n, 1);
    }
    int st = 0;
    int waited = 0;
    int poll_ms = HOST_EXEC_POLL_MIN_MS;
    // Every way out of this loop is a break or a return, so it runs until the
    // child is reaped rather than until a flag says so.
    for (;;) {
        pid_t wr = waitpid(pid, &st, WNOHANG);
        if (wr == pid) break;
        if (wr < 0) {
            if (errno == EINTR) continue;
            reap_child(pid);
            return APPATTIC_HOST_EXEC_FAIL;
        }
        if (start >= 0) {
            long now = monotonic_ms();
            if (now < 0 || now - start >= (long)HOST_EXEC_TIMEOUT_MS) {
                reap_child(pid);
                return APPATTIC_HOST_EXEC_FAIL;
            }
        } else if (waited >= HOST_EXEC_TIMEOUT_MS) {
            reap_child(pid);
            return APPATTIC_HOST_EXEC_FAIL;
        }
        struct timespec sl;
        sl.tv_sec = 0;
        sl.tv_nsec = (long)poll_ms * 1000L * 1000L;
        (void)nanosleep(&sl, NULL);
        waited += poll_ms;
        if (poll_ms < HOST_EXEC_POLL_MAX_MS) poll_ms *= 2;
    }
    if (WIFEXITED(st) && WEXITSTATUS(st) == 127) return APPATTIC_HOST_EXEC_FAIL;
    if (eq(base_of(argv[0]), "test") && WIFEXITED(st) && WEXITSTATUS(st) != 0) {
        return APPATTIC_HOST_EXEC_FAIL;
    }
    return (int)n;
}
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif

/* Apply the user PATH, fork, and undo the apply if this call is what armed
   it. The child needs the rewrite in its environment, but computing it is not
   fork-safe work: opendir, readdir, stat, snprintf and setenv all take the
   malloc arena lock, and this host forks from a scan thread in a process
   whose other threads are running. A child that reaches for the arena while
   another thread held it at fork time never comes back, and the scan hangs on
   a query that will never answer. Building it here, on a thread that is
   allowed to allocate, and letting the child inherit the finished PATH across
   the fork removes that entirely; the child still calls
   apply_user_path_locked, where it is a no-op for exactly this reason.

   Whether this call armed the rewrite is read under the same lock that armed
   it, so two threads racing here cannot both claim the inverse: the embedder
   that applied PATH before the scan (runCoreWasm, taggedPluginSpecs) owns the
   undo, and an embedder that never applied does not keep the scan's PATH
   after the scan ends. */
static int run_live(char **argv, char *out, size_t cap) {
    pthread_mutex_lock(&g_user_path_lock);
    const int applied_here = !g_user_path_applied;
    apply_user_path_locked();
    pthread_mutex_unlock(&g_user_path_lock);
    const int rc = run_live_forked(argv, out, cap);
    if (applied_here) appattic_host_restore_user_path();
    return rc;
}

int appattic_host_exec(const char *cmdline, char *out, size_t cap) {
    if (!out || cap == 0) return APPATTIC_HOST_EXEC_BAD;
    if (!appattic_host_exec_allowed(cmdline)) return APPATTIC_HOST_EXEC_DENY;

    if (use_fixture()) {
        char scratch[MAX_CMD];
        const char *text = NULL;
        if (!fixture_for(cmdline, scratch, sizeof scratch, &text) || !text) {
            return APPATTIC_HOST_EXEC_FAIL;
        }
        size_t n = strlen(text);
        if (n <= cap) {
            memcpy(out, text, n);
            return (int)n;
        }
        memcpy(out, text, cap);
        return take_complete_output(out, cap, 1);
    }

    char buf[MAX_CMD];
    char *argv[MAX_TOK + 1];
    int argc = parse_argv(cmdline, buf, sizeof buf, argv, MAX_TOK);
    if (argc < 1) return APPATTIC_HOST_EXEC_DENY;
    argv[argc] = NULL;
    /* GNU `readlink -f` is POSIX realpath; BSD readlink has no -f. */
    if (eq(base_of(argv[0]), "readlink")) {
        int has_f = 0;
        char *path = NULL;
        for (int i = 1; i < argc; i++) {
            if (eq(argv[i], "-f")) has_f = 1;
            else if (argv[i][0] != '-') path = argv[i];
        }
        if (has_f && path) {
            argv[0] = "realpath";
            argv[1] = path;
            argv[2] = NULL;
        }
    }
    return run_live(argv, out, cap);
}
