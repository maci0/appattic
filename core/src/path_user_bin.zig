const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "path-user-bin";

const Root = struct {
    path: []const u8,
    label: []const u8,
};

const roots = [_]Root{
    .{ .path = "/home/user/.local/bin", .label = ".local/bin" },
    .{ .path = "/home/user/bin", .label = "bin" },
};

const keep = "dconf\n";

pub const BrokenLink = struct {
    name: []const u8,
    path: []const u8,
    root_label: []const u8,
};

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn nameInKeep(name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, keep, '\n');
    while (lines.next()) |raw| {
        const k = std.mem.trim(u8, raw, " \t\r");
        if (k.len == 0) continue;
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

fn copySlice(slice: []const u8, store: []u8, used: *usize) ?[]const u8 {
    if (used.* + slice.len > store.len) return null;
    const start = used.*;
    @memcpy(store[used.*..][0..slice.len], slice);
    used.* += slice.len;
    return store[start..used.*];
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
        if (nameInKeep(name)) continue;
        names[n] = name;
        n += 1;
    }
    return n;
}

fn testFlagOk(path: []const u8, flag: []const u8) bool {
    var cmd_buf: [512]u8 = undefined;
    var out: [8]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "test {s} {s}", .{ flag, path }) catch return false;
    return host_exec.run(cmd, &out) == 0;
}

/// Dangling user-bin symlink: test -h (symlink) and not test -e (target missing).
fn isDanglingSymlink(path: []const u8) bool {
    if (!testFlagOk(path, "-h")) return false;
    return !testFlagOk(path, "-e");
}

pub fn findBrokenLinks(out: []BrokenLink, paths: []u8) usize {
    var n: usize = 0;
    var used: usize = 0;
    var ls_buf: [2048]u8 = undefined;
    var names: [64][]const u8 = undefined;

    for (roots) |root| {
        var cmd_buf: [512]u8 = undefined;
        const ls_cmd = std.fmt.bufPrint(&cmd_buf, "ls -1 {s}", .{root.path}) catch continue;
        const ls_n = host_exec.run(ls_cmd, &ls_buf);
        if (ls_n < 0) continue;
        const name_n = listingNames(ls_buf[0..@intCast(ls_n)], &names);

        for (names[0..name_n]) |name| {
            if (n >= out.len) return n;
            const stable_name = copySlice(name, paths, &used) orelse continue;
            const link_path = joinPath(root.path, stable_name, paths, &used) orelse continue;
            if (!isDanglingSymlink(link_path)) continue;
            out[n] = .{ .name = stable_name, .path = link_path, .root_label = root.label };
            n += 1;
        }
    }
    return n;
}

var result_buf: [65536]u8 = undefined;
var result_nbytes: u32 = 0;
var path_store: [8192]u8 = undefined;

fn render(hits: []const BrokenLink) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":");
    w.str(plugin_id);
    w.raw(",\"engine\":null,\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"symlink\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"rootLabel\":");
        w.str(h.root_label);
        w.raw(",\"status\":\"orphaned\",\"command\":\"rm ");
        w.raw(h.path);
        w.raw("\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic ");
        w.raw(plugin_id);
        w.raw(". Review before running.\\n");
        for (hits) |h| {
            w.raw("rm ");
            w.raw(h.path);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove leftover user binaries?\",\"body\":\"Named dirs only. Nothing runs until you confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

const missing_json =
    \\{"plugin":"path-user-bin","engine":null,"findings":[],"script":null,"dialog":{"title":"No leftover root","body":"~/.local/bin is missing. Plugin inactive."},"note":"path missing"}
;

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
        @memcpy(result_buf[0..missing_json.len], missing_json);
        result_nbytes = @intCast(missing_json.len);
        return 0;
    }
    var found: [128]BrokenLink = undefined;
    var n = findBrokenLinks(&found, &path_store);
    while (true) {
        if (render(found[0..n])) return 0;
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

pub fn resultSlice() []const u8 {
    return result_buf[0..result_nbytes];
}

test "findBrokenLinks reports dangling symlink only" {
    var scratch: [8]BrokenLink = undefined;
    const n = findBrokenLinks(&scratch, &path_store);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", scratch[0].name);
    try std.testing.expectEqualStrings("/home/user/.local/bin/gone-app", scratch[0].path);
    try std.testing.expectEqualStrings(".local/bin", scratch[0].root_label);
}

test "plugin_query present JSON uses symlink orphaned fields" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-user-bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"symlink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"orphaned\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/bin/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /home/user/.local/bin/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
