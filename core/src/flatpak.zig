const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "flatpak";
const query_cmd = "flatpak uninstall --unused --dry-run";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"flatpak","engine":null,"findings":[],"script":null,"dialog":{"title":"No flatpak","body":"flatpak is not on PATH. Plugin inactive."},"note":"flatpak missing"}
;

pub const FlatpakUnused = struct {
    name: []const u8,
    branch: []const u8,
};

fn isNumberedPrefix(t: []const u8) bool {
    if (t.len < 2 or t[t.len - 1] != '.') return false;
    for (t[0 .. t.len - 1]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isArch(t: []const u8) bool {
    return std.mem.eql(u8, t, "x86_64") or std.mem.eql(u8, t, "aarch64") or
        std.mem.eql(u8, t, "i386") or std.mem.eql(u8, t, "i686") or
        std.mem.eql(u8, t, "arm") or std.mem.eql(u8, t, "noarch") or
        std.mem.eql(u8, t, "ppc64le") or std.mem.eql(u8, t, "s390x");
}

fn skipUnusedNoise(line: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(line, "looking")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "nothing unused")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "info:")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "uninstalling")) return true;
    return false;
}

fn splitRef(tok: []const u8, name: *[]const u8, branch: *[]const u8) bool {
    var it = std.mem.splitScalar(u8, tok, '/');
    const id = it.next() orelse return false;
    const mid = it.next();
    const last = it.next();
    if (!jsonbuf.isSafeIdent(id)) return false;
    name.* = id;
    if (last) |b| {
        _ = mid;
        if (jsonbuf.isSafeIdent(b)) branch.* = b;
    }
    return true;
}

/// Parse `flatpak uninstall --unused --dry-run`. Numbered leftover runtimes only.
/// `flatpak list` / `remote-ls` dumps are not unused.
pub fn parseFlatpakUnused(text: []const u8, out: []FlatpakUnused) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (skipUnusedNoise(line)) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const first = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(first, "ID") or std.ascii.eqlIgnoreCase(first, "Name") or
            std.ascii.eqlIgnoreCase(first, "Application")) continue;

        var name: []const u8 = "";
        var branch: []const u8 = "";
        if (isNumberedPrefix(first)) {
            const idtok = it.next() orelse continue;
            if (std.mem.indexOfScalar(u8, idtok, '/') != null) {
                if (!splitRef(idtok, &name, &branch)) continue;
            } else {
                if (!jsonbuf.isSafeIdent(idtok) or std.mem.indexOfScalar(u8, idtok, '.') == null) continue;
                name = idtok;
            }
            while (it.next()) |tok| {
                if (tok.len == 1) continue;
                if (tok[0] == '[') continue;
                if (isArch(tok)) continue;
                if (jsonbuf.isSafeIdent(tok) and branch.len == 0) {
                    branch = tok;
                    break;
                }
            }
        } else if (std.mem.indexOfScalar(u8, first, '/') != null) {
            if (!splitRef(first, &name, &branch)) continue;
        } else {
            continue;
        }
        if (name.len == 0) continue;
        out[n] = .{ .name = name, .branch = branch };
        n += 1;
    }
    return n;
}

fn renderFlatpak(hits: []const FlatpakUnused) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"flatpak\",\"engine\":\"flatpak\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"unused-runtime\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.branch.len > 0) {
            w.raw(",\"version\":");
            w.str(h.branch);
        }
        w.raw(",\"status\":\"orphaned\",\"command\":\"flatpak uninstall -y ");
        w.raw(h.name);
        if (h.branch.len > 0) {
            w.raw(" ");
            w.raw(h.branch);
        }
        w.raw("\",\"manager\":\"flatpak\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic flatpak. Review before running.\\n");
        for (hits) |h| {
            w.raw("flatpak uninstall -y ");
            w.raw(h.name);
            if (h.branch.len > 0) {
                w.raw(" ");
                w.raw(h.branch);
            }
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove unused Flatpak runtimes?\",\"body\":\"Named unused runtimes only. Installed apps stay on Stale Apps. Outdated updates stay report-only. Nothing runs until you confirm.\"}}");
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
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec < 0) {
        if (!renderFlatpak(&.{})) return 1;
        return 0;
    }
    var hits: [32]FlatpakUnused = undefined;
    const n = parseFlatpakUnused(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderFlatpak(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseFlatpakUnused numbered leftover runtimes" {
    var buf: [8]FlatpakUnused = undefined;
    const text =
        \\Looking for unused runtimes to uninstall...
        \\
        \\        ID                                             Branch    Op
        \\ 1.     org.freedesktop.Platform.GL.default            23.08     r
        \\ 2.     org.freedesktop.Platform.Locale                23.08     r
        \\
    ;
    const n = parseFlatpakUnused(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("org.freedesktop.Platform.GL.default", buf[0].name);
    try std.testing.expectEqualStrings("23.08", buf[0].branch);
    try std.testing.expectEqualStrings("org.freedesktop.Platform.Locale", buf[1].name);
    try std.testing.expectEqualStrings("23.08", buf[1].branch);
}

test "parseFlatpakUnused skips list dump and empty" {
    var buf: [4]FlatpakUnused = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseFlatpakUnused("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseFlatpakUnused("Nothing unused to uninstall\n", &buf),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        parseFlatpakUnused("org.mozilla.firefox\t128.0\tstable\tflathub\n", &buf),
    );
}

test "parseFlatpakUnused ref form after number" {
    var buf: [4]FlatpakUnused = undefined;
    const n = parseFlatpakUnused(" 1. org.freedesktop.Platform/x86_64/23.08\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("org.freedesktop.Platform", buf[0].name);
    try std.testing.expectEqualStrings("23.08", buf[0].branch);
}

test "plugin_query present JSON comes from unused dry-run fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"flatpak\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "unused-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "org.freedesktop.Platform.GL.default") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "23.08") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak uninstall -y org.freedesktop.Platform.GL.default") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak remote-ls") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "org.mozilla.firefox") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /usr/bin/flatpak") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak missing") != null);
}
