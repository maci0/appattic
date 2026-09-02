#include "hostexec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

#define MAX_CMD 512
#define MAX_TOK 16
#define HOST_EXEC_TIMEOUT_MS 60000
#define HOST_EXEC_KILL_GRACE_MS 1000

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

/* docker/podman query shapes only: images -f dangling=true, volume ls -f dangling=true,
   ps -a -f status=exited. Never rmi, rm, prune, system. */
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

static int parse_argv(const char *cmdline, char *buf, size_t bufn, char **argv, int maxn) {
    if (!cmdline || !cmdline[0] || strlen(cmdline) >= bufn) return -1;
    if (strpbrk(cmdline, ";|&`$<>\n\r()")) return -1;
    snprintf(buf, bufn, "%s", cmdline);
    int n = 0;
    for (char *p = strtok(buf, " \t"); p && n < maxn; p = strtok(NULL, " \t")) {
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
    const int is_apt = eq(base, "apt-get") || eq(base, "apt");
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
    if (!is_snap && !is_pacman && !is_apt && !is_ls && !is_readlink && !is_realpath && !is_test &&
        !is_dnf && !is_zypper && !is_flatpak && !is_npm && !is_pnpm && !is_bun && !is_pipx &&
        !is_pip && !is_uv && !is_brew && !is_gem && !is_composer && !is_ctr) {
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
    int has_user = 0, has_format_json = 0;
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
    }

    if (is_snap) return has_list;
    if (is_pacman) return has_Q;
    if (is_apt) {
        if (has_autoremove) return has_s;
        return has_list && has_upgradable;
    }
    if (is_dnf) {
        return (has_repoquery && has_unneeded) || (has_list && has_upgrades) || has_check_update;
    }
    if (is_zypper) return (has_packages && has_unneeded) || has_list_updates;
    if (is_flatpak) return has_uninstall && has_unused && has_s;
    if (is_npm || is_pnpm) return has_g && (has_list || has_outdated);
    if (is_bun) return has_pm && has_list && has_g;
    if (is_pipx) return has_list;
    if (is_pip) return has_list && has_user && has_outdated && has_format_json;
    if (is_uv) return has_tool && has_list;
    if (is_brew) return has_outdated && has_json;
    if (is_gem) return has_outdated;
    if (is_composer) return has_g && has_outdated;
    if (is_ctr) return ctr_query_ok(tok, n);
    return 0;
}

static int env_truthy(const char *name) {
    const char *e = getenv(name);
    return e && e[0] && strcmp(e, "0") != 0;
}

static int use_fixture(void) {
    if (env_truthy("APPATTIC_HOST_EXEC_LIVE")) return 0;
#ifdef __APPLE__
    return 1;
#else
    return env_truthy("APPATTIC_HOST_EXEC_FIXTURE");
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

static char canon_fixture[MAX_CMD];

static const char *fixture_for(const char *cmdline) {
    char buf[MAX_CMD];
    char *tok[MAX_TOK];
    int n = parse_argv(cmdline, buf, sizeof buf, tok, MAX_TOK);
    if (n < 1) return NULL;
    const char *base = base_of(tok[0]);
    if (eq(base, "realpath") || eq(base, "readlink")) {
        const char *path = tok[n - 1];
        if (!path || !path[0] || path[0] == '-') return NULL;
        snprintf(canon_fixture, sizeof canon_fixture, "%s\n", path);
        return canon_fixture;
    }
    if (eq(base, "apt-get") || eq(base, "apt")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "--upgradable")) return FIXTURE_APT_UPGRADABLE;
        }
        return FIXTURE_APT;
    }
    if (eq(base, "pacman")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "-Qu")) return FIXTURE_PACMAN_OUTDATED;
        }
        return FIXTURE_PACMAN;
    }
    if (eq(base, "test")) return test_fixture_ok(cmdline) ? "" : NULL;
    if (eq(base, "readlink")) {
        for (int i = 1; i < n; i++) {
            const char *t = tok[i];
            if (t[0] == '-') continue;
            if (strstr(t, "/.local/bin/python3") != NULL) return "/home/user/.local/bin/python3";
            if (strstr(t, "/usr/bin/python3") != NULL) return "/usr/bin/python3";
        }
        return NULL;
    }
    if (eq(base, "ls")) {
        for (int i = 1; i < n; i++) {
            const char *t = tok[i];
            if (strstr(t, "/snap") != NULL) return FIXTURE_LS_SNAP;
            if (strstr(t, "/.local/bin") != NULL) return FIXTURE_LS_USER_BIN;
            if (eq(t, "/home/user/bin") || strstr(t, "/home/user/bin/") != NULL) {
                return FIXTURE_LS_USER_HOME_BIN;
            }
            if (strstr(t, "/usr/bin") != NULL) return FIXTURE_LS_USR_BIN;
            if (eq(t, "-A") || eq(t, "-a") || eq(t, "-1A") || eq(t, "-A1")) return FIXTURE_LS_DOT;
        }
        return FIXTURE_LS;
    }
    if (eq(base, "snap")) return FIXTURE_SNAP;
    if (eq(base, "dnf") || eq(base, "dnf5") || eq(base, "yum")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "--upgrades") || eq(tok[i], "check-update")) return FIXTURE_DNF_UPGRADES;
        }
        return FIXTURE_DNF;
    }
    if (eq(base, "zypper")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "list-updates")) return FIXTURE_ZYPPER_UPDATES;
        }
        return FIXTURE_ZYPPER;
    }
    if (eq(base, "flatpak")) return FIXTURE_FLATPAK;
    if (eq(base, "pnpm")) return FIXTURE_PNPM;
    if (eq(base, "npm")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "outdated")) return FIXTURE_NPM_OUTDATED;
        }
        return FIXTURE_NPM;
    }
    if (eq(base, "bun")) return FIXTURE_BUN;
    if (eq(base, "pipx")) return FIXTURE_PIPX;
    if (eq(base, "pip") || eq(base, "pip3")) return FIXTURE_PIP;
    if (eq(base, "uv")) return FIXTURE_UV;
    if (eq(base, "brew")) return FIXTURE_BREW;
    if (eq(base, "gem")) return FIXTURE_GEM;
    if (eq(base, "composer")) return FIXTURE_COMPOSER;
    if (eq(base, "docker") || eq(base, "podman")) {
        for (int i = 1; i < n; i++) {
            if (eq(tok[i], "volume")) return FIXTURE_CTR_VOLUME;
            if (eq(tok[i], "images")) return FIXTURE_CTR_IMAGES;
            if (eq(tok[i], "ps")) return FIXTURE_CTR_PS;
        }
        return NULL;
    }
    return NULL;
}

#ifndef _WIN32
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
        sl.tv_nsec = 50L * 1000L * 1000L;
        (void)nanosleep(&sl, NULL);
        waited += 50;
    }
    if (kill(-pid, SIGKILL) != 0) {
        (void)kill(pid, SIGKILL);
    }
    int st = 0;
    (void)waitpid(pid, &st, 0);
}

static int run_live(char **argv, char *out, size_t cap) {
    int fds[2];
    if (pipe(fds) != 0) return APPATTIC_HOST_EXEC_FAIL;
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return APPATTIC_HOST_EXEC_FAIL;
    }
    if (pid == 0) {
        (void)setpgid(0, 0);
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0) _exit(127);
        close(fds[1]);
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            (void)dup2(devnull, STDIN_FILENO);
            (void)dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    (void)setpgid(pid, pid);
    close(fds[1]);

    long start = monotonic_ms();
    int timed_out = 0;
    size_t n = 0;
    while (n < cap) {
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
        if (pr == 0) {
            timed_out = 1;
            break;
        }
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
    if (timed_out || n == cap) {
        reap_child(pid);
        return timed_out ? APPATTIC_HOST_EXEC_FAIL : APPATTIC_HOST_EXEC_BAD;
    }
    int st = 0;
    int reaped = 0;
    int waited = 0;
    while (!reaped) {
        pid_t wr = waitpid(pid, &st, WNOHANG);
        if (wr == pid) {
            reaped = 1;
            break;
        }
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
        sl.tv_nsec = 50L * 1000L * 1000L;
        (void)nanosleep(&sl, NULL);
        waited += 50;
    }
    if (WIFEXITED(st) && WEXITSTATUS(st) == 127) return APPATTIC_HOST_EXEC_FAIL;
    if (eq(base_of(argv[0]), "test") && WIFEXITED(st) && WEXITSTATUS(st) != 0) {
        return APPATTIC_HOST_EXEC_FAIL;
    }
    return (int)n;
}
#endif

int appattic_host_exec(const char *cmdline, char *out, size_t cap) {
    if (!out || cap == 0) return APPATTIC_HOST_EXEC_BAD;
    if (!appattic_host_exec_allowed(cmdline)) return APPATTIC_HOST_EXEC_DENY;

    if (use_fixture()) {
        const char *text = fixture_for(cmdline);
        if (!text) return APPATTIC_HOST_EXEC_FAIL;
        size_t n = strlen(text);
        if (n > cap) return APPATTIC_HOST_EXEC_BAD;
        memcpy(out, text, n);
        return (int)n;
    }

#ifndef _WIN32
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
#else
    (void)cmdline;
    return APPATTIC_HOST_EXEC_FAIL;
#endif
}
