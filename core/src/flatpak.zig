const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "flatpak";
const query_cmd = "flatpak uninstall --unused --dry-run";
const updates_cmd = "flatpak remote-ls --updates --app --columns=application,version";
const list_cmd = "flatpak list --app --columns=application,version";

var result_buf: [65536]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var exec_up_buf: [65536]u8 = undefined;
var exec_list_buf: [65536]u8 = undefined;

const none_json =
    \\{"plugin":"flatpak","engine":null,"findings":[],"script":null,"dialog":{"title":"No flatpak","body":"flatpak is not on PATH. Plugin inactive."},"note":"flatpak missing"}
;

pub const FlatpakUnused = struct {
    name: []const u8,
    branch: []const u8,
};

pub const FlatpakOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

fn isNumberedPrefix(t: []const u8) bool {
    if (t.len < 2 or t[t.len - 1] != '.') return false;
    for (t[0 .. t.len - 1]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isArch(t: []const u8) bool {
    return std.mem.eql(u8, t, "x86_64") or std.mem.eql(u8, t, "aarch64") or
        std.mem.eql(u8, t, "i386") or std.mem.eql(u8, t, "i686") or
        std.mem.eql(u8, t, "arm") or std.mem.eql(u8, t, "noarch") or
        std.mem.eql(u8, t, "ppc64le") or std.mem.eql(u8, t, "s390x");
}

fn skipUnusedNoise(line: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(line, "looking") or
        std.ascii.startsWithIgnoreCase(line, "nothing unused") or
        std.ascii.startsWithIgnoreCase(line, "info:") or
        std.ascii.startsWithIgnoreCase(line, "uninstalling") or
        std.ascii.startsWithIgnoreCase(line, "would");
}

fn splitRef(tok: []const u8, name: *[]const u8, branch: *[]const u8) bool {
    var it = std.mem.splitScalar(u8, tok, '/');
    const id = it.next() orelse return false;
    _ = it.next();
    const last = it.next();
    if (!jsonbuf.isSafeIdent(id)) return false;
    name.* = id;
    if (last) |b| {
        if (jsonbuf.isSafeIdent(b)) branch.* = b;
    }
    return true;
}

/// Parse `flatpak uninstall --unused --dry-run`. Numbered leftover runtimes only.
/// `flatpak list` / `remote-ls` dumps are not unused.
pub fn parseFlatpakUnused(text: []const u8, out: []FlatpakUnused) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (skipUnusedNoise(line)) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const first = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(first, "ID") or std.ascii.eqlIgnoreCase(first, "Name") or
            std.ascii.eqlIgnoreCase(first, "Application")) continue;

        var name: []const u8 = "";
        var branch: []const u8 = "";
        if (isNumberedPrefix(first)) {
            const idtok = it.next() orelse continue;
            if (std.mem.indexOfScalar(u8, idtok, '/') != null) {
                if (!splitRef(idtok, &name, &branch)) continue;
            } else {
                if (!jsonbuf.isSafeIdent(idtok) or std.mem.indexOfScalar(u8, idtok, '.') == null) continue;
                name = idtok;
            }
            while (it.next()) |tok| {
                if (tok.len == 1) continue;
                if (tok[0] == '[') continue;
                if (isArch(tok)) continue;
                if (jsonbuf.isSafeIdent(tok) and branch.len == 0) {
                    branch = tok;
                    break;
                }
            }
        } else if (std.mem.indexOfScalar(u8, first, '/') != null) {
            if (!splitRef(first, &name, &branch)) continue;
        } else {
            continue;
        }
        if (name.len == 0) continue;
        out[n] = .{ .name = name, .branch = branch };
        n += 1;
    }
    return n;
}

const FlatpakRow = struct {
    name: []const u8,
    version: []const u8,
};

fn skipFlatpakHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "application") or
        std.ascii.eqlIgnoreCase(name, "application id") or
        std.ascii.eqlIgnoreCase(name, "name") or
        std.ascii.eqlIgnoreCase(name, "id");
}

fn parseFlatpakAppRows(text: []const u8, out: []FlatpakRow) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var name: []const u8 = "";
        var version: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            var it = std.mem.splitScalar(u8, line, '\t');
            name = std.mem.trim(u8, it.next() orelse "", " ");
            version = std.mem.trim(u8, it.next() orelse "", " ");
        } else {
            var it = std.mem.tokenizeAny(u8, line, " \t");
            name = it.next() orelse continue;
            version = it.next() orelse "";
        }
        if (name.len == 0 or skipFlatpakHeader(name)) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

fn versionOf(rows: []const FlatpakRow, name: []const u8) []const u8 {
    for (rows) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.version;
    }
    return "";
}

/// `flatpak remote-ls --updates --app` plus `flatpak list --app` current versions.
pub fn parseFlatpakUpdates(updates_text: []const u8, installed_text: []const u8, out: []FlatpakOutdated) usize {
    var latest_rows: [128]FlatpakRow = undefined;
    var current_rows: [128]FlatpakRow = undefined;
    const n_latest = parseFlatpakAppRows(updates_text, &latest_rows);
    const n_cur = parseFlatpakAppRows(installed_text, &current_rows);
    var n: usize = 0;
    for (latest_rows[0..n_latest]) |row| {
        if (n == out.len) break;
        const current = versionOf(current_rows[0..n_cur], row.name);
        out[n] = .{ .name = row.name, .current = current, .latest = row.version };
        n += 1;
    }
    return n;
}

fn renderFlatpak(hits: []const FlatpakUnused, outdated: []const FlatpakOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"flatpak\",\"engine\":\"flatpak\",\"findings\":[");
    var first = true;
    for (hits) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"unused-runtime\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.branch.len > 0) {
            w.raw(",\"version\":");
            w.str(h.branch);
        }
        w.raw(",\"status\":\"orphaned\",\"command\":\"flatpak uninstall -y ");
        w.raw(h.name);
        if (h.branch.len > 0) {
            w.raw("//");
            w.raw(h.branch);
        }
        w.raw("\",\"manager\":\"flatpak\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "flatpak", "flatpak update -y ", true);
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic flatpak. Review before running.\\n");
        for (hits) |h| {
            w.raw("flatpak uninstall -y ");
            w.raw(h.name);
            if (h.branch.len > 0) {
                w.raw("//");
                w.raw(h.branch);
            }
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove unused Flatpak runtimes?\",\"body\":\"Named unused runtimes only. Named flatpak update waits for confirm. Nothing runs until you confirm.\"}}");
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
    var hits: [128]FlatpakUnused = undefined;
    var n: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec >= 0) n = parseFlatpakUnused(exec_buf[0..@intCast(nexec)], &hits);

    var outdated: [128]FlatpakOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(updates_cmd, &exec_up_buf);
    if (nq >= 0) {
        var installed: []const u8 = "";
        const nl = host_exec.run(list_cmd, &exec_list_buf);
        if (nl >= 0) installed = exec_list_buf[0..@intCast(nl)];
        n_out = parseFlatpakUpdates(exec_up_buf[0..@intCast(nq)], installed, &outdated);
    }

    while (true) {
        if (renderFlatpak(hits[0..n], outdated[0..n_out])) return 0;
        if (n_out > 0) {
            n_out -= 1;
            continue;
        }
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

test "parseFlatpakUnused numbered leftover runtimes" {
    var buf: [8]FlatpakUnused = undefined;
    const text =
        \\Looking for unused runtimes to uninstall...
        \\
        \\        ID                                             Branch    Op
        \\ 1.     org.freedesktop.Platform.GL.default            23.08     r
        \\ 2.     org.freedesktop.Platform.Locale                23.08     r
        \\
    ;
    const n = parseFlatpakUnused(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("org.freedesktop.Platform.GL.default", buf[0].name);
    try std.testing.expectEqualStrings("23.08", buf[0].branch);
    try std.testing.expectEqualStrings("org.freedesktop.Platform.Locale", buf[1].name);
    try std.testing.expectEqualStrings("23.08", buf[1].branch);
}

test "parseFlatpakUnused skips list dump and empty" {
    var buf: [4]FlatpakUnused = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseFlatpakUnused("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseFlatpakUnused("Nothing unused to uninstall\n", &buf),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        parseFlatpakUnused("org.mozilla.firefox\t128.0\tstable\tflathub\n", &buf),
    );
}

test "parseFlatpakUnused ref form after number" {
    var buf: [4]FlatpakUnused = undefined;
    const n = parseFlatpakUnused(" 1. org.freedesktop.Platform/x86_64/23.08\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("org.freedesktop.Platform", buf[0].name);
    try std.testing.expectEqualStrings("23.08", buf[0].branch);
}

test "plugin_query present JSON comes from unused fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"flatpak\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "unused-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "org.freedesktop.Platform.GL.default") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "23.08") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak uninstall -y org.freedesktop.Platform.GL.default//23.08") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak remote-ls") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "org.mozilla.firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak update -y org.mozilla.firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"current_version\":\"128.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"latest_version\":\"130.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /usr/bin/flatpak") == null);
}

test "parseFlatpakUpdates joins current from list" {
    var buf: [4]FlatpakOutdated = undefined;
    const n = parseFlatpakUpdates(
        "Application Version\norg.mozilla.firefox 130.0\n",
        "Application Version\norg.mozilla.firefox 128.0\n",
        &buf,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("org.mozilla.firefox", buf[0].name);
    try std.testing.expectEqualStrings("128.0", buf[0].current);
    try std.testing.expectEqualStrings("130.0", buf[0].latest);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "flatpak missing") != null);
}
