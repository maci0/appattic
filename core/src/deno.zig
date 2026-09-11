const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "deno";
const query_cmd = "ls -1 /home/user/.deno/bin";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"deno","engine":null,"findings":[],"script":null,"dialog":{"title":"No deno","body":"deno is not on PATH. Plugin inactive."},"note":"deno missing"}
;

pub const DenoGlobal = struct {
    name: []const u8,
};

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn skipName(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "deno") or std.mem.eql(u8, name, "deno.exe");
}

/// Parse `ls -1 ~/.deno/bin`. Skip the deno runtime itself.
pub fn parseDenoGlobalList(text: []const u8, out: []DenoGlobal) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name = basenameOf(line);
        if (skipName(name)) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .name = name };
        n += 1;
    }
    return n;
}

fn renderDeno(hits: []const DenoGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"deno\",\"engine\":\"deno\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"global\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"status\":\"global\",\"command\":\"deno uninstall --global ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"deno\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic deno. Review before running.\\n");
        for (hits) |h| {
            w.raw("deno uninstall --global ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove Deno globals?\",\"body\":\"User-global Deno installs in ~/.deno/bin only. Named uninstall waits for confirm.\"}}");
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
        if (!renderDeno(&.{})) return 1;
        return 0;
    }
    var hits: [128]DenoGlobal = undefined;
    var n = parseDenoGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    while (true) {
        if (renderDeno(hits[0..n])) return 0;
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

test "parseDenoGlobalList skips runtime" {
    var buf: [8]DenoGlobal = undefined;
    const text =
        \\deno
        \\file_server
        \\deployctl
        \\
    ;
    const n = parseDenoGlobalList(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("file_server", buf[0].name);
    try std.testing.expectEqualStrings("deployctl", buf[1].name);
}

test "parseDenoGlobalList empty and unsafe" {
    var buf: [4]DenoGlobal = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseDenoGlobalList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseDenoGlobalList("deno\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseDenoGlobalList("foo;rm\n", &buf));
}

test "plugin_query present JSON comes from deno bin listing fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"deno\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "file_server") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deployctl") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deno uninstall --global file_server") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"deno\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deno install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deno missing") != null);
}
