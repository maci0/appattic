const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "pacman";
const query_cmd = "pacman -Qdt";
const outdated_cmd = "pacman -Qu";

var result_buf: [65536]u8 = undefined;
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
        if (!jsonbuf.isSafeIdent(name)) continue;
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
        if (!jsonbuf.isSafeIdent(name)) continue;
        const version = it.next() orelse "";
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

fn renderPacman(orphans: []const PacmanOrphan, outdated: []const PacmanOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"pacman\",\"engine\":\"pacman\",\"findings\":[");
    var first = true;
    for (orphans) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"orphan\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.version.len > 0) {
            w.raw(",\"version\":");
            w.str(h.version);
        }
        w.raw(",\"status\":\"orphaned\",\"command\":\"pacman --noconfirm -Rns ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"pacman\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "pacman", "pacman --noconfirm -S ", true);
    }
    w.raw("],\"script\":");
    if (orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic pacman. Review before running.\\n");
        for (orphans) |h| {
            w.raw("pacman --noconfirm -Rns ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove pacman orphans?\",\"body\":\"Named -Qdt leaves only. Named pacman -S waits for confirm. Not a full system upgrade. Nothing runs until you confirm.\"}}");
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
    var orphans: [128]PacmanOrphan = undefined;
    var n_orph: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec >= 0) n_orph = parsePacmanQdt(exec_buf[0..@intCast(nexec)], &orphans);

    var outdated: [128]PacmanOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_up_buf);
    if (nq >= 0) n_out = parsePacmanQu(exec_up_buf[0..@intCast(nq)], &outdated);

    while (true) {
        if (renderPacman(orphans[0..n_orph], outdated[0..n_out])) return 0;
        if (n_out > 0) {
            n_out -= 1;
            continue;
        }
        if (n_orph > 0) {
            n_orph -= 1;
            continue;
        }
        return 1;
    }
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
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
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pacman\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.2.3-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libbar") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pacman --noconfirm -Rns libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "-Syu") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}

test "plugin_query present JSON includes pacman -Qu outdated" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "coreutils") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "9.5-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "9.5-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pacman --noconfirm -S coreutils") != null);
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
