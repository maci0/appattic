const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "composer";
const query_cmd = "composer global outdated";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [32768]u8 = undefined;

const none_json =
    \\{"plugin":"composer","engine":null,"findings":[],"script":null,"dialog":{"title":"No composer","body":"composer is not on PATH. Plugin inactive."},"note":"composer missing"}
;

pub const ComposerOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

fn isStatusMark(s: []const u8) bool {
    return std.mem.eql(u8, s, "!") or std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "=");
}

/// Parse `composer global outdated` text. Rows look like
/// `laravel/installer 5.8.0 ! 5.10.0 Laravel application installer`.
/// Legend and section headers go to stderr. Global composer.json only.
pub fn parseComposerOutdated(text: []const u8, out: []ComposerOutdated) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (!jsonbuf.isSafeComposerName(name)) continue;
        const current = it.next() orelse continue;
        const mid = it.next() orelse continue;
        const latest = if (isStatusMark(mid)) (it.next() orelse continue) else mid;
        if (!jsonbuf.isSafeIdent(current) or !jsonbuf.isSafeIdent(latest)) continue;
        out[n] = .{ .name = name, .current = current, .latest = latest };
        n += 1;
    }
    return n;
}

fn renderComposer(hits: []const ComposerOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"composer\",\"engine\":\"composer\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "composer", "composer global update ", false);
    }
    w.raw("],\"script\":null");
    w.raw(",\"dialog\":{\"title\":\"Outdated Composer globals?\",\"body\":\"Global composer.json packages only. Not project vendor. Report-only. Named composer global update waits for confirm. AppAttic does not run this upgrade.\"}}");
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
        if (!renderComposer(&.{})) return 1;
        return 0;
    }
    var hits: [128]ComposerOutdated = undefined;
    var n = parseComposerOutdated(exec_buf[0..@intCast(nexec)], &hits);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderComposer, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "parseComposerOutdated name current latest" {
    var buf: [8]ComposerOutdated = undefined;
    const text =
        \\laravel/installer 5.8.0 ! 5.10.0 Laravel application installer
        \\phpunit/phpunit 9.6.19 ~ 11.3.0 The PHP Unit Testing framework.
        \\
    ;
    const n = parseComposerOutdated(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("laravel/installer", buf[0].name);
    try std.testing.expectEqualStrings("5.8.0", buf[0].current);
    try std.testing.expectEqualStrings("5.10.0", buf[0].latest);
    try std.testing.expectEqualStrings("phpunit/phpunit", buf[1].name);
    try std.testing.expectEqualStrings("9.6.19", buf[1].current);
    try std.testing.expectEqualStrings("11.3.0", buf[1].latest);
}

test "parseComposerOutdated padded columns and no status mark" {
    var buf: [4]ComposerOutdated = undefined;
    const text =
        \\laravel/installer  5.8.0  !  5.10.0  Laravel application installer
        \\phpunit/phpunit    9.6.19    11.3.0  The PHP Unit Testing framework.
        \\
    ;
    const n = parseComposerOutdated(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("laravel/installer", buf[0].name);
    try std.testing.expectEqualStrings("5.10.0", buf[0].latest);
    try std.testing.expectEqualStrings("phpunit/phpunit", buf[1].name);
    try std.testing.expectEqualStrings("11.3.0", buf[1].latest);
}

test "parseComposerOutdated empty junk skips unsafe" {
    var buf: [4]ComposerOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseComposerOutdated("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseComposerOutdated("Legend:\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseComposerOutdated("not composer output\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseComposerOutdated("foo;rm/bar 1.0 ! 2.0\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseComposerOutdated("laravel/installer 5.8.0\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseComposerOutdated("../evil 1.0 ! 2.0\n", &buf));
}

test "isSafeComposerName vendor/package" {
    try std.testing.expect(jsonbuf.isSafeComposerName("laravel/installer"));
    try std.testing.expect(jsonbuf.isSafeComposerName("phpunit/phpunit"));
    try std.testing.expect(!jsonbuf.isSafeComposerName("laravel"));
    try std.testing.expect(!jsonbuf.isSafeComposerName("@vue/cli"));
    try std.testing.expect(!jsonbuf.isSafeComposerName("foo/bar/baz"));
    try std.testing.expect(!jsonbuf.isSafeComposerName("../etc"));
    try std.testing.expect(!jsonbuf.isSafeComposerName("foo;rm/bar"));
}

test "plugin_query present JSON comes from composer global outdated fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"composer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "laravel/installer") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "5.8.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "5.10.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "phpunit/phpunit") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "composer global update laravel/installer") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"script\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "composer global remove") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "vendor/") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "composer missing") != null);
}

// `composer global outdated` rows are `name current ! latest description`,
// with the `!` status mark optional depending on the version. The seeds cover
// both shapes, the legend rows it prints, and rows cut short.
const fuzz_composer_rows = packFuzzSlice(
    \\laravel/installer 5.8.0 ! 5.10.0 Laravel application installer
    \\phpunit/phpunit 9.5.0 9.6.0 Testing framework
);
const fuzz_composer_broken = packFuzzSlice(
    \\laravel/installer
    \\laravel/installer 5.8.0 !
    \\laravel/installer 5.8.0 ! 
);
const fuzz_composer_unsafe = packFuzzSlice(
    \\foo;rm -rf / 1.0 ! 2.0
    \\foo 1.0 $(id)
    \\../../etc 1.0 2.0
);
const fuzz_composer_junk = packFuzzSlice("foo/bar 1.0\x00 ! 2.0\r\n\xff 1.0 2.0");
const fuzz_composer_empty = packFuzzSlice("");

test "fuzz parseComposerOutdated" {
    try std.testing.fuzz({}, fuzzComposerOutdated, .{ .corpus = &.{
        &fuzz_composer_rows,
        &fuzz_composer_broken,
        &fuzz_composer_unsafe,
        &fuzz_composer_junk,
        &fuzz_composer_empty,
    } });
}

fn fuzzComposerOutdated(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var buf: [32]ComposerOutdated = undefined;
    const n = parseComposerOutdated(text, &buf);
    try std.testing.expect(n <= buf.len);
    for (buf[0..n]) |o| {
        try std.testing.expect(jsonbuf.isSafeComposerName(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(sliceInside(text, o.current));
        try std.testing.expect(sliceInside(text, o.latest));
        try std.testing.expect(o.current.len > 0);
        try std.testing.expect(o.latest.len > 0);
    }
}
