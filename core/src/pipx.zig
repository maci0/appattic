const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "pipx";
const query_cmds = [_][]const u8{
    "pipx list --json",
    "pipx list",
};

var result_buf: [65536]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [32768]u8 = undefined;

const none_json =
    \\{"plugin":"pipx","engine":null,"findings":[],"script":null,"dialog":{"title":"No pipx","body":"pipx is not on PATH. Plugin inactive."},"note":"pipx missing"}
;

pub const PipxTool = struct {
    name: []const u8,
    version: []const u8,
};

fn parsePipxJson(text: []const u8, out: []PipxTool) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '"') {
            i += 1;
            continue;
        }
        const key = jsonscan.parseJsonString(text, &i) orelse break;
        i = jsonscan.skipWs(text, i);
        if (i >= text.len or text[i] != ':') continue;
        i += 1;
        i = jsonscan.skipWs(text, i);
        if (!std.mem.eql(u8, key, "venvs")) continue;
        if (i >= text.len or text[i] != '{') return n;
        i += 1;
        while (i < text.len and n < out.len) {
            i = jsonscan.skipWs(text, i);
            if (i >= text.len) break;
            if (text[i] == '}') {
                i += 1;
                break;
            }
            if (text[i] == ',') {
                i += 1;
                continue;
            }
            const fallback = jsonscan.parseJsonString(text, &i) orelse break;
            i = jsonscan.skipWs(text, i);
            if (i >= text.len or text[i] != ':') break;
            i += 1;
            i = jsonscan.skipWs(text, i);
            var name = fallback;
            var version: []const u8 = "";
            if (i < text.len and text[i] == '{') {
                const start = i;
                if (!jsonscan.skipJsonValue(text, &i)) break;
                const slice = text[start..i];
                if (jsonscan.findJsonStringField(slice, "package")) |p| name = p;
                if (jsonscan.findJsonStringField(slice, "package_version")) |v| version = v;
            } else {
                if (!jsonscan.skipJsonValue(text, &i)) break;
            }
            if (!jsonbuf.isSafePkgName(name)) continue;
            out[n] = .{ .name = name, .version = version };
            n += 1;
        }
        return n;
    }
    return n;
}

fn parsePipxText(text: []const u8, out: []PipxTool) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const marker = "package ";
        const start = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = std.mem.trim(u8, line[start + marker.len ..], " \t");
        var it = std.mem.tokenizeAny(u8, rest, " \t");
        const name = it.next() orelse continue;
        var ver = it.next() orelse continue;
        if (std.mem.endsWith(u8, ver, ",")) ver = ver[0 .. ver.len - 1];
        if (!jsonbuf.isSafePkgName(name)) continue;
        out[n] = .{ .name = name, .version = ver };
        n += 1;
    }
    return n;
}

/// Parse `pipx list --json` (`venvs`) or `pipx list` text (`package name ver,`).
pub fn parsePipxList(text: []const u8, out: []PipxTool) usize {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len > 0 and t[0] == '{') return parsePipxJson(t, out);
    return parsePipxText(text, out);
}

fn renderPipx(hits: []const PipxTool) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"pipx\",\"engine\":\"pipx\",\"findings\":[");
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
        w.raw(",\"status\":\"global\",\"command\":\"pipx uninstall ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"pipx\"}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic pipx. Review before running.\\n");
        for (hits) |h| {
            w.raw("pipx uninstall ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pipx tools?\",\"body\":\"User-global pipx tools only. Named uninstall waits for confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn runQuery() i32 {
    for (query_cmds) |cmd| {
        const n = host_exec.run(cmd, &exec_buf);
        if (n >= 0) return n;
    }
    return host_exec.fail;
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
    const nexec = runQuery();
    if (nexec < 0) {
        if (!renderPipx(&.{})) return 1;
        return 0;
    }
    var hits: [128]PipxTool = undefined;
    var n = parsePipxList(exec_buf[0..@intCast(nexec)], &hits);
    while (true) {
        if (renderPipx(hits[0..n])) return 0;
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

test "parsePipxList JSON and text" {
    var buf: [8]PipxTool = undefined;
    const json =
        \\{"venvs":{"httpie":{"metadata":{"main_package":{"package":"httpie","package_version":"3.2.2"}}}}}
    ;
    const n = parsePipxList(json, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("httpie", buf[0].name);
    try std.testing.expectEqualStrings("3.2.2", buf[0].version);

    const text =
        \\venvs are in /home/x/.local/share/pipx/venvs
        \\   package httpie 3.2.2, installed using Python 3.12.3
        \\    - http
        \\
    ;
    const n2 = parsePipxList(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("httpie", buf[0].name);
    try std.testing.expectEqualStrings("3.2.2", buf[0].version);
}

test "parsePipxList empty junk" {
    var buf: [4]PipxTool = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePipxList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipxList("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipxList("nothing here", &buf));
}

fn packFuzzSlice(comptime s: []const u8) [4 + s.len]u8 {
    var out: [4 + s.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4..], s);
    return out;
}

const fuzz_pipx_json = packFuzzSlice(
    \\{"venvs":{"httpie":{"metadata":{"main_package":{"package":"httpie","package_version":"3.2.2"}}}}}
);
const fuzz_pipx_text = packFuzzSlice(
    "package httpie 3.2.2, installed using Python 3.12.3\n",
);
const fuzz_pipx_truncated = packFuzzSlice(
    \\{"venvs":{"httpie":{"metadata":{"main_package":{"package":"http
);

test "fuzz parsePipxList" {
    try std.testing.fuzz({}, fuzzPipxList, .{ .corpus = &.{
        &fuzz_pipx_json,
        &fuzz_pipx_text,
        &fuzz_pipx_truncated,
    } });
}

fn fuzzPipxList(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];
    var tools: [32]PipxTool = undefined;
    const n = parsePipxList(text, &tools);
    try std.testing.expect(n <= tools.len);
    for (tools[0..n]) |tool| {
        try std.testing.expect(jsonbuf.isSafePkgName(tool.name));
        try std.testing.expect(std.mem.indexOf(u8, text, tool.name) != null);
        try std.testing.expect(tool.version.len == 0 or std.mem.indexOf(u8, text, tool.version) != null);
    }
}

test "plugin_query present JSON comes from pipx list fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pipx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "3.2.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pipx uninstall httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pipx missing") != null);
}
