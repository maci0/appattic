#include "embed.h"

#include <stdio.h>
#include <string.h>

static void print_json(const char *json, size_t len, void *user) {
    (void)user;
    fwrite(json, 1, len, stdout);
    fputc('\n', stdout);
}

static void print_usage(FILE *fp, const char *argv0) {
    fprintf(fp, "usage: %s <core.wasm> <plugin.wasm[=tag]>...\n", argv0);
    fprintf(fp, "       %s --precompile <module.wasm>...   (writes <module>.wasm.cwasm)\n", argv0);
    fprintf(fp, "tag 0 = missing coeffect; default 1. container-runtime: 1 docker, 2 podman.\n");
    fprintf(fp, "not loaded: chocolatey nuget appstore steam (backlog)\n");
    fprintf(fp, "host.exec allow: snap pacman -Q* apt-get -s autoremove apt list --upgradable dnf repoquery/--upgrades/check-update zypper packages --unneeded/list-updates flatpak npm pnpm bun pipx pip/pip3 --user outdated uv brew gem composer docker ls. Darwin fixtures.\n");
}

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        print_usage(stdout, argv[0]);
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--precompile") == 0) {
        if (argc < 3) {
            fprintf(stderr, "usage: %s --precompile <module.wasm>...\n", argv[0]);
            return 2;
        }
        char err[1024];
        int rc = 0;
        for (int i = 2; i < argc; i++) {
            char out[4096];
            if (snprintf(out, sizeof out, "%s.cwasm", argv[i]) >= (int)sizeof out) {
                fprintf(stderr, "precompile: path too long: %s\n", argv[i]);
                rc = 1;
                continue;
            }
            err[0] = '\0';
            if (appattic_precompile(argv[i], out, err, sizeof err) != 0) {
                fprintf(stderr, "precompile %s: %s\n", argv[i], err);
                rc = 1;
            }
        }
        return rc;
    }
    if (argc < 3) {
        print_usage(stderr, argv[0]);
        return 2;
    }
    char err[1024];
    err[0] = '\0';
    int rc = appattic_wasm_run(
        argv[1], argv + 2, argc - 2, print_json, NULL, NULL, err, sizeof err
    );
    if (rc != 0 && err[0]) fprintf(stderr, "%s\n", err);
    return rc;
}
