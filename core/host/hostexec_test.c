#include "hostexec.h"

#include <stdio.h>
#include <string.h>

static int fail(const char *msg) {
    fprintf(stderr, "hostexec_test: %s\n", msg);
    return 1;
}

static int expect_allow(const char *cmd) {
    if (!appattic_host_exec_allowed(cmd)) {
        fprintf(stderr, "hostexec_test: expected allow: %s\n", cmd);
        return 1;
    }
    return 0;
}

static int expect_deny(const char *cmd) {
    if (appattic_host_exec_allowed(cmd)) {
        fprintf(stderr, "hostexec_test: expected deny: %s\n", cmd);
        return 1;
    }
    char out[64];
    int n = appattic_host_exec(cmd, out, sizeof out);
    if (n != APPATTIC_HOST_EXEC_DENY) {
        fprintf(stderr, "hostexec_test: exec should deny %s, got %d\n", cmd, n);
        return 1;
    }
    return 0;
}

int main(void) {
    int rc = 0;
    rc |= expect_allow("apt-get -s autoremove");
    rc |= expect_allow("apt-get --simulate autoremove");
    rc |= expect_allow("apt-get --dry-run autoremove");
    rc |= expect_allow("/usr/bin/apt-get -s autoremove");
    rc |= expect_allow("apt -s autoremove");
    rc |= expect_allow("apt list --upgradable");
    rc |= expect_allow("/usr/bin/apt list --upgradable");
    rc |= expect_allow("pacman -Qdt");
    rc |= expect_allow("pacman -Qqdt");
    rc |= expect_allow("pacman -Qu");
    rc |= expect_allow("snap list --all");
    rc |= expect_allow("ls -1");
    rc |= expect_allow("ls -1A");
    rc |= expect_allow("ls -1A /home/user");
    rc |= expect_allow("ls -1 /home/user/.config");
    rc |= expect_allow("/bin/ls -1A");
    rc |= expect_allow("ls /home/user/.config");
    rc |= expect_allow("ls -1 /home/user/snap");
    rc |= expect_allow("ls -a");
    rc |= expect_allow("ls -A");
    rc |= expect_allow("ls -1 -A /home/user/.config");
    rc |= expect_allow("readlink -f /tmp/foo");
    rc |= expect_allow("readlink -n /tmp/foo");
    rc |= expect_allow("readlink /tmp/foo");
    rc |= expect_allow("/usr/bin/readlink -f /tmp/foo");
    rc |= expect_allow("realpath /tmp/foo");
    rc |= expect_allow("/usr/bin/realpath /tmp/foo");
    rc |= expect_allow("test -e /tmp/foo");
    rc |= expect_allow("test -f /tmp/foo");
    rc |= expect_allow("test -h /tmp/foo");
    rc |= expect_allow("test -L /tmp/foo");
    rc |= expect_allow("test -e -h /tmp/foo");
    rc |= expect_allow("dnf repoquery --unneeded --qf %{name}");
    rc |= expect_allow("dnf5 repoquery --unneeded --qf %{name}");
    rc |= expect_allow("/usr/bin/dnf repoquery --unneeded --qf %{name}");
    rc |= expect_allow("yum repoquery --unneeded --qf %{name}");
    rc |= expect_allow("dnf repoquery --unneeded");
    rc |= expect_allow("dnf list --upgrades");
    rc |= expect_allow("dnf5 list --upgrades");
    rc |= expect_allow("/usr/bin/dnf list --upgrades");
    rc |= expect_allow("dnf check-update");
    rc |= expect_allow("dnf5 check-update");
    rc |= expect_allow("yum check-update");
    rc |= expect_allow("zypper --non-interactive packages --unneeded");
    rc |= expect_allow("/usr/bin/zypper packages --unneeded");
    rc |= expect_allow("zypper --non-interactive list-updates");
    rc |= expect_allow("/usr/bin/zypper list-updates");
    rc |= expect_allow("flatpak uninstall --unused --dry-run");
    rc |= expect_allow("flatpak remove --unused --dry-run");
    rc |= expect_allow("/usr/bin/flatpak uninstall --unused --dry-run");
    rc |= expect_allow("flatpak uninstall --unused --simulate");
    rc |= expect_allow("npm ls -g --depth=0 --json");
    rc |= expect_allow("npm ls -g --depth=0");
    rc |= expect_allow("npm outdated -g --json");
    rc |= expect_allow("npm outdated -g");
    rc |= expect_allow("/usr/bin/npm ls -g --depth=0 --json");
    rc |= expect_allow("pnpm ls -g --depth=0 --json");
    rc |= expect_allow("pnpm ls -g");
    rc |= expect_allow("pnpm outdated -g");
    rc |= expect_allow("/usr/bin/pnpm ls -g --depth=0 --json");
    rc |= expect_allow("bun pm ls -g");
    rc |= expect_allow("bun pm ls --global");
    rc |= expect_allow("/usr/bin/bun pm ls -g");
    rc |= expect_allow("pipx list");
    rc |= expect_allow("pipx list --json");
    rc |= expect_allow("/usr/bin/pipx list --json");
    rc |= expect_allow("pip list --user --outdated --format=json");
    rc |= expect_allow("pip3 list --user --outdated --format=json");
    rc |= expect_allow("/usr/bin/pip list --user --outdated --format=json");
    rc |= expect_allow("/usr/bin/pip3 list --user --outdated --format=json");
    rc |= expect_allow("pip list --outdated --user --format=json");
    rc |= expect_allow("pip list --user --outdated --format json");
    rc |= expect_allow("uv tool list");
    rc |= expect_allow("/usr/bin/uv tool list");
    rc |= expect_allow("brew outdated --json=v2");
    rc |= expect_allow("brew outdated --json");
    rc |= expect_allow("/opt/homebrew/bin/brew outdated --json=v2");
    rc |= expect_allow("/home/linuxbrew/.linuxbrew/bin/brew outdated --json=v2");
    rc |= expect_allow("/usr/local/bin/brew outdated --json=v2");
    rc |= expect_allow("gem outdated");
    rc |= expect_allow("/usr/bin/gem outdated");
    rc |= expect_allow("composer global outdated");
    rc |= expect_allow("composer global outdated --format=json");
    rc |= expect_allow("/usr/bin/composer global outdated --format=json");
    rc |= expect_allow("docker images -f dangling=true");
    rc |= expect_allow("podman images -f dangling=true");
    rc |= expect_allow("/usr/bin/docker images -f dangling=true");
    rc |= expect_allow("docker images --filter dangling=true");
    rc |= expect_allow("docker volume ls -f dangling=true");
    rc |= expect_allow("podman volume ls -f dangling=true");
    rc |= expect_allow("/usr/bin/podman volume ls -f dangling=true");
    rc |= expect_allow("docker ps -a -f status=exited");
    rc |= expect_allow("podman ps -a -f status=exited");
    rc |= expect_allow("docker ps --all --filter status=exited");
    rc |= expect_allow("/usr/bin/docker ps -a -f status=exited");

    rc |= expect_deny("apt-get autoremove");
    rc |= expect_deny("apt-get -s autoremove -y");
    rc |= expect_deny("apt-get -s autoremove --yes");
    rc |= expect_deny("apt-get purge -y libfoo0");
    rc |= expect_deny("apt-get upgrade");
    rc |= expect_deny("apt upgrade");
    rc |= expect_deny("apt list");
    rc |= expect_deny("apt-get upgrade git");
    rc |= expect_deny("snap remove chromium --revision 1846");
    rc |= expect_deny("snap remove --purge '*'");
    rc |= expect_deny("rm -rf /usr/bin/snap");
    rc |= expect_deny("rm -rf /home/user/.config/gone-app");
    rc |= expect_deny("docker system prune -af");
    rc |= expect_deny("podman system prune");
    rc |= expect_deny("docker rmi -f");
    rc |= expect_deny("docker rmi a1b2c3d4e5f6");
    rc |= expect_deny("podman rmi -f a1b2c3d4e5f6");
    rc |= expect_deny("docker volume prune -f");
    rc |= expect_deny("podman volume prune -f");
    rc |= expect_deny("docker volume rm orphvol");
    rc |= expect_deny("docker rm c0ffee123456");
    rc |= expect_deny("docker images");
    rc |= expect_deny("docker ps -a");
    rc |= expect_deny("docker system df");
    rc |= expect_deny("podman images -f dangling=true -q");
    rc |= expect_deny("pacman -Rns libfoo");
    rc |= expect_deny("pacman -Syu");
    rc |= expect_deny("ls; rm -rf /");
    rc |= expect_deny("ls -rf");
    rc |= expect_deny("ls --force");
    rc |= expect_deny("ls -R /");
    rc |= expect_deny("ls -l");
    rc |= expect_deny("ls --recursive /home/user");
    rc |= expect_deny("ls -1 /tmp /home");
    rc |= expect_deny("readlink -m /tmp/foo");
    rc |= expect_deny("readlink -f /tmp/foo; rm -rf /");
    rc |= expect_deny("realpath -m /tmp/foo");
    rc |= expect_deny("realpath --relative-to=/ /tmp/foo");
    rc |= expect_deny("realpath /tmp/foo /tmp/bar");
    rc |= expect_deny("test -w /tmp/foo");
    rc |= expect_deny("test -x /tmp/foo");
    rc |= expect_deny("test -d /tmp/foo");
    rc |= expect_deny("test /tmp/foo");
    rc |= expect_deny("test -e /tmp/foo; rm -rf /");
    rc |= expect_deny("test -f /tmp/foo; rm -rf /");
    rc |= expect_deny("cat /tmp/foo");
    rc |= expect_deny("dnf remove -y libfoo");
    rc |= expect_deny("dnf5 remove -y libfoo");
    rc |= expect_deny("yum erase -y libfoo");
    rc |= expect_deny("dnf upgrade -y");
    rc |= expect_deny("dnf upgrade");
    rc |= expect_deny("dnf upgrade git");
    rc |= expect_deny("dnf install -y libfoo");
    rc |= expect_deny("dnf leaves");
    rc |= expect_deny("dnf list");
    rc |= expect_deny("zypper rm libfoo");
    rc |= expect_deny("zypper --non-interactive rm libfoo");
    rc |= expect_deny("zypper dup");
    rc |= expect_deny("zypper update");
    rc |= expect_deny("zypper update git");
    rc |= expect_deny("zypper --non-interactive install -y libfoo");
    rc |= expect_deny("flatpak uninstall -y org.mozilla.firefox");
    rc |= expect_deny("flatpak uninstall --unused -y");
    rc |= expect_deny("flatpak uninstall --unused");
    rc |= expect_deny("flatpak remove --unused");
    rc |= expect_deny("flatpak update -y org.mozilla.firefox");
    rc |= expect_deny("flatpak remote-ls --updates --app");
    rc |= expect_deny("flatpak list --app");
    rc |= expect_deny("flatpak uninstall org.freedesktop.Platform");
    rc |= expect_deny("rm /usr/bin/flatpak");
    rc |= expect_deny("npm uninstall -g typescript");
    rc |= expect_deny("npm -g uninstall typescript");
    rc |= expect_deny("npm install -g foo");
    rc |= expect_deny("npm ls");
    rc |= expect_deny("npm outdated");
    rc |= expect_deny("npm ls --prefix /tmp/proj");
    rc |= expect_deny("npm ls -g --prefix /tmp/proj");
    rc |= expect_deny("pnpm remove -g nx");
    rc |= expect_deny("pnpm ls");
    rc |= expect_deny("pnpm add -g nx");
    rc |= expect_deny("bun remove -g prettier");
    rc |= expect_deny("bun pm ls");
    rc |= expect_deny("bun add -g foo");
    rc |= expect_deny("pipx uninstall httpie");
    rc |= expect_deny("pipx install httpie");
    rc |= expect_deny("uv tool uninstall ruff");
    rc |= expect_deny("uv pip install ruff");
    rc |= expect_deny("brew outdated");
    rc |= expect_deny("brew upgrade wget");
    rc |= expect_deny("brew upgrade --cask visual-studio-code");
    rc |= expect_deny("brew uninstall wget");
    rc |= expect_deny("brew uninstall --cask visual-studio-code");
    rc |= expect_deny("brew outdated --json=v2 --greedy");
    rc |= expect_deny("brew outdated --greedy --json=v2");
    rc |= expect_deny("brew list");
    rc |= expect_deny("brew info --json=v2");
    rc |= expect_deny("brew install wget");
    rc |= expect_deny("brew update");
    rc |= expect_deny("gem uninstall sass");
    rc |= expect_deny("gem update sass");
    rc |= expect_deny("gem update");
    rc |= expect_deny("gem install sass");
    rc |= expect_deny("gem list");
    rc |= expect_deny("composer global update");
    rc |= expect_deny("composer global update laravel/installer");
    rc |= expect_deny("composer global remove laravel/installer");
    rc |= expect_deny("composer global require laravel/installer");
    rc |= expect_deny("composer install");
    rc |= expect_deny("composer global install");
    rc |= expect_deny("composer outdated");
    rc |= expect_deny("composer outdated --format=json");
    rc |= expect_deny("composer global outdated --working-dir /tmp/proj");
    rc |= expect_deny("composer update");
    rc |= expect_deny("uv pip list");
    rc |= expect_deny("pip install httpie");
    rc |= expect_deny("pip3 install httpie");
    rc |= expect_deny("pip uninstall requests");
    rc |= expect_deny("pip3 uninstall urllib3");
    rc |= expect_deny("pip list");
    rc |= expect_deny("pip list --outdated --format=json");
    rc |= expect_deny("pip3 list --outdated --format=json");
    rc |= expect_deny("pip list --user");
    rc |= expect_deny("pip list --user --outdated");
    rc |= expect_deny("pip list --user --format=json");
    rc |= expect_deny("pip freeze --user");
    rc |= expect_deny("pip list --user --outdated --format=json --path /tmp/venv");
    rc |= expect_deny("pip list --user --outdated --format=json --target /tmp");
    rc |= expect_deny("pip3 list --user --outdated --format=json --target=/tmp");
    rc |= expect_deny("pip list --user --outdated --format=json -t /tmp");
    rc |= expect_deny("brew outdated --json=v2 --greedy-latest");
    rc |= expect_deny("brew outdated --json=v2 --greedy-auto-updates");
    rc |= expect_deny("docker images -f dangling=false");
    rc |= expect_deny("docker images --filter=dangling=false");
    rc |= expect_deny("docker ps -a -f dangling=true");
    rc |= expect_deny("docker volume ls -f status=exited");
    rc |= expect_deny("docker images --filter=status=exited");
    rc |= expect_deny("readlink");
    rc |= expect_deny("readlink -f");
    rc |= expect_deny("realpath");
    rc |= expect_deny("test -e");
    rc |= expect_deny("test -f");
    rc |= expect_deny("apt-get -s autoremove --prefix /tmp");
    rc |= expect_deny("npm ls -g --prefix=/tmp/proj");
    rc |= expect_deny("composer global outdated --working-dir=/tmp/proj");
    rc |= expect_deny("");

    char out[4096];
    int     n = appattic_host_exec("apt-get -s autoremove", out, sizeof out);
    if (n <= 0) return fail("apt fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "Remv libfoo0 [1.2.3]") || !strstr(out, "Remv libbar1 [2.0.0]")) {
        return fail("apt fixture text");
    }

    n = appattic_host_exec("apt list --upgradable", out, sizeof out);
    if (n <= 0) return fail("apt upgradable fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "upgradable from") || !strstr(out, "git/stable")) {
        return fail("apt upgradable fixture text");
    }

    n = appattic_host_exec("pacman -Qdt", out, sizeof out);
    if (n <= 0) return fail("pacman fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "libfoo 1.2.3-1")) return fail("pacman fixture text");

    n = appattic_host_exec("pacman -Qu", out, sizeof out);
    if (n <= 0) return fail("pacman -Qu fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "coreutils 9.5-1 -> 9.5-2")) return fail("pacman -Qu fixture text");

    n = appattic_host_exec("snap list --all", out, sizeof out);
    if (n <= 0) return fail("snap fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "disabled") || strstr(out, "snap remove")) {
        return fail("snap fixture text");
    }

    n = appattic_host_exec("ls -1 /home/user/.local/bin", out, sizeof out);
    if (n <= 0) return fail("ls user-bin fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "gone-app") || !strstr(out, "herdr-link") || !strstr(out, "python3") ||
        strstr(out, "orphan-cfg")) {
        return fail("ls user-bin fixture text");
    }

    n = appattic_host_exec("ls -1 /usr/bin", out, sizeof out);
    if (n <= 0) return fail("ls usr-bin fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "python3") || strstr(out, "gone-app")) {
        return fail("ls usr-bin fixture text");
    }

    n = appattic_host_exec("readlink -f /home/user/.local/bin/python3", out, sizeof out);
    if (n <= 0) return fail("readlink overlay python3 fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "/home/user/.local/bin/python3")) return fail("readlink overlay python3 fixture text");

    n = appattic_host_exec("readlink -f /usr/bin/python3", out, sizeof out);
    if (n <= 0) return fail("readlink packaged python3 fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "/usr/bin/python3")) return fail("readlink packaged python3 fixture text");

    n = appattic_host_exec("test -f /home/user/.local/bin/python3", out, sizeof out);
    if (n != 0) return fail("test -f python3 fixture missing");
    n = appattic_host_exec("test -f /usr/bin/python3", out, sizeof out);
    if (n != 0) return fail("test -f /usr/bin/python3 fixture missing");

    n = appattic_host_exec("test -h /home/user/.local/bin/gone-app", out, sizeof out);
    if (n != 0) return fail("test -h gone-app fixture missing");
    n = appattic_host_exec("test -e /home/user/.local/bin/gone-app", out, sizeof out);
    if (n >= 0) return fail("test -e gone-app should fail fixture");
    n = appattic_host_exec("test -e /home/user/.local/bin/herdr-link", out, sizeof out);
    if (n != 0) return fail("test -e herdr-link fixture missing");
    n = appattic_host_exec("test -f /home/user/.local/bin/herdr", out, sizeof out);
    if (n != 0) return fail("test -f herdr fixture missing");
    n = appattic_host_exec("test -f /home/user/.local/bin/dconf", out, sizeof out);
    if (n != 0) return fail("test -f dconf fixture missing");
    n = appattic_host_exec("test -f /home/user/.local/bin/gone-app", out, sizeof out);
    if (n >= 0) return fail("test -f gone-app should fail fixture");
    n = appattic_host_exec("test -f /home/user/.local/bin/herdr-link", out, sizeof out);
    if (n >= 0) return fail("test -f herdr-link should fail fixture");
    n = appattic_host_exec("test -f /home/user/.local/bin/python3", out, sizeof out);
    if (n != 0) return fail("test -f python3 fixture missing");
    n = appattic_host_exec("realpath /home/user/.local/bin/python3", out, sizeof out);
    if (n <= 0) return fail("realpath fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "/home/user/.local/bin/python3")) return fail("realpath fixture text");
    n = appattic_host_exec("readlink -f /usr/bin/python3", out, sizeof out);
    if (n <= 0) return fail("readlink -f fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "/usr/bin/python3")) return fail("readlink -f fixture text");

    n = appattic_host_exec("ls -1", out, sizeof out);
    if (n <= 0) return fail("ls fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "gone-app")) return fail("ls fixture text");

    n = appattic_host_exec("ls -1 /home/user/snap", out, sizeof out);
    if (n <= 0) return fail("ls snap fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "gone-app") || !strstr(out, "firefox") || !strstr(out, "chromium")) {
        return fail("ls snap fixture text");
    }

    n = appattic_host_exec("ls -1A", out, sizeof out);
    if (n <= 0) return fail("ls -1A fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, ".mozilla") || !strstr(out, ".wine")) return fail("ls -1A fixture text");

    n = appattic_host_exec("ls -1A /home/user", out, sizeof out);
    if (n <= 0) return fail("ls -1A home fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, ".mozilla") || !strstr(out, ".wine") || strstr(out, "gone-app")) {
        return fail("ls -1A home fixture text");
    }

    n = appattic_host_exec("ls -1 /home/user/.config", out, sizeof out);
    if (n <= 0) return fail("ls config fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "gone-app") || !strstr(out, "orphan-cfg")) {
        return fail("ls config fixture text");
    }

    n = appattic_host_exec("dnf repoquery --unneeded --qf %{name}", out, sizeof out);
    if (n <= 0) return fail("dnf fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "libfoo") || !strstr(out, "python3-bar")) return fail("dnf fixture text");

    n = appattic_host_exec("dnf list --upgrades", out, sizeof out);
    if (n <= 0) return fail("dnf upgrades fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "git.x86_64") || !strstr(out, "2.45.1-1.fc40")) return fail("dnf upgrades fixture text");

    n = appattic_host_exec("dnf check-update", out, sizeof out);
    if (n <= 0) return fail("dnf check-update fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "firefox.x86_64")) return fail("dnf check-update fixture text");

    n = appattic_host_exec("zypper --non-interactive packages --unneeded", out, sizeof out);
    if (n <= 0) return fail("zypper fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "libfoo") || !strstr(out, "1.2.3-1")) return fail("zypper fixture text");

    n = appattic_host_exec("zypper --non-interactive list-updates", out, sizeof out);
    if (n <= 0) return fail("zypper list-updates fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "2.45.1-1.1") || !strstr(out, "vim")) return fail("zypper list-updates fixture text");

    n = appattic_host_exec("flatpak uninstall --unused --dry-run", out, sizeof out);
    if (n <= 0) return fail("flatpak fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "org.freedesktop.Platform.GL.default") || strstr(out, "remote-ls")) {
        return fail("flatpak fixture text");
    }

    n = appattic_host_exec("npm ls -g --depth=0 --json", out, sizeof out);
    if (n <= 0) return fail("npm ls fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "typescript") || !strstr(out, "prettier")) return fail("npm ls fixture text");

    n = appattic_host_exec("npm outdated -g --json", out, sizeof out);
    if (n <= 0) return fail("npm outdated fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "wanted")) return fail("npm outdated fixture text");

    n = appattic_host_exec("pnpm ls -g --depth=0 --json", out, sizeof out);
    if (n <= 0) return fail("pnpm fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "nx") || strstr(out, "typescript")) return fail("pnpm fixture text");

    n = appattic_host_exec("bun pm ls -g", out, sizeof out);
    if (n <= 0) return fail("bun fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "typescript@5.4.5") || !strstr(out, "prettier@3.3.0")) {
        return fail("bun fixture text");
    }

    n = appattic_host_exec("pipx list --json", out, sizeof out);
    if (n <= 0) return fail("pipx fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "httpie") || !strstr(out, "3.2.2")) return fail("pipx fixture text");

    n = appattic_host_exec("pip list --user --outdated --format=json", out, sizeof out);
    if (n <= 0) return fail("pip fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "requests") || !strstr(out, "2.32.3") || !strstr(out, "urllib3") ||
        strstr(out, "pip uninstall") || strstr(out, "pip install")) {
        return fail("pip fixture text");
    }

    n = appattic_host_exec("pip3 list --user --outdated --format=json", out, sizeof out);
    if (n <= 0) return fail("pip3 fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "requests") || !strstr(out, "urllib3")) return fail("pip3 fixture text");

    n = appattic_host_exec("uv tool list", out, sizeof out);
    if (n <= 0) return fail("uv fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "ruff v0.6.8") || !strstr(out, "httpie v3.2.2")) return fail("uv fixture text");

    n = appattic_host_exec("brew outdated --json=v2", out, sizeof out);
    if (n <= 0) return fail("brew fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "wget") || !strstr(out, "visual-studio-code") || strstr(out, "brew uninstall")) {
        return fail("brew fixture text");
    }

    n = appattic_host_exec("gem outdated", out, sizeof out);
    if (n <= 0) return fail("gem fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "sass") || !strstr(out, "nokogiri") || strstr(out, "gem uninstall")) {
        return fail("gem fixture text");
    }

    n = appattic_host_exec("composer global outdated", out, sizeof out);
    if (n <= 0) return fail("composer fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "laravel/installer") || !strstr(out, "5.8.0 ! 5.10.0") ||
        !strstr(out, "phpunit/phpunit") ||
        strstr(out, "composer global update") || strstr(out, "composer global remove")) {
        return fail("composer fixture text");
    }

    n = appattic_host_exec("composer global outdated --format=json", out, sizeof out);
    if (n <= 0) return fail("composer json-flag fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "laravel/installer") || !strstr(out, "phpunit/phpunit")) {
        return fail("composer json-flag fixture text");
    }

    n = appattic_host_exec("docker images -f dangling=true", out, sizeof out);
    if (n <= 0) return fail("docker images fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "a1b2c3d4e5f6") || !strstr(out, "b9e8d7c6b5a4")) {
        return fail("docker images fixture text");
    }

    n = appattic_host_exec("podman images -f dangling=true", out, sizeof out);
    if (n <= 0) return fail("podman images fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "a1b2c3d4e5f6")) return fail("podman images fixture text");

    n = appattic_host_exec("docker volume ls -f dangling=true", out, sizeof out);
    if (n <= 0) return fail("docker volume fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "orphvol") || !strstr(out, "leftover_data")) {
        return fail("docker volume fixture text");
    }

    n = appattic_host_exec("docker ps -a -f status=exited", out, sizeof out);
    if (n <= 0) return fail("docker ps fixture missing");
    out[n < (int)sizeof out ? n : (int)sizeof out - 1] = '\0';
    if (!strstr(out, "c0ffee123456") || !strstr(out, "web") || strstr(out, "system prune")) {
        return fail("docker ps fixture text");
    }

    if (rc != 0) return 1;
    printf("hostexec_test: ok\n");
    return 0;
}
