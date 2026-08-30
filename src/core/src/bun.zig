const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "bun";
const query_cmd = "bun pm ls -g";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"bun","engine":null,"findings":[],"script":null,"dialog":{"title":"No bun","body":"bun is not on PATH. Plugin inactive."},"note":"bun missing"}
;

pub const BunGlobal = struct {
    name: []const u8,
    version: []const u8,
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '@' or c == '_';
}

fn stripTree(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (isIdentStart(line[i])) return line[i..];
    }
    return line[0..0];
}

fn splitNameVer(s: []const u8) ?BunGlobal {
    if (s.len == 0) return null;
    const at: usize = blk: {
        if (s[0] == '@') {
            const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
            const rel = std.mem.indexOfScalar(u8, s[slash + 1 ..], '@') orelse return null;
            break :blk slash + 1 + rel;
        }
        break :blk std.mem.indexOfScalar(u8, s, '@') orelse return null;
    };
    if (at == 0 or at + 1 >= s.len) return null;
    const name = s[0..at];
    var version = s[at + 1 ..];
    if (std.mem.indexOfAny(u8, version, " \t")) |sp| version = version[0..sp];
    if (!jsonbuf.isSafePkgName(name)) return null;
    if (version.len == 0) return null;
    return .{ .name = name, .version = version };
}

/// Parse `bun pm ls -g` tree (`name@version` rows). Path headers skipped.
pub fn parseBunGlobalList(text: []const u8, out: []BunGlobal) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const rest = stripTree(line);
        const hit = splitNameVer(rest) orelse continue;
        out[n] = hit;
        n += 1;
    }
    return n;
}

fn renderBun(hits: []const BunGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"bun\",\"engine\":\"bun\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"global\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.version.len > 0) {
            w.raw(",\"version\":");
            w.str(h.version);
        }
        w.raw(",\"status\":\"global\",\"command\":\"bun remove -g ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"bun\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic bun. Review before running.\\n");
        for (hits) |h| {
            w.raw("bun remove -g ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove bun globals?\",\"body\":\"User-global bun packages only. Named remove waits for confirm.\"}}");
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
        if (!renderBun(&.{})) return 1;
        return 0;
    }
    var hits: [32]BunGlobal = undefined;
    const n = parseBunGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderBun(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseBunGlobalList tree" {
    var buf: [8]BunGlobal = undefined;
    const text =
        \\/home/user/.bun/install/global/node_modules
        \\├── typescript@5.4.5
        \\└── prettier@3.3.0
        \\
    ;
    const n = parseBunGlobalList(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
    try std.testing.expectEqualStrings("prettier", buf[1].name);
    try std.testing.expectEqualStrings("3.3.0", buf[1].version);
}

test "parseBunGlobalList scoped and empty" {
    var buf: [4]BunGlobal = undefined;
    const n = parseBunGlobalList("└── @vue/cli@5.0.8\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("@vue/cli", buf[0].name);
    try std.testing.expectEqualStrings("5.0.8", buf[0].version);
    try std.testing.expectEqual(@as(usize, 0), parseBunGlobalList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseBunGlobalList("/home/user/.bun/install/global/node_modules\n", &buf));
}

test "plugin_query present JSON comes from bun pm ls -g fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"bun\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "prettier") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bun remove -g typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bun add") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "package.json") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bun missing") != null);
}
