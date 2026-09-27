const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "pnpm";
const query_cmd = "pnpm ls -g --depth=0 --json";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [32768]u8 = undefined;

const none_json =
    \\{"plugin":"pnpm","engine":null,"findings":[],"script":null,"dialog":{"title":"No pnpm","body":"pnpm is not on PATH. Plugin inactive."},"note":"pnpm missing"}
;

pub const PnpmGlobal = struct {
    name: []const u8,
    version: []const u8,
};

/// Parse `pnpm ls -g --depth=0 --json` (object or array of objects).
pub fn parsePnpmGlobalList(text: []const u8, out: []PnpmGlobal) usize {
    var deps: [128]jsonscan.Dep = undefined;
    const n = jsonscan.parseJsonDependencies(text, &deps);
    const cap = @min(n, out.len);
    for (0..cap) |i| {
        out[i] = .{ .name = deps[i].name, .version = deps[i].version };
    }
    return cap;
}

fn renderPnpm(hits: []const PnpmGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"pnpm\",\"engine\":\"pnpm\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeRowGuard(&cmd_w, &q_buf, "pnpm ls -g --depth=0", .{ .after = "@" }, "pnpm remove -g ", h.name);
        jsonbuf.writeGlobal(&w, h.name, h.version, cmd_w.slice(), "pnpm");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic pnpm. Review before running.\\n");
        for (hits) |h| {
            guard.writeRowGuard(&w, &q_buf, "pnpm ls -g --depth=0", .{ .after = "@" }, "pnpm remove -g ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pnpm globals?\",\"body\":\"User-global -g packages only. Not project lockfiles. Named remove waits for confirm.\"}}");
    note.write(&w);
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn query_impl(present: i32) i32 {
    note = .{};
    if (present == 0) {
        @memcpy(result_buf[0..none_json.len], none_json);
        result_nbytes = @intCast(none_json.len);
        return 0;
    }
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec < 0) {
        if (!renderPnpm(&.{})) return 1;
        return 0;
    }
    var hits: [128]PnpmGlobal = undefined;
    var n = parsePnpmGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderPnpm, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
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
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pnpm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nx") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "19.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pnpm remove -g nx") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if pnpm ls -g --depth=0 | grep -qF -- nx@; then pnpm remove -g nx; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pnpm add") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "package.json") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pnpm missing") != null);
}
