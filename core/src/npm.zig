const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

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
        plugin_abi.publishMissing(result_buf[0..], &result_nbytes, none_json);
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

const fuzz_deps_object = fuzzsupport.packFuzzSlice(
    \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
);
const fuzz_deps_array = fuzzsupport.packFuzzSlice(
    \\[{"dependencies":{"nx":{"version":"19.0.0"}}}]
);
const fuzz_deps_scoped = fuzzsupport.packFuzzSlice(
    \\{"dependencies":{"@vue/cli":{"version":"5.0.8"}}}
);
const fuzz_deps_outdated = fuzzsupport.packFuzzSlice(
    \\[{"name":"typescript","current":"5.4.5","wanted":"5.4.5","latest":"5.5.0"}]
);
const fuzz_deps_long_versions = fuzzsupport.packFuzzSlice(
    \\{"dependencies":{"a":{"version":"000000000000000000000000000000001.0.0-rc.1+b.2"}}}
);
const fuzz_deps_quotes = fuzzsupport.packFuzzSlice(
    \\{"name":"ab","dependencies":{"c":{"version":"1.2.3-rc.1+b.2"},"@scope/d":{"version":"0.0.1"}}}
);
const fuzz_deps_truncated = fuzzsupport.packFuzzSlice("{\"dependencies\":{\"a\":{\"version\":\"1");
const fuzz_deps_not_json = fuzzsupport.packFuzzSlice("not json {{{ \x00\xff");
const fuzz_deps_empty = fuzzsupport.packFuzzSlice("");
const fuzz_deps_nulls = fuzzsupport.packFuzzSlice("{\"dependencies\":{\"a\":null,\"b\":1,\"c\":true}}");
// A listing at the parse bound with the longest versions the scanner will hand
// back: `renderNpm` writes every row twice, once as a finding and once as a
// script line, so this is the widest document the render is handed for a
// normal scan and exercises `writeRowGuard` and the shrinker at that width.
const fuzz_deps_overflow = blk: {
    var text: [40 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(text[0 .. 128 * (32 + 200)]);
    w.writeAll("{\"dependencies\":{") catch unreachable;
    for (0..128) |row| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "pkg-{d:0>4}", .{row}) catch unreachable;
        w.print("\"{s}\":{{\"version\":\"{s}\"}}", .{ name, "-" ** 200 }) catch unreachable;
        w.writeAll(if (row == 127) "}}" else ",") catch unreachable;
    }
    break :blk fuzzsupport.packFuzzSlice(text[0..w.end]);
};

test "fuzz npm renders a parseable document from whatever npm ls -g prints" {
    try std.testing.fuzz({}, fuzzNpmRender, .{ .corpus = &.{
        &fuzz_deps_object,
        &fuzz_deps_array,
        &fuzz_deps_scoped,
        &fuzz_deps_outdated,
        &fuzz_deps_long_versions,
        &fuzz_deps_quotes,
        &fuzz_deps_truncated,
        &fuzz_deps_not_json,
        &fuzz_deps_empty,
        &fuzz_deps_nulls,
        &fuzz_deps_overflow,
    } });
}

/// The trust boundary this covers is the whole of the npm plugin: what
/// `npm ls -g --json` and `npm outdated -g --json` printed is untrusted, and
/// it becomes the rows the confirm dialog shows and the commands the script
/// runs. `jsonscan.zig`'s parser fuzz already covers the parse half; what it
/// cannot see is the render half — whether the document coming out the other
/// end is JSON a UI can read, and whether a list trimmed to fit the result
/// buffer says it was trimmed rather than reading as the whole machine.
///
/// So the harness states those as assertions. A crash here is not the risk; a
/// silently-truncated or unparseable result is.
fn fuzzNpmRender(_: void, smith: *std.testing.Smith) !void {
    var raw: [8192]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var hits: [128]jsonscan.Dep = undefined;
    var n: usize = parseNpmGlobalList(text, &hits);
    const parsed_deps = n;
    var outdated: [128]jsonscan.NamedVer = undefined;
    var n_out: usize = jsonscan.parseJsonNamedOutdated(text, &outdated);
    const parsed_out = n_out;

    note = .{};
    // 0 means the render fitted. 1 means both lists were trimmed to nothing
    // and it still did not, which is the one path that must not publish: a
    // returned document there would be whatever the last failed write left.
    const rc = note.renderShrinkingPair(renderNpm, &hits, &n, &outdated, &n_out);
    if (rc != 0) {
        try std.testing.expectEqual(@as(usize, 0), n);
        try std.testing.expectEqual(@as(usize, 0), n_out);
        return;
    }

    const json = result_buf[0..result_nbytes];
    try std.testing.expect(result_nbytes <= result_buf.len);
    // The document the UI parses. A version or name carrying a quote, a
    // backslash or a control byte is what makes this fail: it reaches
    // `writeGlobal` and `writeOutdated`, which JSON-escape into the same buffer
    // the rest of the document is written into.
    try std.testing.expect(jsonbuf.isValidJson(json));
    // It is this plugin's document, so a failed write cannot pass as another
    // plugin's answer.
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"plugin\":\"npm\""));

    // Shrinking is recorded, not silent: a list that lost rows names the loss.
    if (n < parsed_deps or n_out < parsed_out) {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"note\":\"") != null);
    }

    // Every name the document carries came through the parser's own gate, so
    // nothing outside the safe package-name class reaches a command.
    for (hits[0..n]) |h| {
        try std.testing.expect(jsonbuf.isSafePkgName(h.name));
    }
    for (outdated[0..n_out]) |h| {
        try std.testing.expect(jsonbuf.isSafePkgName(h.name));
    }
}
