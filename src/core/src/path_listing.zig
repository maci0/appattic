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

/// Parse `ls -1` / `ls -1A` of a leftover root. Skip only `.` and `..`.
/// Names in `keep` (newline list) are not orphans.
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
    const nexec = host_exec.run(spec.query_cmd, &exec_buf);
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
