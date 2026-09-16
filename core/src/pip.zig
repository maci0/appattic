const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "pip";
const list_cmds = [_][]const u8{
    "pip list --user --not-required --format=json",
    "pip3 list --user --not-required --format=json",
    "pip list --user --format=json",
    "pip3 list --user --format=json",
};
const outdated_cmds = [_][]const u8{
    "pip list --user --outdated --format=json",
    "pip3 list --user --outdated --format=json",
};

var result_buf: [65536]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var exec_out_buf: [65536]u8 = undefined;

const none_json =
    \\{"plugin":"pip","engine":null,"findings":[],"script":null,"dialog":{"title":"No pip","body":"pip is not on PATH. Plugin inactive."},"note":"pip missing"}
;

pub const PipOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

/// One element of `pip list --user --outdated --format=json`.
const ItemCtx = struct {
    out: []PipOutdated,
    n: usize = 0,
    name: []const u8 = "",
    current: []const u8 = "",
    latest: []const u8 = "",

    pub fn onPair(self: *ItemCtx, cur: *jsonscan.Cursor, key: []const u8, vt: jsonscan.Cursor.Tok) jsonscan.Action {
        if (vt == .string) {
            if (std.mem.eql(u8, key, "name")) self.name = cur.value();
            if (std.mem.eql(u8, key, "version")) self.current = cur.value();
            if (std.mem.eql(u8, key, "latest_version")) self.latest = cur.value();
            return .took;
        }
        return .skip;
    }

    pub fn finish(self: *ItemCtx) void {
        if (self.n >= self.out.len) return;
        if (!jsonbuf.isSafeIdent(self.name)) return;
        self.out[self.n] = .{ .name = self.name, .current = self.current, .latest = self.latest };
        self.n += 1;
    }
};

/// Parse `pip list --user --outdated --format=json`. Array of {name, version, latest_version}.
pub fn parsePipOutdatedJSON(text: []const u8, out: []PipOutdated) usize {
    var cur: jsonscan.Cursor = undefined;
    jsonscan.Cursor.init(&cur, text);
    if (cur.next() != .array_begin) return 0;
    var ctx = ItemCtx{ .out = out };
    jsonscan.eachObjectInArray(&cur, ItemCtx, &ctx);
    return ctx.n;
}

fn nameIn(hits: []const PipOutdated, name: []const u8) bool {
    for (hits) |h| {
        if (std.mem.eql(u8, h.name, name)) return true;
    }
    return false;
}

fn renderPip(globals: []const PipOutdated, outdated: []const PipOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"pip\",\"engine\":\"pip\",\"findings\":[");
    var first = true;
    for (globals) |h| {
        if (nameIn(outdated, h.name)) continue;
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"global\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.current.len > 0) {
            w.raw(",\"version\":");
            w.str(h.current);
        }
        w.raw(",\"status\":\"global\",\"command\":\"pip uninstall -y --user ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"pip\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"outdated\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.current.len > 0) {
            w.raw(",\"current_version\":");
            w.str(h.current);
        }
        if (h.latest.len > 0) {
            w.raw(",\"latest_version\":");
            w.str(h.latest);
        }
        w.raw(",\"status\":\"outdated\",\"updatable\":false,\"command\":null,\"manager\":\"pip\"}");
    }
    w.raw("],\"script\":");
    var nscript: usize = 0;
    for (globals) |h| {
        if (!nameIn(outdated, h.name)) nscript += 1;
    }
    if (nscript == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic pip. Review before running.\\n");
        for (globals) |h| {
            if (nameIn(outdated, h.name)) continue;
            w.raw("pip uninstall -y --user ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pip user-site packages?\",\"body\":\"Top-level user-site packages (pip list --user --not-required). Dependencies stay off Packages. Outdated rows are report-only. Named uninstall waits for confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn runQuery(cmds: []const []const u8, buf: []u8) i32 {
    for (cmds) |cmd| {
        const n = host_exec.run(cmd, buf);
        if (n <= 0) continue;
        const body = std.mem.trimStart(u8, buf[0..@intCast(n)], " \t\r\n");
        if (body.len > 0 and body[0] == '[') return n;
    }
    return host_exec.fail;
}

fn query_impl(present: i32) i32 {
    if (present == 0) {
        @memcpy(result_buf[0..none_json.len], none_json);
        result_nbytes = @intCast(none_json.len);
        return 0;
    }
    var globals: [128]PipOutdated = undefined;
    var n_glob: usize = 0;
    const nlist = runQuery(&list_cmds, &exec_buf);
    if (nlist >= 0) n_glob = parsePipOutdatedJSON(exec_buf[0..@intCast(nlist)], &globals);

    var outdated: [128]PipOutdated = undefined;
    var n_out: usize = 0;
    const nq = runQuery(&outdated_cmds, &exec_out_buf);
    if (nq >= 0) n_out = parsePipOutdatedJSON(exec_out_buf[0..@intCast(nq)], &outdated);

    while (true) {
        if (renderPip(globals[0..n_glob], outdated[0..n_out])) return 0;
        if (n_glob > 0) {
            n_glob -= 1;
            continue;
        }
        if (n_out > 0) {
            n_out -= 1;
            continue;
        }
        return 1;
    }
}

fn resultPtr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

fn resultLen() i32 {
    return @intCast(result_nbytes);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, resultPtr, resultLen);
}

test "parsePipOutdatedJSON name version latest_version" {
    var buf: [8]PipOutdated = undefined;
    const text =
        \\[{"name":"requests","version":"2.28.1","latest_version":"2.32.3","latest_filetype":"wheel"},{"name":"urllib3","version":"1.26.18","latest_version":"2.2.2"}]
    ;
    const n = parsePipOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("requests", buf[0].name);
    try std.testing.expectEqualStrings("2.28.1", buf[0].current);
    try std.testing.expectEqualStrings("2.32.3", buf[0].latest);
    try std.testing.expectEqualStrings("urllib3", buf[1].name);
    try std.testing.expectEqualStrings("1.26.18", buf[1].current);
    try std.testing.expectEqualStrings("2.2.2", buf[1].latest);
}

test "parsePipOutdatedJSON pretty printed and dotted name" {
    var buf: [4]PipOutdated = undefined;
    const text =
        \\[
        \\  {"name": "backports.zoneinfo", "version": "0.2.1", "latest_version": "0.2.2"}
        \\]
    ;
    const n = parsePipOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("backports.zoneinfo", buf[0].name);
    try std.testing.expectEqualStrings("0.2.1", buf[0].current);
    try std.testing.expectEqualStrings("0.2.2", buf[0].latest);
}

test "parsePipOutdatedJSON empty junk skips unsafe" {
    var buf: [4]PipOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("[]", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("not json", &buf));
    const bad =
        \\[{"name":"requests;rm","version":"1","latest_version":"2"}]
    ;
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON(bad, &buf));
}

test "renderPip keeps a large user-site list" {
    var hits: [80]PipOutdated = undefined;
    var names: [80][12]u8 = undefined;
    var vers: [80][8]u8 = undefined;
    for (0..80) |i| {
        const n = std.fmt.bufPrint(&names[i], "pkg-{d:0>2}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&vers[i], "1.0.{d}", .{i}) catch unreachable;
        hits[i] = .{ .name = n, .current = v, .latest = "" };
    }
    try std.testing.expect(renderPip(&hits, &.{}));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "pkg-00") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pkg-79") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip uninstall -y --user pkg-00") != null);
}

test "plugin_query present JSON comes from pip list --user --outdated fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip uninstall -y --user httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.28.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.32.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "urllib3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip install") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip3 install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip missing") != null);
}
