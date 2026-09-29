const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "pacman";
const query_cmd = "pacman -Qdt";
const outdated_cmd = "pacman -Qu";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var exec_up_buf: [65536]u8 = undefined;

const none_json =
    \\{"plugin":"pacman","engine":null,"findings":[],"script":null,"dialog":{"title":"No pacman","body":"pacman is not on PATH. Plugin inactive."},"note":"pacman missing"}
;

pub const PacmanOrphan = struct {
    name: []const u8,
    version: []const u8,
};

pub const PacmanOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

/// Parse `pacman -Qu` (name current -> latest). Exit 0 and 1 both parseable.
pub fn parsePacmanQu(text: []const u8, out: []PacmanOutdated) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "error:") or std.mem.startsWith(u8, line, "warning:")) continue;
        const arrow = std.mem.indexOf(u8, line, " -> ") orelse continue;
        var left = std.mem.tokenizeAny(u8, line[0..arrow], " \t");
        const name = left.next() orelse continue;
        const current = left.next() orelse continue;
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
        var right = std.mem.tokenizeAny(u8, line[arrow + 4 ..], " \t");
        const latest = right.next() orelse continue;
        out[n] = .{ .name = name, .current = current, .latest = latest };
        n += 1;
    }
    return n;
}

/// Parse `pacman -Qdt` (name version) or `pacman -Qqdt` (name only).
pub fn parsePacmanQdt(text: []const u8, out: []PacmanOrphan) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "error:") or std.mem.startsWith(u8, line, "warning:")) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
        const version = it.next() orelse "";
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

fn renderPacman(orphans: []const PacmanOrphan, outdated: []const PacmanOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"pacman\",\"engine\":\"pacman\",\"findings\":[");
    var first = true;
    for (orphans) |h| {
        if (!first) w.raw(",");
        first = false;
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeNameGuard(&cmd_w, &q_buf, "pacman -Qq ", "pacman --noconfirm -Rns ", h.name);
        w.raw("{\"kind\":\"orphan\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.version.len > 0) {
            w.raw(",\"version\":");
            w.str(h.version);
        }
        w.raw(",\"status\":\"orphaned\",\"command\":");
        w.str(cmd_w.slice() orelse {
            w.failed = true;
            return false;
        });
        w.raw(",\"manager\":\"pacman\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeUpgradeGuard(&cmd_w, &q_buf, "pacman -Qu", "pacman --noconfirm -S", h.name);
        const cmd = cmd_w.slice() orelse {
            w.failed = true;
            return false;
        };
        jsonbuf.writeOutdatedCommand(&w, h.name, h.current, h.latest, "pacman", cmd, true);
    }
    w.raw("],\"script\":");
    if (orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic pacman. Review before running.\\n");
        for (orphans) |h| {
            guard.writeNameGuard(&w, &q_buf, "pacman -Qq ", "pacman --noconfirm -Rns ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pacman orphans?\",\"body\":\"Named -Qdt leaves only. Named pacman -S waits for confirm. Not a full system upgrade. Nothing runs until you confirm.\"}");
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
    var orphans: [128]PacmanOrphan = undefined;
    var n_orph: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec >= 0) n_orph = parsePacmanQdt(exec_buf[0..@intCast(nexec)], &orphans);
    note.addTruncatedRows(n_orph, orphans.len);

    var outdated: [128]PacmanOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_up_buf);
    note.add(outdated_cmd, nq);
    if (nq >= 0) n_out = parsePacmanQu(exec_up_buf[0..@intCast(nq)], &outdated);
    note.addTruncatedRows(n_out, outdated.len);

    return note.renderShrinkingPair(renderPacman, &orphans, &n_orph, &outdated, &n_out);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "parsePacmanQdt name version and quiet" {
    var buf: [8]PacmanOrphan = undefined;
    const n = parsePacmanQdt("libfoo 1.2.3-1\nlibbar 2.0.0-1\n", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("1.2.3-1", buf[0].version);
    try std.testing.expectEqualStrings("libbar", buf[1].name);
    try std.testing.expectEqualStrings("2.0.0-1", buf[1].version);

    const q = parsePacmanQdt("libfoo\nlibbar\n", &buf);
    try std.testing.expectEqual(@as(usize, 2), q);
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("", buf[0].version);
}

test "parsePacmanQdt skips error warning empty" {
    var buf: [4]PacmanOrphan = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePacmanQdt("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePacmanQdt("error: no orphans\nwarning: db\n", &buf));
    const n = parsePacmanQdt("error: skip me\nlibfoo 1-1\nwarning: x\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
}

test "plugin_query present JSON comes from pacman -Qdt fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pacman\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.2.3-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libbar") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pacman --noconfirm -Rns libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if pacman -Qq libfoo; then pacman --noconfirm -Rns libfoo; fi") != null);
    // The script line is guarded too, not just the row command: the script runs
    // under `set -e`, and `pacman -Rns` on a package a previous run removed
    // exits nonzero and strands every orphan listed after it.
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "# AppAttic pacman. Review before running.\\nif pacman -Qq libfoo; then pacman --noconfirm -Rns libfoo; fi\\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "-Syu") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}

test "plugin_query present JSON includes pacman -Qu outdated" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "coreutils") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "9.5-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "9.5-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pacman --noconfirm -S coreutils") != null);
    // Guarded, so a script that runs twice does not reinstall the package:
    // `pacman -S` on a package already at the scanned version is a reinstall.
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "if pacman -Qu coreutils >/dev/null 2>&1; then pacman --noconfirm -S coreutils; fi",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "-Syu") == null);
}

test "parsePacmanQu name current latest and ignored" {
    var buf: [8]PacmanOutdated = undefined;
    const text =
        \\coreutils 9.5-1 -> 9.5-2
        \\firefox 129.0-1 -> 129.0.1-1
        \\linux 6.10.5.arch1-1 -> 6.10.6.arch1-1 [ignored]
        \\
    ;
    const n = parsePacmanQu(text, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("coreutils", buf[0].name);
    try std.testing.expectEqualStrings("9.5-1", buf[0].current);
    try std.testing.expectEqualStrings("9.5-2", buf[0].latest);
    try std.testing.expectEqualStrings("firefox", buf[1].name);
    try std.testing.expectEqualStrings("129.0.1-1", buf[1].latest);
    try std.testing.expectEqualStrings("linux", buf[2].name);
    try std.testing.expectEqualStrings("6.10.6.arch1-1", buf[2].latest);
}

test "parsePacmanQu skips empty error warning" {
    var buf: [4]PacmanOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePacmanQu("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePacmanQu("error: failed\nwarning: db\n", &buf));
}

// Seeds are `pacman -Qdt` and `pacman -Qu` output, plus the rows that break a
// hand-rolled tokenizer: the arrow with nothing after it, a row carrying only
// the name, and the `error:`/`warning:` lines the tool prints on the same
// stream as its results.
const fuzz_pacman_qdt = packFuzzSlice(
    \\libfoo 6.0.1-1
    \\libbar
    \\warning: database file 'local' is missing or unreadable
    \\error: failed to init transaction (invalid or corrupted repo (detected))
);
const fuzz_pacman_qu = packFuzzSlice(
    \\libfoo 6.0.0-1 -> 6.0.1-1
    \\libbar 0.1-1 -> 0.2-1 [ignored]
    \\error: could not open
);
const fuzz_pacman_broken = packFuzzSlice(
    \\libfoo -> 
    \\ -> 1.0
    \\libfoo ->
    \\libfoo 1.0 ->
);
const fuzz_pacman_unsafe = packFuzzSlice(
    \\libfoo;rm -rf / 1.0
    \\$(id) 1.0 -> 2.0
    \\../../etc 1.0-1 -> 2.0-1
);
const fuzz_pacman_junk = packFuzzSlice("libfoo\x00\x01 1.0\r\n\xff\xfe");
const fuzz_pacman_empty = packFuzzSlice("");

test "fuzz pacman listing parsers" {
    try std.testing.fuzz({}, fuzzPacmanListings, .{ .corpus = &.{
        &fuzz_pacman_qdt,
        &fuzz_pacman_qu,
        &fuzz_pacman_broken,
        &fuzz_pacman_unsafe,
        &fuzz_pacman_junk,
        &fuzz_pacman_empty,
    } });
}

/// Both parsers cut names that reach `pacman -R` lines, so a name must pass
/// `jsonbuf.isSafeCmdIdent`, the stricter rule that also rejects a leading `-`,
/// and every field must be a slice of the input. The version of
/// a `-Qdt` row is optional, but a `-Qu` row needs all three fields.
fn fuzzPacmanListings(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var orphans: [32]PacmanOrphan = undefined;
    const nord = parsePacmanQdt(text, &orphans);
    try std.testing.expect(nord <= orphans.len);
    for (orphans[0..nord]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(sliceInside(text, o.version));
    }

    var outdated: [32]PacmanOutdated = undefined;
    const nout = parsePacmanQu(text, &outdated);
    try std.testing.expect(nout <= outdated.len);
    for (outdated[0..nout]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(sliceInside(text, o.current));
        try std.testing.expect(sliceInside(text, o.latest));
        // A `-Qu` row is only reported when both sides of the arrow tokenize,
        // so no field may be empty.
        try std.testing.expect(o.current.len > 0);
        try std.testing.expect(o.latest.len > 0);
    }

    var orphans2: [32]PacmanOrphan = undefined;
    try std.testing.expectEqual(nord, parsePacmanQdt(text, &orphans2));
}

// `pacman -Qqdt` prints names with no version at all, so a row of one field
// is a result, not a partial line.
test "parsePacmanQdt accepts a bare name" {
    var buf: [8]PacmanOrphan = undefined;
    try std.testing.expectEqual(@as(usize, 1), parsePacmanQdt("libfoo\n", &buf));
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("", buf[0].version);
}
