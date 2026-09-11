const builtin = @import("builtin");
const std = @import("std");

pub const fail: i32 = -2;
pub const bad: i32 = -3;

const apt_fixture =
    \\Reading package lists... Done
    \\The following packages will be REMOVED:
    \\  libfoo0 libbar1
    \\0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.
    \\Remv libfoo0 [1.2.3]
    \\Remv libbar1 [2.0.0]
    \\
;

const apt_upgradable_fixture =
    \\Listing...
    \\git/stable 1:2.39.5-0+deb12u2 amd64 [upgradable from: 1:2.39.2-1.1]
    \\code/stable 1.90.2-1718 amd64 [upgradable from: 1.90.0-1600]
    \\
;

const dpkg_list_fixture =
    \\Desired=Unknown/Install/Remove/Purge/Hold
    \\| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
    \\|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
    \\||/ Name           Version      Architecture Description
    \\+++-==============-============-============-=================================
    \\ii  bash           5.2.15-2     amd64        GNU Bourne Again SHell
    \\rc  oldpkg         1.0-1        amd64        leftover config
    \\rc  gone-lib       2.2-3        amd64        unused leftover
    \\
;

const apt_sources_fixture =
    \\google-chrome.list
    \\deadsnakes-ubuntu-ppa-noble.list
    \\nodesource.list
    \\ubuntu.sources
    \\
;

const pacman_fixture =
    \\libfoo 1.2.3-1
    \\libbar 2.0.0-1
    \\
;

const pacman_outdated_fixture =
    \\coreutils 9.5-1 -> 9.5-2
    \\firefox 129.0-1 -> 129.0.1-1
    \\
;

const snap_fixture =
    \\Name     Version                     Rev    Tracking         Publisher     Notes
    \\bare     1.0                         5      latest/stable    canonical**   base
    \\core22   20240111                    1122   latest/stable    canonical*    base
    \\core22   20231123                    1033   latest/stable    canonical*    disabled
    \\chromium 120.0.6099.224              1846   latest/stable    canonical**   disabled
    \\core20   20230622                    1974   latest/stable    canonical**   base,disabled
    \\firefox  129.0                       4336   latest/stable    mozilla**     -
    \\
;

const ls_fixture =
    \\gone-app
    \\orphan-cfg
    \\dconf
    \\
;

const ls_snap_fixture =
    \\gone-app
    \\chromium
    \\firefox
    \\bare
    \\
;

const ls_dot_fixture =
    \\.mozilla
    \\.wine
    \\dconf
    \\
;

const ls_user_bin_fixture =
    \\gone-app
    \\dconf
    \\herdr
    \\herdr-link
    \\python3
    \\
;

const shadow_package_ls =
    \\python3
    \\
;

const ls_user_home_bin_fixture =
    \\
;

fn testFixtureOk(cmd: []const u8) bool {
    if (!std.mem.startsWith(u8, cmd, "test ")) return false;
    const slash = std.mem.lastIndexOfScalar(u8, cmd, '/') orelse return false;
    const path = cmd[slash..];
    const want_h = std.mem.indexOf(u8, cmd, "-h") != null or std.mem.indexOf(u8, cmd, "-L") != null;
    const want_e = std.mem.indexOf(u8, cmd, "-e") != null;
    const want_f = std.mem.indexOf(u8, cmd, "-f") != null;
    const is_gone = std.mem.indexOf(u8, path, "gone-app") != null;
    const is_link = std.mem.indexOf(u8, path, "herdr-link") != null;
    const is_regular = std.mem.indexOf(u8, path, "dconf") != null or
        (std.mem.indexOf(u8, path, "herdr") != null and std.mem.indexOf(u8, path, "herdr-link") == null) or
        std.mem.indexOf(u8, path, "python3") != null;
    if (want_f) return is_regular;
    if (want_h) return is_gone or is_link;
    if (want_e) return is_link;
    return false;
}

const dnf_fixture =
    \\Last metadata expiration check: 1:23:45 ago on Wed 26 Aug 2026.
    \\libfoo
    \\python3-bar
    \\
;

const dnf_upgrades_fixture =
    \\Last metadata expiration check: 0:12:00 ago on Tue 25 Aug 2026.
    \\Available Upgrades
    \\git.x86_64                    2.45.1-1.fc40           updates
    \\firefox.x86_64                129.0-1.fc40            updates
    \\
;

const zypper_fixture =
    \\S | Name   | Type    | Version | Arch   | Repository
    \\--+--------+---------+---------+--------+-----------
    \\i | libfoo | package | 1.2.3-1 | x86_64 | repo
    \\i | libbar | package | 2.0.0-1 | x86_64 | repo
    \\
;

const zypper_updates_fixture =
    \\Loading repository data...
    \\S | Repository | Name | Current Version | Available Version | Arch
    \\--+------------+------+-----------------+-------------------+-------
    \\v | Update     | git  | 2.43.0-1.1      | 2.45.1-1.1        | x86_64
    \\v | OSS        | vim  | 9.1-1           | 9.1-2             | x86_64
    \\
;

const flatpak_fixture =
    \\Looking for unused runtimes to uninstall...
    \\
    \\        ID                                             Branch    Op
    \\ 1.     org.freedesktop.Platform.GL.default            23.08     r
    \\ 2.     org.freedesktop.Platform.Locale                23.08     r
    \\
;

const flatpak_updates_fixture =
    \\Application Version
    \\org.mozilla.firefox 130.0
    \\
;

const flatpak_list_fixture =
    \\Application Version
    \\org.mozilla.firefox 128.0
    \\org.gnome.Calculator 46.0
    \\
;

const npm_ls_fixture =
    \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
    \\
;

const npm_outdated_fixture =
    \\{"typescript":{"current":"5.4.5","wanted":"5.5.0","latest":"5.5.0"}}
    \\
;

const pnpm_fixture =
    \\{"dependencies":{"nx":{"version":"19.0.0"}}}
    \\
;

const bun_fixture =
    \\/home/user/.bun/install/global/node_modules
    \\├── typescript@5.4.5
    \\└── prettier@3.3.0
    \\
;

const pipx_fixture =
    \\{"venvs":{"httpie":{"metadata":{"main_package":{"package":"httpie","package_version":"3.2.2"}}}}}
    \\
;

const pip_fixture =
    \\[{"name":"requests","version":"2.28.1","latest_version":"2.32.3","latest_filetype":"wheel"},{"name":"urllib3","version":"1.26.18","latest_version":"2.2.2"}]
    \\
;

const pip_list_fixture =
    \\[{"name":"httpie","version":"3.2.2"},{"name":"requests","version":"2.28.1"}]
    \\
;

const pip_not_required_fixture =
    \\[{"name":"httpie","version":"3.2.2"}]
    \\
;

const ls_deno_fixture =
    \\deno
    \\file_server
    \\deployctl
    \\
;

const uv_fixture =
    \\ruff v0.6.8
    \\- ruff
    \\httpie v3.2.2
    \\- http
    \\
;

const brew_fixture =
    \\{"formulae":[{"name":"wget","installed_versions":["1.21.4"],"current_version":"1.24.5","pinned":false,"pinned_version":null}],"casks":[{"name":"visual-studio-code","installed_versions":["1.90.0"],"current_version":"1.92.1","pinned":false,"pinned_version":null}]}
    \\
;

const gem_fixture =
    \\*** LOCAL GEMS ***
    \\
    \\sass (3.7.4 < 3.7.5)
    \\nokogiri (1.16.0 < 1.16.7)
    \\
;

const composer_fixture =
    \\laravel/installer 5.8.0 ! 5.10.0 Laravel application installer
    \\phpunit/phpunit 9.6.19 ~ 11.3.0 The PHP Unit Testing framework.
    \\
;

const docker_images_fixture =
    \\REPOSITORY   TAG       IMAGE ID       CREATED        SIZE
    \\<none>       <none>    a1b2c3d4e5f6   2 weeks ago    12MB
    \\<none>       <none>    b9e8d7c6b5a4   3 months ago   8MB
    \\
;

const docker_volume_fixture =
    \\DRIVER    VOLUME NAME
    \\local     orphvol
    \\local     leftover_data
    \\
;

const docker_ps_fixture =
    \\CONTAINER ID   IMAGE     COMMAND   CREATED        STATUS                      PORTS     NAMES
    \\c0ffee123456   nginx     nginx     3 weeks ago    Exited (0) 3 weeks ago                web
    \\deadbeef0001   alpine    sh        2 months ago   Exited (1) 2 months ago               oldjob
    \\
;

fn isDockerish(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "docker ") or std.mem.startsWith(u8, cmd, "podman ") or
        std.mem.startsWith(u8, cmd, "/usr/bin/docker ") or std.mem.startsWith(u8, cmd, "/usr/bin/podman ");
}

fn fixtureFor(cmd: []const u8) ?[]const u8 {
    if (isDockerish(cmd)) {
        if (std.mem.indexOf(u8, cmd, "volume") != null) return docker_volume_fixture;
        if (std.mem.indexOf(u8, cmd, "images") != null) return docker_images_fixture;
        if (std.mem.indexOf(u8, cmd, " ps") != null) return docker_ps_fixture;
        return null;
    }
    if (std.mem.indexOf(u8, cmd, "--upgradable") != null) return apt_upgradable_fixture;
    if (std.mem.indexOf(u8, cmd, "autoremove") != null) return apt_fixture;
    if (std.mem.startsWith(u8, cmd, "dpkg ") or std.mem.indexOf(u8, cmd, "/dpkg ") != null) {
        return dpkg_list_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "paru") or std.mem.startsWith(u8, cmd, "yay") or
        std.mem.startsWith(u8, cmd, "pikaur") or std.mem.indexOf(u8, cmd, "/paru ") != null or
        std.mem.indexOf(u8, cmd, "/yay ") != null or std.mem.indexOf(u8, cmd, "/pikaur ") != null)
    {
        return pacman_outdated_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "pacman") != null) {
        if (std.mem.indexOf(u8, cmd, "-Qu") != null) return pacman_outdated_fixture;
        return pacman_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "/snap") != null and std.mem.startsWith(u8, cmd, "ls")) {
        return ls_snap_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "snap") or std.mem.indexOf(u8, cmd, "/snap") != null) {
        return snap_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "--upgrades") != null or std.mem.indexOf(u8, cmd, "check-update") != null) {
        return dnf_upgrades_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "repoquery") != null) return dnf_fixture;
    if (std.mem.indexOf(u8, cmd, "list-updates") != null) return zypper_updates_fixture;
    if (std.mem.indexOf(u8, cmd, "zypper") != null) return zypper_fixture;
    if (std.mem.startsWith(u8, cmd, "flatpak") or std.mem.indexOf(u8, cmd, "/flatpak") != null) {
        if (std.mem.indexOf(u8, cmd, "remote-ls") != null or std.mem.indexOf(u8, cmd, "--updates") != null) {
            return flatpak_updates_fixture;
        }
        if (std.mem.indexOf(u8, cmd, " list") != null or std.mem.endsWith(u8, cmd, " list") or
            std.mem.indexOf(u8, cmd, " ls") != null)
        {
            return flatpak_list_fixture;
        }
        return flatpak_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "pnpm")) return pnpm_fixture;
    if (std.mem.startsWith(u8, cmd, "npm")) {
        if (std.mem.indexOf(u8, cmd, "outdated") != null) return npm_outdated_fixture;
        return npm_ls_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "bun")) return bun_fixture;
    if (std.mem.startsWith(u8, cmd, "pipx")) return pipx_fixture;
    if (std.mem.startsWith(u8, cmd, "pip3 ") or std.mem.indexOf(u8, cmd, "/pip3 ") != null or
        std.mem.startsWith(u8, cmd, "pip ") or std.mem.indexOf(u8, cmd, "/pip ") != null)
    {
        if (std.mem.indexOf(u8, cmd, "outdated") != null) return pip_fixture;
        if (std.mem.indexOf(u8, cmd, "not-required") != null) return pip_not_required_fixture;
        return pip_list_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "uv")) return uv_fixture;
    if (std.mem.startsWith(u8, cmd, "brew ") or std.mem.indexOf(u8, cmd, "/brew ") != null) {
        return brew_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "gem ") or std.mem.indexOf(u8, cmd, "/gem ") != null) {
        return gem_fixture;
    }
    if (std.mem.startsWith(u8, cmd, "composer ") or std.mem.indexOf(u8, cmd, "/composer ") != null) {
        return composer_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "/.deno/bin") != null and std.mem.startsWith(u8, cmd, "ls")) {
        return ls_deno_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "sources.list.d") != null and std.mem.startsWith(u8, cmd, "ls")) {
        return apt_sources_fixture;
    }
    if (std.mem.indexOf(u8, cmd, "/.local/bin") != null and std.mem.startsWith(u8, cmd, "ls")) {
        return ls_user_bin_fixture;
    }
    if ((std.mem.endsWith(u8, cmd, "/home/user/bin") or std.mem.indexOf(u8, cmd, "/home/user/bin/") != null) and
        std.mem.startsWith(u8, cmd, "ls"))
    {
        return ls_user_home_bin_fixture;
    }
    if (std.mem.indexOf(u8, cmd, " /usr/bin") != null and std.mem.startsWith(u8, cmd, "ls")) {
        return shadow_package_ls;
    }
    if (std.mem.startsWith(u8, cmd, "readlink -f ") or std.mem.startsWith(u8, cmd, "realpath ")) {
        if (std.mem.indexOf(u8, cmd, "/.local/bin/python3") != null) {
            return "/home/user/.local/bin/python3";
        }
        if (std.mem.indexOf(u8, cmd, "/usr/bin/python3") != null) {
            return "/usr/bin/python3";
        }
        return null;
    }
    if (std.mem.startsWith(u8, cmd, "test ")) {
        return if (testFixtureOk(cmd)) "" else null;
    }
    if (std.mem.eql(u8, cmd, "ls -1A") or std.mem.startsWith(u8, cmd, "ls -1A ") or
        std.mem.startsWith(u8, cmd, "ls -A")) return ls_dot_fixture;
    if (std.mem.startsWith(u8, cmd, "ls")) return ls_fixture;
    return null;
}

fn nativeRun(cmd: []const u8, out: []u8) i32 {
    const text = fixtureFor(cmd) orelse return fail;
    if (text.len <= out.len) {
        @memcpy(out[0..text.len], text);
        return @intCast(text.len);
    }
    @memcpy(out[0..out.len], text[0..out.len]);
    var n = out.len;
    while (n > 0 and out[n - 1] != '\n') n -= 1;
    if (n == 0) return bad;
    return @intCast(n);
}

/// Query-only host.exec. Wasm guest imports `host.exec`. Native tests inject fixtures.
pub fn run(cmd: []const u8, out: []u8) i32 {
    if (comptime builtin.cpu.arch == .wasm32) {
        const Imp = struct {
            pub extern "host" fn exec(cmd_ptr: i32, cmd_len: i32, out_ptr: i32, out_cap: i32) i32;
        };
        return Imp.exec(
            @intCast(@intFromPtr(cmd.ptr)),
            @intCast(cmd.len),
            @intCast(@intFromPtr(out.ptr)),
            @intCast(out.len),
        );
    }
    return nativeRun(cmd, out);
}

test "native fixture routes apt pacman snap ls dnf zypper flatpak npm pnpm bun pipx pip uv brew gem composer docker" {
    var buf: [2048]u8 = undefined;
    const a = run("apt-get -s autoremove", &buf);
    try std.testing.expect(a > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(a)], "Remv libfoo0") != null);

    const au = run("apt list --upgradable", &buf);
    try std.testing.expect(au > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(au)], "upgradable from") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(au)], "git/stable") != null);

    const p = run("pacman -Qdt", &buf);
    try std.testing.expect(p > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(p)], "libfoo 1.2.3-1") != null);

    const pu = run("pacman -Qu", &buf);
    try std.testing.expect(pu > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pu)], "coreutils 9.5-1 -> 9.5-2") != null);

    const aur = run("paru -Qua", &buf);
    try std.testing.expect(aur > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(aur)], "coreutils 9.5-1 -> 9.5-2") != null);

    const dpkg = run("dpkg -l", &buf);
    try std.testing.expect(dpkg > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(dpkg)], "rc  oldpkg") != null);

    const ppa = run("ls -1 /etc/apt/sources.list.d", &buf);
    try std.testing.expect(ppa > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(ppa)], "deadsnakes-ubuntu-ppa-noble.list") != null);

    const s = run("snap list --all", &buf);
    try std.testing.expect(s > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(s)], "chromium") != null);

    const lsnap = run("ls -1 /home/user/snap", &buf);
    try std.testing.expect(lsnap > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lsnap)], "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lsnap)], "firefox") != null);

    const l = run("ls -1", &buf);
    try std.testing.expect(l > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(l)], "gone-app") != null);

    const lbin = run("ls -1 /home/user/.local/bin", &buf);
    try std.testing.expect(lbin > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lbin)], "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lbin)], "herdr-link") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lbin)], "python3") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lbin)], "orphan-cfg") == null);

    const lusr = run("ls -1 /usr/bin", &buf);
    try std.testing.expect(lusr > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(lusr)], "python3") != null);

    const rl_over = run("readlink -f /home/user/.local/bin/python3", &buf);
    try std.testing.expect(rl_over > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rl_over)], "/home/user/.local/bin/python3") != null);
    const rl_pkg = run("readlink -f /usr/bin/python3", &buf);
    try std.testing.expect(rl_pkg > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rl_pkg)], "/usr/bin/python3") != null);

    const la = run("ls -1A", &buf);
    try std.testing.expect(la > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(la)], ".mozilla") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(la)], ".wine") != null);
    const la_root = run("ls -1A /home/user", &buf);
    try std.testing.expect(la_root > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(la_root)], ".mozilla") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(la_root)], "gone-app") == null);

    const d = run("dnf5 repoquery --unneeded --qf %{name}", &buf);
    try std.testing.expect(d > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(d)], "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(d)], "python3-bar") != null);

    const du = run("dnf list --upgrades", &buf);
    try std.testing.expect(du > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(du)], "git.x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(du)], "2.45.1-1.fc40") != null);

    const dc = run("dnf check-update", &buf);
    try std.testing.expect(dc > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(dc)], "firefox.x86_64") != null);

    const z = run("zypper --non-interactive packages --unneeded", &buf);
    try std.testing.expect(z > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(z)], "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(z)], "1.2.3-1") != null);

    const zu = run("zypper --non-interactive list-updates", &buf);
    try std.testing.expect(zu > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(zu)], "2.45.1-1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(zu)], "vim") != null);

    const f = run("flatpak uninstall --unused --dry-run", &buf);
    try std.testing.expect(f > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(f)], "org.freedesktop.Platform.GL.default") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(f)], "remote-ls") == null);

    const fu = run("flatpak remote-ls --updates --app --columns=application,version", &buf);
    try std.testing.expect(fu > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(fu)], "org.mozilla.firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(fu)], "130.0") != null);

    const fl = run("flatpak list --app --columns=application,version", &buf);
    try std.testing.expect(fl > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(fl)], "128.0") != null);

    const nls = run("npm ls -g --depth=0 --json", &buf);
    try std.testing.expect(nls > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(nls)], "typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(nls)], "prettier") != null);

    const nod = run("npm outdated -g --json", &buf);
    try std.testing.expect(nod > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(nod)], "wanted") != null);

    const pn = run("pnpm ls -g --depth=0 --json", &buf);
    try std.testing.expect(pn > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pn)], "nx") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pn)], "typescript") == null);

    const b = run("bun pm ls -g", &buf);
    try std.testing.expect(b > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(b)], "typescript@5.4.5") != null);

    const px = run("pipx list --json", &buf);
    try std.testing.expect(px > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(px)], "httpie") != null);

    const pipnr = run("pip list --user --not-required --format=json", &buf);
    try std.testing.expect(pipnr > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pipnr)], "httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pipnr)], "urllib3") == null);

    const pip = run("pip list --user --outdated --format=json", &buf);
    try std.testing.expect(pip > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pip)], "requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pip)], "2.32.3") != null);

    const pip3 = run("pip3 list --user --outdated --format=json", &buf);
    try std.testing.expect(pip3 > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pip3)], "urllib3") != null);

    const u = run("uv tool list", &buf);
    try std.testing.expect(u > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(u)], "ruff v0.6.8") != null);

    const br = run("brew outdated --json=v2", &buf);
    try std.testing.expect(br > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(br)], "wget") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(br)], "visual-studio-code") != null);

    const gm = run("gem outdated", &buf);
    try std.testing.expect(gm > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(gm)], "sass") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(gm)], "nokogiri") != null);

    const co = run("composer global outdated", &buf);
    try std.testing.expect(co > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(co)], "laravel/installer") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(co)], "5.8.0 ! 5.10.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(co)], "phpunit/phpunit") != null);

    const di = run("docker images -f dangling=true", &buf);
    try std.testing.expect(di > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(di)], "a1b2c3d4e5f6") != null);

    const dv = run("docker volume ls -f dangling=true", &buf);
    try std.testing.expect(dv > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(dv)], "orphvol") != null);

    const dp = run("docker ps -a -f status=exited", &buf);
    try std.testing.expect(dp > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(dp)], "c0ffee123456") != null);

    const pi = run("podman images -f dangling=true", &buf);
    try std.testing.expect(pi > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(pi)], "b9e8d7c6b5a4") != null);

    const rp = run("realpath /home/user/.local/bin/python3", &buf);
    try std.testing.expect(rp > 0);
    try std.testing.expectEqualStrings("/home/user/.local/bin/python3", buf[0..@intCast(rp)]);
    const rl = run("readlink -f /usr/bin/python3", &buf);
    try std.testing.expect(rl > 0);
    try std.testing.expectEqualStrings("/usr/bin/python3", buf[0..@intCast(rl)]);
}

test "native test -f fixtures" {
    var out: [8]u8 = undefined;
    try std.testing.expect(run("test -f /home/user/.local/bin/herdr", &out) == 0);
    try std.testing.expect(run("test -f /home/user/.local/bin/dconf", &out) == 0);
    try std.testing.expect(run("test -f /home/user/.local/bin/python3", &out) == 0);
    try std.testing.expect(run("test -f /usr/bin/python3", &out) == 0);
    try std.testing.expect(run("test -f /home/user/.local/bin/gone-app", &out) != 0);
    try std.testing.expect(run("test -f /home/user/.local/bin/herdr-link", &out) != 0);
    try std.testing.expect(run("test -h /home/user/.local/bin/gone-app", &out) == 0);
    try std.testing.expect(run("test -e /home/user/.local/bin/gone-app", &out) != 0);
    try std.testing.expect(run("test -e /home/user/.local/bin/herdr-link", &out) == 0);
}
