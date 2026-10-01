const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "uv";
const query_cmd = "uv tool list";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [32768]u8 = undefined;

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
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"uv\",\"engine\":\"uv\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeRowGuard(&cmd_w, &q_buf, "uv tool list", .{ .after = " v" }, "uv tool uninstall ", h.name);
        jsonbuf.writeGlobal(&w, h.name, h.version, cmd_w.slice(), "uv");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic uv. Review before running.\\n");
        for (hits) |h| {
            guard.writeRowGuard(&w, &q_buf, "uv tool list", .{ .after = " v" }, "uv tool uninstall ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove uv tools?\",\"body\":\"uv tool installs only. Named uninstall waits for confirm.\"}");
    note.write(&w);
    w.raw("}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn query_impl(present: i32) i32 {
    note = .{};
    if (present == 0) {
        plugin_abi.publishMissing(result_buf[0..], &result_nbytes, none_json);
        return 0;
    }
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec < 0) {
        if (!renderUv(&.{})) return 1;
        return 0;
    }
    var hits: [128]UvTool = undefined;
    var n = parseUvToolList(exec_buf[0..@intCast(nexec)], &hits);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderUv, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
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
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"uv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ruff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0.6.8") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "uv tool uninstall ruff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if uv tool list | grep -qF -- 'ruff v'; then uv tool uninstall ruff; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "uv pip install") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "uv missing") != null);
}

// Seeds are what `uv tool list` prints: the tool rows with their leading `-`
// entry lines, blank lines and trailing whitespace, a bare runtime name, then
// the ways this listing arrives broken: a name with no version, a version that
// is just `v`, extra tokens, names the command guard has to reject, and the
// bytes a directory entry on disk can carry (NUL, C0, a BOM, invalid UTF-8).
const fuzz_uv_rows = packFuzzSlice(
    \\ruff v0.6.8
    \\- ruff
    \\httpie v3.2.2
    \\- http
    \\
);
const fuzz_uv_no_version = packFuzzSlice("ruff\nruffv\n\n   \nv\nv\nx v0\n");
const fuzz_uv_edges = packFuzzSlice(
    \\ruff v0.6.8 extra tokens
    \\  httpie   v3.2.2
    \\deno v1.0
    \\@scope/tool v1.2.3
    \\@scope v1.0
);
const fuzz_uv_unsafe = packFuzzSlice(
    \\ruff;rm -rf / v1.0
    \\../../etc v1.0
    \\-x v1.0
    \\$(id) v1.0
);
const fuzz_uv_junk = packFuzzSlice("\x00\xff\r\n \t\nv\rv\n \xef\xbb\xbfrust v1");
const fuzz_uv_empty = packFuzzSlice("");

test "fuzz parseUvToolList" {
    try std.testing.fuzz({}, fuzzUvToolList, .{ .corpus = &.{
        &fuzz_uv_rows,
        &fuzz_uv_no_version,
        &fuzz_uv_edges,
        &fuzz_uv_unsafe,
        &fuzz_uv_junk,
        &fuzz_uv_empty,
    } });
}

/// The name of a reported row is spliced into a `uv tool uninstall <name>`
/// line, so it has to pass the package-name rule and to be a slice of this
/// input rather than a dead buffer. The version is the second token with one
/// leading `v` removed, so it is a slice of the input too, and a token shorter
/// than `v0` is not a version at all, so no reported row carries an empty one.
/// Rows are read one line at a time, so reading the same text twice has to give
/// the same rows.
fn fuzzUvToolList(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var buf: [32]UvTool = undefined;
    const n = parseUvToolList(text, &buf);
    try std.testing.expect(n <= buf.len);
    for (buf[0..n]) |tool| {
        try std.testing.expect(jsonbuf.isSafePkgName(tool.name));
        try std.testing.expect(sliceInside(text, tool.name));
        try std.testing.expect(sliceInside(text, tool.version));
        // A reported row always has a version: the parser skips a second token
        // shorter than `v0`.
        try std.testing.expect(tool.version.len > 0);
    }

    var again: [32]UvTool = undefined;
    const n2 = parseUvToolList(text, &again);
    try std.testing.expectEqual(n, n2);
    for (buf[0..n], again[0..n2]) |a, b| {
        try std.testing.expect(std.mem.eql(u8, a.name, b.name));
        try std.testing.expect(std.mem.eql(u8, a.version, b.version));
    }
}
