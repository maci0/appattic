const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "uv";
const query_cmd = "uv tool list";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"uv","engine":null,"findings":[],"script":null,"dialog":{"title":"No uv","body":"uv is not on PATH. Plugin inactive."},"note":"uv missing"}
;

pub const UvTool = struct {
    name: []const u8,
    version: []const u8,
};

/// Parse `uv tool list` (`name vX.Y` rows). Entry lines starting with `-` skipped.
pub fn parseUvToolList(text: []const u8, out: []UvTool) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '-') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        const ver_tok = it.next() orelse continue;
        if (ver_tok.len < 2 or ver_tok[0] != 'v') continue;
        const version = ver_tok[1..];
        if (!jsonbuf.isSafePkgName(name)) continue;
        if (version.len == 0) continue;
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

fn renderUv(hits: []const UvTool) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"uv\",\"engine\":\"uv\",\"findings\":[");
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
        w.raw(",\"status\":\"global\",\"command\":\"uv tool uninstall ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"uv\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic uv. Review before running.\\n");
        for (hits) |h| {
            w.raw("uv tool uninstall ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove uv tools?\",\"body\":\"uv tool installs only. Named uninstall waits for confirm.\"}}");
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
        if (!renderUv(&.{})) return 1;
        return 0;
    }
    var hits: [32]UvTool = undefined;
    const n = parseUvToolList(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderUv(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseUvToolList names skip entry dashes" {
    var buf: [8]UvTool = undefined;
    const text =
        \\ruff v0.6.8
        \\- ruff
        \\httpie v3.2.2
        \\- http
        \\
    ;
    const n = parseUvToolList(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("ruff", buf[0].name);
    try std.testing.expectEqualStrings("0.6.8", buf[0].version);
    try std.testing.expectEqualStrings("httpie", buf[1].name);
    try std.testing.expectEqualStrings("3.2.2", buf[1].version);
}

test "parseUvToolList empty" {
    var buf: [4]UvTool = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseUvToolList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseUvToolList("- ruff\n", &buf));
}

test "plugin_query present JSON comes from uv tool list fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"uv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ruff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0.6.8") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "uv tool uninstall ruff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "uv pip install") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "uv missing") != null);
}
