const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "pnpm";
const query_cmd = "pnpm ls -g --depth=0 --json";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [8192]u8 = undefined;

const none_json =
    \\{"plugin":"pnpm","engine":null,"findings":[],"script":null,"dialog":{"title":"No pnpm","body":"pnpm is not on PATH. Plugin inactive."},"note":"pnpm missing"}
;

pub const PnpmGlobal = struct {
    name: []const u8,
    version: []const u8,
};

/// Parse `pnpm ls -g --depth=0 --json` (object or array of objects).
pub fn parsePnpmGlobalList(text: []const u8, out: []PnpmGlobal) usize {
    var deps: [32]jsonscan.Dep = undefined;
    const n = jsonscan.parseJsonDependencies(text, &deps);
    const cap = @min(n, out.len);
    for (0..cap) |i| {
        out[i] = .{ .name = deps[i].name, .version = deps[i].version };
    }
    return cap;
}

fn renderPnpm(hits: []const PnpmGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"pnpm\",\"engine\":\"pnpm\",\"findings\":[");
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
        w.raw(",\"status\":\"global\",\"command\":\"pnpm remove -g ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"pnpm\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic pnpm. Review before running.\\n");
        for (hits) |h| {
            w.raw("pnpm remove -g ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pnpm globals?\",\"body\":\"User-global -g packages only. Not project lockfiles. Named remove waits for confirm.\"}}");
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
        if (!renderPnpm(&.{})) return 1;
        return 0;
    }
    var hits: [32]PnpmGlobal = undefined;
    const n = parsePnpmGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderPnpm(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parsePnpmGlobalList object and array" {
    var buf: [4]PnpmGlobal = undefined;
    const object =
        \\{"dependencies":{"nx":{"version":"19.0.0"}}}
    ;
    const n = parsePnpmGlobalList(object, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("nx", buf[0].name);
    try std.testing.expectEqualStrings("19.0.0", buf[0].version);

    const array =
        \\[{"dependencies":{"nx":{"version":"19.0.0"}}}]
    ;
    const n2 = parsePnpmGlobalList(array, &buf);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("nx", buf[0].name);
}

test "parsePnpmGlobalList empty" {
    var buf: [4]PnpmGlobal = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePnpmGlobalList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePnpmGlobalList("{}", &buf));
}

test "plugin_query present JSON comes from pnpm ls -g fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pnpm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nx") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "19.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pnpm remove -g nx") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pnpm add") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "package.json") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pnpm missing") != null);
}
