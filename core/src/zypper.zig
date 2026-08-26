const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "zypper";
const query_cmd = "zypper --non-interactive packages --unneeded";
const outdated_cmd = "zypper --non-interactive list-updates";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;
var exec_up_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"zypper","engine":null,"findings":[],"script":null,"dialog":{"title":"No zypper","body":"zypper is not on PATH. Plugin inactive."},"note":"zypper missing"}
;

pub const ZypperOrphan = struct {
    name: []const u8,
    version: []const u8,
};

pub const ZypperOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

fn splitPipeCols(line: []const u8, cols: [][]const u8) usize {
    var ncol: usize = 0;
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |col| {
        if (ncol == cols.len) break;
        cols[ncol] = std.mem.trim(u8, col, " \t");
        ncol += 1;
    }
    return ncol;
}

/// Parse `zypper --non-interactive list-updates` table.
pub fn parseZypperListUpdates(text: []const u8, out: []ZypperOutdated) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.indexOfScalar(u8, line, '|') == null) continue;
        var cols: [8][]const u8 = undefined;
        const ncol = splitPipeCols(line, &cols);
        if (ncol < 5) continue;
        const status = cols[0];
        const name = cols[2];
        if (name.len == 0) continue;
        if (status.len == 1 and (status[0] == 's' or status[0] == 'S')) continue;
        if (std.ascii.eqlIgnoreCase(name, "Name")) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .name = name, .current = cols[3], .latest = cols[4] };
        n += 1;
    }
    return n;
}

/// Parse `zypper --non-interactive packages --unneeded` table (pipe columns).
pub fn parseZypperUnneeded(text: []const u8, out: []ZypperOrphan) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.indexOfScalar(u8, line, '|') == null) continue;
        var cols: [8][]const u8 = undefined;
        const ncol = splitPipeCols(line, &cols);
        if (ncol < 4) continue;
        const name = cols[1];
        if (name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(name, "Name")) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        const version = cols[3];
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

fn renderZypper(orphans: []const ZypperOrphan, outdated: []const ZypperOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"zypper\",\"engine\":\"zypper\",\"findings\":[");
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
        w.raw(",\"status\":\"orphaned\",\"command\":\"zypper --non-interactive rm ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"zypper\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "zypper", "zypper update ");
    }
    w.raw("],\"script\":");
    if (orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic zypper. Review before running.\\n");
        for (orphans) |h| {
            w.raw("zypper --non-interactive rm ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove zypper unneeded?\",\"body\":\"Named --unneeded packages only. Outdated packages are report-only. Named zypper update waits for confirm. Nothing runs until you confirm.\"}}");
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
    var orphans: [32]ZypperOrphan = undefined;
    var n_orph: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec >= 0) n_orph = parseZypperUnneeded(exec_buf[0..@intCast(nexec)], &orphans);

    var outdated: [32]ZypperOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_up_buf);
    if (nq >= 0) n_out = parseZypperListUpdates(exec_up_buf[0..@intCast(nq)], &outdated);

    if (!renderZypper(orphans[0..n_orph], outdated[0..n_out])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseZypperUnneeded table name version" {
    var buf: [8]ZypperOrphan = undefined;
    const text =
        \\S | Name   | Type    | Version | Arch   | Repository
        \\--+--------+---------+---------+--------+-----------
        \\i | libfoo | package | 1.2.3-1 | x86_64 | repo
        \\i | libbar | package | 2.0.0-1 | x86_64 | repo
        \\
    ;
    const n = parseZypperUnneeded(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("1.2.3-1", buf[0].version);
    try std.testing.expectEqualStrings("libbar", buf[1].name);
    try std.testing.expectEqualStrings("2.0.0-1", buf[1].version);
}

test "parseZypperUnneeded skips empty and separator" {
    var buf: [4]ZypperOrphan = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseZypperUnneeded("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseZypperUnneeded("S | Name | Type | Version\n--+----+----+\n", &buf),
    );
}

test "plugin_query present JSON comes from zypper packages --unneeded fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"zypper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.2.3-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libbar") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "zypper --non-interactive rm libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "zypper dup") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "list-updates") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "zypper missing") != null);
}

test "plugin_query present JSON includes zypper list-updates outdated" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.43.0-1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.45.1-1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "zypper update git") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "zypper dup") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "list-updates") == null);
}

test "parseZypperListUpdates name current latest" {
    var buf: [8]ZypperOutdated = undefined;
    const text =
        \\Loading repository data...
        \\S | Repository | Name | Current Version | Available Version | Arch
        \\--+------------+------+-----------------+-------------------+-------
        \\v | Update     | git  | 2.43.0-1.1      | 2.45.1-1.1        | x86_64
        \\v | OSS        | vim  | 9.1-1           | 9.1-2             | x86_64
        \\
    ;
    const n = parseZypperListUpdates(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("git", buf[0].name);
    try std.testing.expectEqualStrings("2.43.0-1.1", buf[0].current);
    try std.testing.expectEqualStrings("2.45.1-1.1", buf[0].latest);
    try std.testing.expectEqualStrings("vim", buf[1].name);
    try std.testing.expectEqualStrings("9.1-2", buf[1].latest);
}

test "parseZypperListUpdates skips empty header" {
    var buf: [4]ZypperOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseZypperListUpdates("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseZypperListUpdates("S | Repository | Name | Current Version | Available Version\n--+----+----+\n", &buf),
    );
}
