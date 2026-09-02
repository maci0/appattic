const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

pub const Orphan = struct {
    name: []const u8,
    path: []const u8,
};

pub const Spec = struct {
    id: []const u8,
    root_label: []const u8,
    root: []const u8,
    keep: []const u8,
    missing_note: []const u8,
    dialog_title: []const u8,
    /// `ls -1A` for home-dot leftovers (`.mozilla`, `.wine`). Others: `ls -1`.
    query_cmd: []const u8 = "ls -1",
};

/// `ls` the leftover root. Roots with spaces stay as `query_cmd` only:
/// host.exec splits on whitespace and cannot take `Application Support`.
pub fn queryCommand(comptime spec: Spec) []const u8 {
    if (std.mem.indexOfAny(u8, spec.root, " \t") != null) return spec.query_cmd;
    return spec.query_cmd ++ " " ++ spec.root;
}

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// Canned usage timing for path-home-dot smoke (no QFileInfo on fake /home/user paths).
fn usageTimingExtra(comptime spec: Spec, name: []const u8) []const u8 {
    if (!std.mem.eql(u8, spec.id, "path-home-dot")) return "";
    if (std.mem.eql(u8, name, ".mozilla")) return ",\"idleDays\":120";
    if (std.mem.eql(u8, name, ".wine")) return ",\"idleDays\":90";
    return ",\"idleDays\":45";
}

fn nameInKeep(name: []const u8, keep: []const u8) bool {
    var lines = std.mem.splitScalar(u8, keep, '\n');
    while (lines.next()) |raw| {
        const k = std.mem.trim(u8, raw, " \t\r");
        if (k.len == 0) continue;
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

const linux_system_names =
    \\fontconfig
    \\dconf
    \\gconf
    \\gtk-2.0
    \\gtk-3.0
    \\gtk-4.0
    \\glib-2.0
    \\pulse
    \\pipewire
    \\systemd
    \\user-dirs.dirs
    \\user-dirs.locale
    \\xdg
    \\mime
    \\icons
    \\themes
    \\applications
    \\desktop-directories
    \\ibus
    \\fcitx
    \\fcitx5
    \\environment.d
    \\procps
    \\tracker3
    \\upstart
    \\kde
    \\plasma
    \\xfce4
    \\recently-used.xbel
    \\flatpak
    \\containers
    \\Trash
    \\xorg
    \\session
    \\update-notifier
    \\dbus
    \\gvfs
    \\xdg-desktop-portal
    \\gnome-shell
    \\gnome-session
    \\snap
    \\fish
    \\zsh
    \\bash
    \\git
    \\nvim
    \\vim
    \\ssh
    \\gnupg
    \\aws
    \\docker
    \\tmux
    \\direnv
    \\starship
    \\asdf
    \\nvm
    \\pyenv
    \\rbenv
    \\rustup
    \\cargo
    \\npm
    \\yarn
    \\pnpm
    \\pip
    \\conda
    \\htop
    \\curl
    \\thumbnails
    \\mesa_shader_cache
    \\mesa_shader_cache_db
    \\nvidia
    \\gnome-software
    \\evolution
    \\update-manager
    \\gvfs-metadata
    \\man
    \\uv
    \\bun
    \\go
    \\helm
    \\gh
    \\virtualenv
    \\configstore
    \\node
    \\node-gyp
    \\bazelisk
    \\black
    \\pythonentrypoints
    \\swift
    \\gcloud
    \\btop
    \\wasmtime
    \\zls
    \\kube
    \\kubectl
    \\kubebuilder
    \\jetpack
    \\jetpackcache
    \\pacman
    \\yay
    \\paru
    \\makepkg
    \\dnf
    \\dnf5
    \\yum
    \\zypper
    \\rpm
;

const snap_system_names =
    \\bare
    \\core
    \\snapd
    \\gtk-common-themes
    \\gtk3-common-themes
    \\cups
    \\mesa-2404
;

fn nameInListIgnoreCase(name: []const u8, list: []const u8) bool {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const k = std.mem.trim(u8, raw, " \t\r");
        if (k.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(k, name)) return true;
    }
    return false;
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Same rules as Swift `classifyLinuxSystemName`: these are not leftover orphans.
pub fn isSystemLeftoverName(name: []const u8) bool {
    var n = name;
    while (n.len > 0 and n[0] == '.') n = n[1..];
    if (n.len == 0) return false;
    if (nameInListIgnoreCase(n, linux_system_names)) return true;
    if (nameInListIgnoreCase(n, snap_system_names)) return true;
    if (n.len >= 4 and std.ascii.eqlIgnoreCase(n[0..4], "gtk-")) return true;
    if (n.len >= 3 and std.ascii.eqlIgnoreCase(n[0..3], "xdg")) return true;
    if (n.len >= 4 and std.ascii.eqlIgnoreCase(n[0..4], "core")) {
        if (n.len == 4 or isAllDigits(n[4..])) return true;
    }
    if (n.len > 6 and std.ascii.eqlIgnoreCase(n[0..6], "gnome-")) {
        if (std.mem.lastIndexOfScalar(u8, n, '-')) |dash| {
            if (isAllDigits(n[dash + 1 ..])) return true;
        }
    }
    var stem_end: usize = 0;
    while (stem_end < n.len and n[stem_end] != '-' and n[stem_end] != '_') : (stem_end += 1) {}
    if (stem_end >= 2 and nameInListIgnoreCase(n[0..stem_end], linux_system_names)) return true;
    return false;
}

/// Parse `ls -1` / `ls -1A` of a leftover root. Skip `.` and `..`,
/// Linux/snap system names, and names in `keep` (newline list).
pub fn parseListing(
    listing: []const u8,
    keep: []const u8,
    root: []const u8,
    out: []Orphan,
    path_store: []u8,
) usize {
    var n: usize = 0;
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name = basenameOf(line);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        if (isSystemLeftoverName(name)) continue;
        if (nameInKeep(name, keep)) continue;
        const path = if (line.len > 0 and line[0] == '/') line else blk: {
            const need = root.len + 1 + name.len;
            if (used + need > path_store.len) continue;
            const start = used;
            @memcpy(path_store[used..][0..root.len], root);
            used += root.len;
            path_store[used] = '/';
            used += 1;
            @memcpy(path_store[used..][0..name.len], name);
            used += name.len;
            break :blk path_store[start..used];
        };
        out[n] = .{ .name = name, .path = path };
        n += 1;
    }
    return n;
}

var result_buf: [4096]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [2048]u8 = undefined;
var none_json_buf: [512]u8 = undefined;

fn render(comptime spec: Spec, hits: []const Orphan) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":");
    w.str(spec.id);
    w.raw(",\"engine\":null,\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"orphan-dir\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"rootLabel\":");
        w.str(spec.root_label);
        w.raw(usageTimingExtra(spec, h.name));
        w.raw(",\"status\":\"orphaned\",\"command\":\"rm -rf ");
        w.raw(h.path);
        w.raw("\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic ");
        w.raw(spec.id);
        w.raw(". Review before running.\\n");
        for (hits) |h| {
            w.raw("rm -rf ");
            w.raw(h.path);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":");
    w.str(spec.dialog_title);
    w.raw(",\"body\":\"Named dirs only. Nothing runs until you confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn missingJson(comptime spec: Spec) []const u8 {
    var w = jsonbuf.W{ .buf = &none_json_buf };
    w.raw("{\"plugin\":");
    w.str(spec.id);
    w.raw(",\"engine\":null,\"findings\":[],\"script\":null,\"dialog\":{\"title\":\"No leftover root\",\"body\":");
    w.str(spec.missing_note);
    w.raw("},\"note\":\"path missing\"}");
    return w.slice() orelse "{}";
}

pub fn query(comptime spec: Spec, present: i32) i32 {
    if (present == 0) {
        const none = missingJson(spec);
        @memcpy(result_buf[0..none.len], none);
        result_nbytes = @intCast(none.len);
        return 0;
    }
    const nexec = host_exec.run(queryCommand(spec), &exec_buf);
    if (nexec < 0) {
        if (!render(spec, &.{})) return 1;
        return 0;
    }
    var hits: [32]Orphan = undefined;
    var paths: [1024]u8 = undefined;
    const n = parseListing(exec_buf[0..@intCast(nexec)], spec.keep, spec.root, &hits, &paths);
    if (!render(spec, hits[0..n])) return 1;
    return 0;
}

pub fn resultPtr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

pub fn resultLen() i32 {
    return @intCast(result_nbytes);
}

pub fn resultSlice() []const u8 {
    return result_buf[0..result_nbytes];
}

pub fn abiVersion() i32 {
    return abi.ABI_VERSION;
}

/// WASM ABI for one leftover-root plugin. Each `path_*.zig` is a separate
/// compilation; `comptime { listing.bind(spec); }` exports the guest symbols.
pub fn bind(comptime spec: Spec) void {
    const Impl = struct {
        fn plugin_abi_version() callconv(.c) i32 {
            return abiVersion();
        }
        fn plugin_id_ptr() callconv(.c) i32 {
            return @intCast(@intFromPtr(spec.id.ptr));
        }
        fn plugin_id_len() callconv(.c) i32 {
            return @intCast(spec.id.len);
        }
        fn plugin_query(present: i32) callconv(.c) i32 {
            return query(spec, present);
        }
        fn result_ptr() callconv(.c) i32 {
            return resultPtr();
        }
        fn result_len() callconv(.c) i32 {
            return resultLen();
        }
    };
    @export(&Impl.plugin_abi_version, .{ .name = "plugin_abi_version" });
    @export(&Impl.plugin_id_ptr, .{ .name = "plugin_id_ptr" });
    @export(&Impl.plugin_id_len, .{ .name = "plugin_id_len" });
    @export(&Impl.plugin_query, .{ .name = "plugin_query" });
    @export(&Impl.result_ptr, .{ .name = "result_ptr" });
    @export(&Impl.result_len, .{ .name = "result_len" });
}

test "parseListing orphans names not in keep" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseListing(
        "dconf\ngone-app\nhtop\n",
        "dconf\nhtop\n",
        "/home/user/.local/share",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.local/share/gone-app", hits[0].path);
}

test "parseListing keeps home-dot leftovers and skips only . and .." {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseListing(
        ".mozilla\n.wine\n.\n..\ndconf\n",
        "dconf\n",
        "/home/user",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(".mozilla", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.mozilla", hits[0].path);
    try std.testing.expectEqualStrings(".wine", hits[1].name);
    try std.testing.expectEqualStrings("/home/user/.wine", hits[1].path);
}

test "parseListing accepts full paths, skips . and .., keeps other dots" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseListing(
        "/home/user/.cache/gone-app\n.cache-secret\n.\n..\n\n",
        "",
        "/home/user/.cache",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.cache/gone-app", hits[0].path);
    try std.testing.expectEqualStrings(".cache-secret", hits[1].name);
    try std.testing.expectEqualStrings("/home/user/.cache/.cache-secret", hits[1].path);
}

test "parseListing empty listing" {
    var hits: [2]Orphan = undefined;
    var paths: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseListing("", "dconf", "/home/user/.config", &hits, &paths));
}

test "parseListing keeps utf8 leftover names" {
    var hits: [4]Orphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseListing(
        "café\ngone-app\n",
        "",
        "/home/user/.config",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("café", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.config/café", hits[0].path);
    try std.testing.expectEqualStrings("gone-app", hits[1].name);
}

test "queryCommand appends root unless the root has spaces" {
    const linux = Spec{
        .id = "path-xdg-config",
        .root_label = ".config",
        .root = "/home/user/.config",
        .keep = "",
        .missing_note = "",
        .dialog_title = "",
    };
    try std.testing.expectEqualStrings("ls -1 /home/user/.config", queryCommand(linux));
    const home_dot = Spec{
        .id = "path-home-dot",
        .root_label = "home",
        .root = "/home/user",
        .keep = "",
        .missing_note = "",
        .dialog_title = "",
        .query_cmd = "ls -1A",
    };
    try std.testing.expectEqualStrings("ls -1A /home/user", queryCommand(home_dot));
    const darwin = Spec{
        .id = "path-application-support",
        .root_label = "Application Support",
        .root = "/Users/user/Library/Application Support",
        .keep = "",
        .missing_note = "",
        .dialog_title = "",
    };
    try std.testing.expectEqualStrings("ls -1", queryCommand(darwin));
}

test "parseListing skips system names even without keep" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseListing(
        "gtk-3.0\n.git\n.ssh\n.aws\n.docker\ngnome-42\ncore22\ngone-app\n",
        "",
        "/home/user/.config",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expect(isSystemLeftoverName("gtk-3.0"));
    try std.testing.expect(isSystemLeftoverName(".ssh"));
    try std.testing.expect(isSystemLeftoverName(".aws"));
    try std.testing.expect(isSystemLeftoverName(".docker"));
    try std.testing.expect(isSystemLeftoverName("dconf"));
    try std.testing.expect(!isSystemLeftoverName("gone-app"));
    try std.testing.expect(!isSystemLeftoverName(".mozilla"));
}
