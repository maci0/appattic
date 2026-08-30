const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "apt";
const query_cmd = "apt-get -s autoremove";
const outdated_cmd = "apt list --upgradable";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;
var exec_up_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"apt","engine":null,"findings":[],"script":null,"dialog":{"title":"No apt","body":"apt is not on PATH. Plugin inactive."},"note":"apt missing"}
;

pub const AptOrphan = struct {
    name: []const u8,
    version: []const u8,
};

pub const AptOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

/// Parse `apt list --upgradable`.
pub fn parseAptUpgradable(text: []const u8, out: []AptOutdated) usize {
    const marker = "[upgradable from:";
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const m = std.mem.indexOf(u8, line, marker) orelse continue;
        var current = std.mem.trim(u8, line[m + marker.len ..], " \t");
        if (current.len > 0 and current[current.len - 1] == ']') {
            current = std.mem.trim(u8, current[0 .. current.len - 1], " \t");
        }
        if (current.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const first = it.next() orelse continue;
        const slash = std.mem.indexOfScalar(u8, first, '/') orelse continue;
        const name = first[0..slash];
        if (!jsonbuf.isSafeIdent(name)) continue;
        const latest = it.next() orelse continue;
        out[n] = .{ .name = name, .current = current, .latest = latest };
        n += 1;
    }
    return n;
}

/// Parse `apt-get -s autoremove` dry-run text. Keeps `Remv name [version]` rows.
pub fn parseAptAutoremove(text: []const u8, out: []AptOrphan) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Remv ")) continue;
        var it = std.mem.tokenizeAny(u8, line["Remv ".len..], " \t");
        const name = it.next() orelse continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        var version: []const u8 = "";
        if (it.next()) |tok| {
            if (tok.len >= 2 and tok[0] == '[' and tok[tok.len - 1] == ']') {
                version = tok[1 .. tok.len - 1];
            }
        }
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

fn renderApt(orphans: []const AptOrphan, outdated: []const AptOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"apt\",\"engine\":\"apt\",\"findings\":[");
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
        w.raw(",\"status\":\"orphaned\",\"command\":\"apt-get purge -y ");
        w.raw(h.name);
        w.raw("\",\"manager\":\"apt\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "apt", "apt install --only-upgrade ");
    }
    w.raw("],\"script\":");
    if (orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic apt. Review before running.\\n");
        for (orphans) |h| {
            w.raw("apt-get purge -y ");
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove apt orphans?\",\"body\":\"Named autoremove leaves only. Outdated packages are report-only. Named apt install --only-upgrade waits for confirm. Nothing runs until you confirm.\"}}");
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
    var orphans: [32]AptOrphan = undefined;
    var n_orph: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec >= 0) n_orph = parseAptAutoremove(exec_buf[0..@intCast(nexec)], &orphans);

    var outdated: [32]AptOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_up_buf);
    if (nq >= 0) n_out = parseAptUpgradable(exec_up_buf[0..@intCast(nq)], &outdated);

    if (!renderApt(orphans[0..n_orph], outdated[0..n_out])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseAptAutoremove Remv lines" {
    var buf: [8]AptOrphan = undefined;
    const text =
        \\Reading package lists... Done
        \\The following packages will be REMOVED:
        \\  libfoo0 libbar1
        \\0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.
        \\Remv libfoo0 [1.2.3]
        \\Remv libbar1 [2.0.0]
        \\
    ;
    const n = parseAptAutoremove(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("libfoo0", buf[0].name);
    try std.testing.expectEqualStrings("1.2.3", buf[0].version);
    try std.testing.expectEqualStrings("libbar1", buf[1].name);
    try std.testing.expectEqualStrings("2.0.0", buf[1].version);
}

test "parseAptAutoremove skips empty and summary" {
    var buf: [4]AptOrphan = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseAptAutoremove("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseAptAutoremove("Reading package lists... Done\n0 upgraded, 0 newly installed, 0 to remove\n", &buf),
    );
}

test "plugin_query present JSON comes from apt-get -s autoremove fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"apt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libbar1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt-get purge -y libfoo0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt upgrade") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dist-upgrade") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt missing") != null);
}

test "plugin_query present JSON includes apt list --upgradable outdated" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1:2.39.2-1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1:2.39.5-0+deb12u2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt install --only-upgrade git") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt upgrade") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dist-upgrade") == null);
}

test "parseAptUpgradable name current latest" {
    var buf: [8]AptOutdated = undefined;
    const text =
        \\Listing...
        \\git/stable 1:2.39.5-0+deb12u2 amd64 [upgradable from: 1:2.39.2-1.1]
        \\code/stable 1.90.2-1718 amd64 [upgradable from: 1.90.0-1600]
        \\
    ;
    const n = parseAptUpgradable(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("git", buf[0].name);
    try std.testing.expectEqualStrings("1:2.39.2-1.1", buf[0].current);
    try std.testing.expectEqualStrings("1:2.39.5-0+deb12u2", buf[0].latest);
    try std.testing.expectEqualStrings("code", buf[1].name);
    try std.testing.expectEqualStrings("1.90.2-1718", buf[1].latest);
}

test "parseAptUpgradable skips empty listing" {
    var buf: [4]AptOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseAptUpgradable("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseAptUpgradable("Listing...\n", &buf));
}
