const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const Io = std.Io;
const Dir = Io.Dir;

const plugin_id = "path-shadow";

fn nativeIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

pub const ShadowFinding = struct {
    name: []const u8,
    path: []const u8,
    shadows: []const u8,
};

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn joinPath(dir: []const u8, name: []const u8, store: []u8, used: *usize) ?[]const u8 {
    const need = dir.len + 1 + name.len;
    if (used.* + need > store.len) return null;
    const start = used.*;
    @memcpy(store[used.*..][0..dir.len], dir);
    used.* += dir.len;
    store[used.*] = '/';
    used.* += 1;
    @memcpy(store[used.*..][0..name.len], name);
    used.* += name.len;
    return store[start..used.*];
}

fn resolvePathNative(io: Io, path: []const u8, buf: []u8) ?[]const u8 {
    const n = Dir.realPathFileAbsolute(io, path, buf) catch return null;
    return buf[0..n];
}

fn isRegularFile(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn findShadowsNative(
    overlayDirs: []const []const u8,
    packageDirs: []const []const u8,
    out: []ShadowFinding,
    path_store: []u8,
) usize {
    var n: usize = 0;
    var used: usize = 0;
    var o_res: [4096]u8 = undefined;
    var p_res: [4096]u8 = undefined;

    const io = nativeIo();
    for (overlayDirs) |odir| {
        var dir = Dir.cwd().openDir(io, odir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (n >= out.len) return n;
            if (entry.kind == .directory) continue;
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') continue;
            if (!jsonbuf.isSafeIdent(name)) continue;

            const overlay_path = joinPath(odir, name, path_store, &used) orelse continue;
            if (!isRegularFile(io, overlay_path)) continue;
            const resolved_overlay = resolvePathNative(io, overlay_path, &o_res) orelse continue;

            var packaged: ?[]const u8 = null;
            var same = false;
            for (packageDirs) |pdir| {
                const pkg_path = joinPath(pdir, name, path_store, &used) orelse continue;
                if (!isRegularFile(io, pkg_path)) continue;
                const resolved_pkg = resolvePathNative(io, pkg_path, &p_res) orelse continue;
                if (std.mem.eql(u8, resolved_overlay, resolved_pkg)) {
                    same = true;
                    break;
                }
                if (packaged == null) packaged = pkg_path;
            }
            if (same or packaged == null) continue;
            out[n] = .{ .name = name, .path = overlay_path, .shadows = packaged.? };
            n += 1;
        }
    }
    return n;
}

fn listingNames(listing: []const u8, names: *[64][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        if (n >= names.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name = basenameOf(line);
        if (name.len == 0 or name[0] == '.') continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        names[n] = name;
        n += 1;
    }
    return n;
}

fn resolvePathExec(path: []const u8, buf: []u8) ?[]const u8 {
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "realpath {s}", .{path}) catch return null;
    const n = host_exec.run(cmd, buf);
    if (n < 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn fileExistsExec(path: []const u8) bool {
    var cmd_buf: [512]u8 = undefined;
    var out: [8]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "test -f {s}", .{path}) catch return false;
    return host_exec.run(cmd, &out) == 0;
}

fn findShadowsExec(
    overlayDirs: []const []const u8,
    packageDirs: []const []const u8,
    out: []ShadowFinding,
    path_store: []u8,
) usize {
    var n: usize = 0;
    var used: usize = 0;
    var ls_buf: [65536]u8 = undefined;
    var ov_buf: [512]u8 = undefined;
    var pkg_buf: [512]u8 = undefined;
    var name_store: [8192]u8 = undefined;
    var names: [64][]const u8 = undefined;
    var name_used: usize = 0;

    for (overlayDirs) |odir| {
        var cmd_buf: [512]u8 = undefined;
        const ls_cmd = std.fmt.bufPrint(&cmd_buf, "ls -1 {s}", .{odir}) catch continue;
        const ls_n = host_exec.run(ls_cmd, &ls_buf);
        if (ls_n < 0) continue;
        const raw_n = listingNames(ls_buf[0..@intCast(ls_n)], &names);
        var copied: usize = 0;
        while (copied < raw_n) : (copied += 1) {
            const src = names[copied];
            if (name_used + src.len > name_store.len) break;
            const start = name_used;
            @memcpy(name_store[name_used..][0..src.len], src);
            name_used += src.len;
            names[copied] = name_store[start..name_used];
        }

        for (names[0..copied]) |name| {
            if (n >= out.len) return n;
            const overlay_path = joinPath(odir, name, path_store, &used) orelse continue;
            if (!fileExistsExec(overlay_path)) continue;
            const resolved_overlay = resolvePathExec(overlay_path, &ov_buf) orelse continue;

            var packaged: ?[]const u8 = null;
            var same = false;
            for (packageDirs) |pdir| {
                const pkg_path = joinPath(pdir, name, path_store, &used) orelse continue;
                if (!fileExistsExec(pkg_path)) continue;
                const resolved_pkg = resolvePathExec(pkg_path, &pkg_buf) orelse continue;
                if (std.mem.eql(u8, resolved_overlay, resolved_pkg)) {
                    same = true;
                    break;
                }
                if (packaged == null) packaged = pkg_path;
            }
            if (same or packaged == null) continue;
            out[n] = .{ .name = name, .path = overlay_path, .shadows = packaged.? };
            n += 1;
        }
    }
    return n;
}

/// Scan overlay dirs for files that shadow same-named files in package dirs.
pub fn findShadows(
    overlayDirs: []const []const u8,
    packageDirs: []const []const u8,
    out: []ShadowFinding,
    path_store: []u8,
) usize {
    if (comptime builtin.cpu.arch == .wasm32) {
        return findShadowsExec(overlayDirs, packageDirs, out, path_store);
    }
    return findShadowsNative(overlayDirs, packageDirs, out, path_store);
}

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;

const none_json =
    \\{"plugin":"path-shadow","engine":null,"findings":[],"script":null,"dialog":{"title":"No overlay roots","body":"Overlay PATH dirs missing. Plugin inactive."},"note":"path missing"}
;

const overlay_fixture = "/home/user/.local/bin";
const overlay_home_bin = "/home/user/bin";
const package_fixture = "/usr/bin";

fn renderShadows(hits: []const ShadowFinding) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"path-shadow\",\"engine\":null,\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"shadow\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"status\":\"shadow\",\"shadows\":");
        w.str(h.shadows);
        w.raw(",\"command\":\"rm -f ");
        w.raw(h.path);
        w.raw("\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic path-shadow. Review before running.\\n");
        for (hits) |h| {
            w.raw("rm -f ");
            w.raw(h.path);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove shadowing files?\",\"body\":\"Overlay files hide packaged copies. Nothing runs until you confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

export fn plugin_abi_version() i32 {
    return abi.ABI_VERSION;
}

export fn plugin_id_ptr() i32 {
    return @intCast(@intFromPtr(plugin_id.ptr));
}

export fn plugin_id_len() i32 {
    return @intCast(plugin_id.len);
}

export fn plugin_query(present: i32) i32 {
    if (present == 0) {
        @memcpy(result_buf[0..none_json.len], none_json);
        result_nbytes = @intCast(none_json.len);
        return 0;
    }
    const overlays = [_][]const u8{ overlay_fixture, overlay_home_bin };
    const packages = [_][]const u8{package_fixture};
    var hits: [32]ShadowFinding = undefined;
    var paths: [2048]u8 = undefined;
    var n = findShadows(&overlays, &packages, &hits, &paths);
    while (true) {
        if (renderShadows(hits[0..n])) return 0;
        if (n == 0) return 1;
        n -= 1;
    }
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "findShadows reports different overlay file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "overlay");
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "overlay/python3", .data = "#!/bin/sh\necho user\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/python3", .data = "#!/bin/sh\necho distro\n" });

    var overlay_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const overlay_dir = try tmp.dir.realPathFile(io, "overlay", &overlay_rp);
    const package_dir = try tmp.dir.realPathFile(io, "usr/bin", &package_rp);

    var hits: [8]ShadowFinding = undefined;
    var paths: [1024]u8 = undefined;
    const overlays = [_][]const u8{overlay_rp[0..overlay_dir]};
    const packages = [_][]const u8{package_rp[0..package_dir]};
    const n = findShadows(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("python3", hits[0].name);
    try std.testing.expect(std.mem.endsWith(u8, hits[0].path, "/overlay/python3"));
    try std.testing.expect(std.mem.endsWith(u8, hits[0].shadows, "/usr/bin/python3"));
}

test "findShadows skips symlink to packaged file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "overlay");
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/python3", .data = "#!/bin/sh\necho distro\n" });

    var pkg_rp: [512]u8 = undefined;
    const pkg_n = try tmp.dir.realPathFile(io, "usr/bin/python3", &pkg_rp);
    try tmp.dir.symLink(io, pkg_rp[0..pkg_n], "overlay/python3", .{});

    var overlay_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const overlay_dir = try tmp.dir.realPathFile(io, "overlay", &overlay_rp);
    const package_dir = try tmp.dir.realPathFile(io, "usr/bin", &package_rp);

    var hits: [8]ShadowFinding = undefined;
    var paths: [1024]u8 = undefined;
    const overlays = [_][]const u8{overlay_rp[0..overlay_dir]};
    const packages = [_][]const u8{package_rp[0..package_dir]};
    const n = findShadows(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "plugin_query present JSON includes shadow finding" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-shadow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dialog\":") != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
