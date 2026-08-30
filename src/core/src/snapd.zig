const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");
const listing = @import("path_listing.zig");

const plugin_id = "snapd";
const query_cmd = "snap list --all";
const snap_home_cmd = "ls -1 /home/user/snap";
const snap_home_root = "/home/user/snap";

pub const DisabledRev = struct {
    name: []const u8,
    revision: []const u8,
};

fn notesHasDisabled(notes: []const u8) bool {
    var it = std.mem.splitScalar(u8, notes, ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "disabled")) return true;
    }
    return false;
}

/// Parse `snap list --all` text. Only rows whose Notes include `disabled`.
/// `out` holds slices into `text`. Returns count written.
pub fn parseSnapListAll(text: []const u8, out: []DisabledRev) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "Name")) continue;
        _ = it.next() orelse continue;
        const rev = it.next() orelse continue;
        var notes: []const u8 = "";
        while (it.next()) |tok| notes = tok;
        if (!notesHasDisabled(notes)) continue;
        if (!jsonbuf.isSafeIdent(name) or !jsonbuf.isSafeIdent(rev)) continue;
        out[n] = .{ .name = name, .revision = rev };
        n += 1;
    }
    return n;
}

fn nameInList(name: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Unique snap names with at least one non-disabled revision in `snap list --all`.
pub fn parseInstalledSnapNames(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "Name")) continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        var notes: []const u8 = "";
        while (it.next()) |tok| notes = tok;
        if (notesHasDisabled(notes)) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        if (nameInList(name, out[0..n])) continue;
        out[n] = name;
        n += 1;
    }
    return n;
}

fn keepFromNames(names: []const []const u8, buf: []u8) []const u8 {
    var used: usize = 0;
    for (names) |name| {
        if (used != 0) {
            if (used >= buf.len) break;
            buf[used] = '\n';
            used += 1;
        }
        if (used + name.len > buf.len) break;
        @memcpy(buf[used..][0..name.len], name);
        used += name.len;
    }
    return buf[0..used];
}

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;
var snap_home_exec_buf: [2048]u8 = undefined;

const none_json =
    \\{"plugin":"snapd","engine":null,"findings":[],"script":null,"dialog":{"title":"No snapd","body":"snap is not on PATH. Plugin inactive."},"note":"snapd missing"}
;

const snap_list_all_fixture =
    \\Name     Version                     Rev    Tracking         Publisher     Notes
    \\bare     1.0                         5      latest/stable    canonical**   base
    \\core22   20240111                    1122   latest/stable    canonical*    base
    \\core22   20231123                    1033   latest/stable    canonical*    disabled
    \\chromium 120.0.6099.224              1846   latest/stable    canonical**   disabled
    \\core20   20230622                    1974   latest/stable    canonical**   base,disabled
    \\firefox  129.0                       4336   latest/stable    mozilla**     -
    \\
;

fn renderSnapd(
    disabled: []const DisabledRev,
    orphans: []const listing.Orphan,
) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"snapd\",\"engine\":\"snap\",\"findings\":[");
    var first = true;
    for (disabled) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"disabled-revision\",\"id\":\"");
        w.raw(h.name);
        w.raw("_");
        w.raw(h.revision);
        w.raw("\",\"name\":");
        w.str(h.name);
        w.raw(",\"revision\":");
        w.str(h.revision);
        w.raw(",\"status\":\"orphaned\",\"command\":\"snap remove ");
        w.raw(h.name);
        w.raw(" --revision ");
        w.raw(h.revision);
        w.raw("\"}");
    }
    for (orphans) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"orphan-dir\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"rootLabel\":\"snap\",\"status\":\"orphaned\",\"command\":\"rm -rf ");
        w.raw(h.path);
        w.raw("\"}");
    }
    w.raw("],\"script\":");
    if (disabled.len == 0 and orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic snapd. Review before running.\\n");
        for (disabled) |h| {
            w.raw("snap remove ");
            w.raw(h.name);
            w.raw(" --revision ");
            w.raw(h.revision);
            w.raw("\\n");
        }
        for (orphans) |h| {
            w.raw("rm -rf ");
            w.raw(h.path);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove snap leftovers?\",\"body\":\"Named disabled revisions and orphan ~/snap dirs only. Installed snap apps stay on Stale Apps. Nothing runs until you confirm.\"}}");
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
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec < 0) {
        if (!renderSnapd(&.{}, &.{})) return 1;
        return 0;
    }
    const snap_text = exec_buf[0..@intCast(nexec)];
    var disabled: [32]DisabledRev = undefined;
    const n_disabled = parseSnapListAll(snap_text, &disabled);

    var installed_names: [64][]const u8 = undefined;
    const n_installed = parseInstalledSnapNames(snap_text, installed_names[0..]);
    var keep_buf: [512]u8 = undefined;
    const keep = keepFromNames(installed_names[0..n_installed], &keep_buf);

    var orphans: [32]listing.Orphan = undefined;
    var paths: [1024]u8 = undefined;
    var n_orphans: usize = 0;
    const nls = host_exec.run(snap_home_cmd, &snap_home_exec_buf);
    if (nls >= 0) {
        n_orphans = listing.parseListing(
            snap_home_exec_buf[0..@intCast(nls)],
            keep,
            snap_home_root,
            &orphans,
            &paths,
        );
    }

    if (!renderSnapd(disabled[0..n_disabled], orphans[0..n_orphans])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseSnapListAll keeps disabled revisions only" {
    var buf: [8]DisabledRev = undefined;
    const n = parseSnapListAll(snap_list_all_fixture, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("core22", buf[0].name);
    try std.testing.expectEqualStrings("1033", buf[0].revision);
    try std.testing.expectEqualStrings("chromium", buf[1].name);
    try std.testing.expectEqualStrings("1846", buf[1].revision);
    try std.testing.expectEqualStrings("core20", buf[2].name);
    try std.testing.expectEqualStrings("1974", buf[2].revision);
}

test "parseInstalledSnapNames keeps active snaps only" {
    var buf: [16][]const u8 = undefined;
    const n = parseInstalledSnapNames(snap_list_all_fixture, buf[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("bare", buf[0]);
    try std.testing.expectEqualStrings("core22", buf[1]);
    try std.testing.expectEqualStrings("firefox", buf[2]);
}

test "parseSnapListAll empty and header-only" {
    var buf: [4]DisabledRev = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseSnapListAll("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseSnapListAll("Name Version Rev Tracking Publisher Notes\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseSnapListAll("firefox  129.0  4336  latest/stable  mozilla**  -\n", &buf));
}

test "plugin_query present JSON comes from snap list --all fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"snapd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "disabled-revision") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "chromium") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1846") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1033") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "snap remove chromium --revision 1846") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "orphan-dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf /home/user/snap/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/snap/firefox") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "snap remove --purge") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /usr/bin/snap") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
