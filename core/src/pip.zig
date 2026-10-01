const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

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
var note: querynote.Log = .{};
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

    pub fn reset(self: *ItemCtx) void {
        self.name = "";
        self.current = "";
        self.latest = "";
    }

    pub fn finish(self: *ItemCtx) void {
        if (self.n >= self.out.len) return;
        if (!jsonbuf.isSafeCmdIdent(self.name)) return;
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

fn renderPip(outdated: []const PipOutdated, globals: []const PipOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"pip\",\"engine\":\"pip\",\"findings\":[");
    var first = true;
    for (globals) |h| {
        if (nameIn(outdated, h.name)) continue;
        if (!first) w.raw(",");
        first = false;
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeNameGuard(&cmd_w, &q_buf, "pip show ", "pip uninstall -y --user ", h.name);
        jsonbuf.writeGlobal(&w, h.name, h.current, cmd_w.slice(), "pip");
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
            guard.writeNameGuard(&w, &q_buf, "pip show ", "pip uninstall -y --user ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pip user-site packages?\",\"body\":\"Top-level user-site packages (pip list --user --not-required). Dependencies stay off Packages. Outdated rows are report-only. Named uninstall waits for confirm.\"}");
    note.write(&w);
    w.raw("}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn runQuery(cmds: []const []const u8, buf: []u8) i32 {
    for (cmds) |cmd| {
        const n = host_exec.run(cmd, buf);
        if (n <= 0) {
            note.add(cmd, n);
            continue;
        }
        const body = std.mem.trimStart(u8, buf[0..@intCast(n)], " \t\r\n");
        if (body.len > 0 and body[0] == '[') return n;
    }
    return host_exec.fail;
}

fn query_impl(present: i32) i32 {
    note = .{};
    if (present == 0) {
        @memcpy(result_buf[0..none_json.len], none_json);
        result_nbytes = @intCast(none_json.len);
        return 0;
    }
    var globals: [128]PipOutdated = undefined;
    var n_glob: usize = 0;
    const nlist = runQuery(&list_cmds, &exec_buf);
    if (nlist >= 0) n_glob = parsePipOutdatedJSON(exec_buf[0..@intCast(nlist)], &globals);
    note.addTruncatedRows(n_glob, globals.len);

    var outdated: [128]PipOutdated = undefined;
    var n_out: usize = 0;
    const nq = runQuery(&outdated_cmds, &exec_out_buf);
    if (nq >= 0) n_out = parsePipOutdatedJSON(exec_out_buf[0..@intCast(nq)], &outdated);
    note.addTruncatedRows(n_out, outdated.len);

    return note.renderShrinkingPair(renderPip, &outdated, &n_out, &globals, &n_glob);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
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
    try std.testing.expect(renderPip(&.{}, &hits));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "pkg-00") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pkg-79") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip uninstall -y --user pkg-00") != null);
}

test "plugin_query present JSON comes from pip list --user --outdated fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip uninstall -y --user httpie") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if pip show httpie; then pip uninstall -y --user httpie; fi") != null);
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
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip missing") != null);
}

test "parsePipOutdatedJSON does not carry a field across elements" {
    var buf: [4]PipOutdated = undefined;
    const text =
        \\[{"name":"a","version":"1.0","latest_version":"2.0"},{"name":"b","latest_version":"3.0"}]
    ;
    const n = parsePipOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("a", buf[0].name);
    try std.testing.expectEqualStrings("1.0", buf[0].current);
    try std.testing.expectEqualStrings("b", buf[1].name);
    try std.testing.expectEqualStrings("", buf[1].current);
    try std.testing.expectEqualStrings("3.0", buf[1].latest);
}

// Seeds are what `pip list --user --outdated --format=json` prints: a compact
// row set, the pretty-printed form pip falls back to when the listing is long,
// an element that leaves a field out (the shape that proved the per-element
// reset), and one carrying a `latest_filetype` the parser skips. The rest are
// the ways this manifest arrives broken: cut mid-string, an element that is not
// an object, a document that is not an array, escapes, and names the command
// guard has to reject.
const fuzz_pip_rows = packFuzzSlice(
    \\[{"name":"requests","version":"2.28.1","latest_version":"2.32.3","latest_filetype":"wheel"},{"name":"urllib3","version":"1.26.18","latest_version":"2.2.2"}]
);
const fuzz_pip_pretty = packFuzzSlice(
    \\[
    \\  {"name": "backports.zoneinfo", "version": "0.2.1", "latest_version": "0.2.2"},
    \\  {"name": "zope.interface", "version": "5.0", "latest_version": "6.0", "latest_filetype": "sdist"}
    \\]
);
const fuzz_pip_missing_field = packFuzzSlice(
    \\[{"name":"a","version":"1.0","latest_version":"2.0"},{"name":"b","latest_version":"3.0"},{"name":"c","version":"4.0"}]
);
const fuzz_pip_truncated = packFuzzSlice(
    \\[{"name":"requests","version":"2.28.1","latest_version":"2.32
);
const fuzz_pip_unsafe = packFuzzSlice(
    \\[{"name":"requests;rm -rf /","version":"1","latest_version":"2"},{"name":"../../etc/passwd","version":"1"},{"name":"-x","version":"1"}]
);
const fuzz_pip_shapes = packFuzzSlice(
    \\{"name":"not-an-array"}
    \\[]
    \\[1,2,3]
    \\[null,"str",[{"name":"nested"}],{"name":123}]
);
const fuzz_pip_escapes = packFuzzSlice("[{\"name\":\"a\\\"b\",\"version\":\"1\\n2\"}]");
const fuzz_pip_junk = packFuzzSlice("not json [ { \x00\xff\r\n \t ]");
const fuzz_pip_empty = packFuzzSlice("");

test "fuzz parsePipOutdatedJSON" {
    try std.testing.fuzz({}, fuzzPipOutdatedJson, .{ .corpus = &.{
        &fuzz_pip_rows,
        &fuzz_pip_pretty,
        &fuzz_pip_missing_field,
        &fuzz_pip_truncated,
        &fuzz_pip_unsafe,
        &fuzz_pip_shapes,
        &fuzz_pip_escapes,
        &fuzz_pip_junk,
        &fuzz_pip_empty,
    } });
}

/// Every field of a reported row reaches the result JSON, and the name also
/// reaches a `pip uninstall -y --user <name>` line, so a row has to carry a
/// name the command ident guard accepts, and every field has to be a slice of
/// this input rather than a rebuilt or a dead buffer. Elements are read one at
/// a time, so a value nested inside one must not be read as the next element's
/// field: reading the same text twice has to give the same rows.
fn fuzzPipOutdatedJson(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var buf: [32]PipOutdated = undefined;
    const n = parsePipOutdatedJSON(text, &buf);
    try std.testing.expect(n <= buf.len);
    for (buf[0..n]) |row| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(row.name));
        try std.testing.expect(sliceInside(text, row.name));
        try std.testing.expect(sliceInside(text, row.current));
        try std.testing.expect(sliceInside(text, row.latest));
        // A field is a whole string token, so none keeps the quoting around it.
        try std.testing.expect(std.mem.indexOfScalar(u8, row.name, '"') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, row.name, '\\') == null);
    }

    var again: [32]PipOutdated = undefined;
    const n2 = parsePipOutdatedJSON(text, &again);
    try std.testing.expectEqual(n, n2);
    for (buf[0..n], again[0..n2]) |a, b| {
        try std.testing.expect(std.mem.eql(u8, a.name, b.name));
        try std.testing.expect(std.mem.eql(u8, a.current, b.current));
        try std.testing.expect(std.mem.eql(u8, a.latest, b.latest));
    }
}
