const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "npm";
const query_cmd = "npm ls -g --depth=0 --json";
const outdated_cmd = "npm outdated -g --json";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var exec_out_buf: [65536]u8 = undefined;

const none_json =
    \\{"plugin":"npm","engine":null,"findings":[],"script":null,"dialog":{"title":"No npm","body":"npm is not on PATH. Plugin inactive."},"note":"npm missing"}
;

/// Parse `npm ls -g --depth=0 --json`. User-global `dependencies` only.
pub fn parseNpmGlobalList(text: []const u8, out: []jsonscan.Dep) usize {
    return jsonscan.parseJsonDependencies(text, out);
}

fn renderNpm(hits: []const jsonscan.Dep, outdated: []const jsonscan.NamedVer) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"npm\",\"engine\":\"npm\",\"findings\":[");
    var first = true;
    for (hits) |h| {
        if (!first) w.raw(",");
        first = false;
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeRowGuard(&cmd_w, &q_buf, "npm ls -g --depth=0", .{ .after = "@" }, "npm -g uninstall ", h.name);
        jsonbuf.writeGlobal(&w, h.name, h.version, cmd_w.slice(), "npm");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "npm", "", false);
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic npm. Review before running.\\n");
        for (hits) |h| {
            guard.writeRowGuard(&w, &q_buf, "npm ls -g --depth=0", .{ .after = "@" }, "npm -g uninstall ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove npm globals?\",\"body\":\"User-global -g packages only. Not project node_modules. Outdated rows are report-only. Named uninstall waits for confirm.\"}");
    note.write(&w);
    w.raw("}");
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
    var hits: [128]jsonscan.Dep = undefined;
    var n: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec >= 0) n = parseNpmGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    note.addTruncatedRows(n, hits.len);

    var outdated: [128]jsonscan.NamedVer = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_out_buf);
    note.add(outdated_cmd, nq);
    if (nq >= 0) n_out = jsonscan.parseJsonNamedOutdated(exec_out_buf[0..@intCast(nq)], &outdated);
    note.addTruncatedRows(n_out, outdated.len);

    return note.renderShrinkingPair(renderNpm, &hits, &n, &outdated, &n_out);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "parseNpmGlobalList dependencies JSON" {
    var buf: [8]jsonscan.Dep = undefined;
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
    var buf: [4]jsonscan.Dep = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseNpmGlobalList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseNpmGlobalList("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseNpmGlobalList("not json", &buf));
}

test "plugin_query present JSON comes from npm ls -g fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"npm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "5.4.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "prettier") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "npm -g uninstall typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if npm ls -g --depth=0 | grep -qF -- typescript@; then npm -g uninstall typescript; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "5.5.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "npm install") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "package.json") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "npm missing") != null);
}
