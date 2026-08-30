const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "npm";
const query_cmd = "npm ls -g --depth=0 --json";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [8192]u8 = undefined;

const none_json =
    \\{"plugin":"npm","engine":null,"findings":[],"script":null,"dialog":{"title":"No npm","body":"npm is not on PATH. Plugin inactive."},"note":"npm missing"}
;

pub const NpmGlobal = struct {
    name: []const u8,
    version: []const u8,
};

/// Parse `npm ls -g --depth=0 --json`. User-global `dependencies` only.
pub fn parseNpmGlobalList(text: []const u8, out: []NpmGlobal) usize {
    var deps: [32]jsonscan.Dep = undefined;
    const n = jsonscan.parseJsonDependencies(text, &deps);
    const cap = @min(n, out.len);
    for (0..cap) |i| {
        out[i] = .{ .name = deps[i].name, .version = deps[i].version };
    }
    return cap;
}

fn renderNpm(hits: []const NpmGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"npm\",\"engine\":\"npm\",\"findings\":[");
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
        w.raw(",\"status\":\"global\",\"command\":\"npm -g uninstall ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"npm\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic npm. Review before running.\\n");
        for (hits) |h| {
            w.raw("npm -g uninstall ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove npm globals?\",\"body\":\"User-global -g packages only. Not project node_modules. Named uninstall waits for confirm.\"}}");
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
        if (!renderNpm(&.{})) return 1;
        return 0;
    }
    var hits: [32]NpmGlobal = undefined;
    const n = parseNpmGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderNpm(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseNpmGlobalList dependencies JSON" {
    var buf: [8]NpmGlobal = undefined;
    const text =
        \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
    ;
    const n = parseNpmGlobalList(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
    try std.testing.expectEqualStrings("prettier", buf[1].name);
}

test "parseNpmGlobalList empty junk" {
    var buf: [4]NpmGlobal = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseNpmGlobalList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseNpmGlobalList("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseNpmGlobalList("not json", &buf));
}

test "plugin_query present JSON comes from npm ls -g fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"npm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "5.4.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "prettier") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "npm -g uninstall typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "npm install") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "package.json") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "npm missing") != null);
}
