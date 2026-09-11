const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "dnf";
const query_cmds = [_][]const u8{
    "dnf5 repoquery --unneeded --qf %{name}",
    "dnf repoquery --unneeded --qf %{name}",
    "yum repoquery --unneeded --qf %{name}",
};
const outdated_cmds = [_][]const u8{
    "dnf5 list --upgrades",
    "dnf list --upgrades",
    "dnf5 check-update",
    "dnf check-update",
    "yum check-update",
};

var result_buf: [65536]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var exec_up_buf: [65536]u8 = undefined;

const none_json =
    \\{"plugin":"dnf","engine":null,"findings":[],"script":null,"dialog":{"title":"No dnf","body":"dnf, dnf5, or yum is not on PATH. Plugin inactive."},"note":"dnf missing"}
;

pub const DnfOrphan = struct {
    name: []const u8,
};

pub const DnfOutdated = struct {
    name: []const u8,
    latest: []const u8,
};

/// Parse `dnf list --upgrades` / `dnf check-update`. Exit 0 and 100 both parseable.
pub fn parseDnfUpgrades(text: []const u8, out: []DnfOutdated) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (skipDnfNoise(line)) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const raw_name = it.next() orelse continue;
        const latest = it.next() orelse continue;
        _ = it.next() orelse continue;
        if (!hasDigit(latest)) continue;
        const name = stripDnfArch(raw_name);
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .name = name, .latest = latest };
        n += 1;
    }
    return n;
}

fn skipDnfNoise(line: []const u8) bool {
    const low_len = @min(line.len, 32);
    var tmp: [32]u8 = undefined;
    for (line[0..low_len], 0..) |c, i| {
        tmp[i] = std.ascii.toLower(c);
    }
    const low = tmp[0..low_len];
    if (std.mem.startsWith(u8, low, "last metadata")) return true;
    if (std.mem.startsWith(u8, low, "packages")) return true;
    if (std.mem.startsWith(u8, low, "finding")) return true;
    if (std.mem.startsWith(u8, low, "available upgrade")) return true;
    if (std.mem.startsWith(u8, low, "obsoleting")) return true;
    return false;
}

fn stripDnfArch(name: []const u8) []const u8 {
    const arches = [_][]const u8{ ".x86_64", ".aarch64", ".i686", ".noarch", ".ppc64le", ".s390x" };
    for (arches) |a| {
        if (std.mem.endsWith(u8, name, a)) return name[0 .. name.len - a.len];
    }
    return name;
}

fn hasDigit(s: []const u8) bool {
    for (s) |c| {
        if (c >= '0' and c <= '9') return true;
    }
    return false;
}

/// Parse `dnf repoquery --unneeded --qf %{name}` (one name per line). Not `dnf leaves`.
pub fn parseDnfUnneeded(text: []const u8, out: []DnfOrphan) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (skipDnfNoise(line)) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .name = name };
        n += 1;
    }
    return n;
}

fn managerFromCmd(cmd: []const u8) []const u8 {
    if (std.mem.startsWith(u8, cmd, "yum") or std.mem.indexOf(u8, cmd, "/yum ") != null) return "yum";
    return "dnf";
}

fn removePrefix(manager: []const u8) []const u8 {
    if (std.mem.eql(u8, manager, "yum")) return "yum remove -y ";
    return "dnf remove -y ";
}

fn upgradePrefix(manager: []const u8) []const u8 {
    if (std.mem.eql(u8, manager, "yum")) return "yum upgrade -y ";
    return "dnf upgrade -y ";
}

fn renderDnf(orphans: []const DnfOrphan, outdated: []const DnfOutdated, manager: []const u8) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"dnf\",\"engine\":");
    w.str(manager);
    w.raw(",\"findings\":[");
    var first = true;
    const rm = removePrefix(manager);
    for (orphans) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"orphan\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"status\":\"orphaned\",\"command\":\"");
        w.raw(rm);
        w.raw(h.name);
        w.raw("\",\"manager\":");
        w.str(manager);
        w.raw("}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, "", h.latest, manager, upgradePrefix(manager), true);
    }
    w.raw("],\"script\":");
    if (orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic ");
        w.raw(manager);
        w.raw(". Review before running.\\n");
        for (orphans) |h| {
            w.raw(rm);
            w.raw(h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove dnf unneeded?\",\"body\":\"Named repoquery --unneeded packages only. Named dnf/yum upgrade waits for confirm. Not a full distro upgrade. Nothing runs until you confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn runQuery(buf: []u8, cmds: []const []const u8, used: *[]const u8) i32 {
    for (cmds) |cmd| {
        const n = host_exec.run(cmd, buf);
        if (n >= 0) {
            used.* = cmd;
            return n;
        }
    }
    return host_exec.fail;
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
    var orphans: [128]DnfOrphan = undefined;
    var n_orph: usize = 0;
    var used_q: []const u8 = query_cmds[0];
    const nexec = runQuery(&exec_buf, &query_cmds, &used_q);
    if (nexec >= 0) n_orph = parseDnfUnneeded(exec_buf[0..@intCast(nexec)], &orphans);

    var outdated: [128]DnfOutdated = undefined;
    var n_out: usize = 0;
    var used_u: []const u8 = outdated_cmds[0];
    const nq = runQuery(&exec_up_buf, &outdated_cmds, &used_u);
    if (nq >= 0) n_out = parseDnfUpgrades(exec_up_buf[0..@intCast(nq)], &outdated);

    const mgr = if (nexec >= 0) managerFromCmd(used_q) else managerFromCmd(used_u);
    while (true) {
        if (renderDnf(orphans[0..n_orph], outdated[0..n_out], mgr)) return 0;
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

test "parseDnfUnneeded names skip metadata" {
    var buf: [8]DnfOrphan = undefined;
    const text =
        \\Last metadata expiration check: 1:23:45 ago on Wed 26 Aug 2026.
        \\libfoo
        \\python3-bar
        \\
    ;
    const n = parseDnfUnneeded(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("python3-bar", buf[1].name);
}

test "parseDnfUnneeded skips empty packages finding" {
    var buf: [4]DnfOrphan = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseDnfUnneeded("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseDnfUnneeded("Packages\nFinding unneeded\n", &buf));
}

test "plugin_query present JSON comes from dnf repoquery --unneeded fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"dnf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "python3-bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf remove -y libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf leaves") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf missing") != null);
}

test "plugin_query present JSON includes dnf list --upgrades outdated" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.45.1-1.fc40") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf upgrade -y git") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf leaves") == null);
}

test "parseDnfUpgrades strips arch skips headers" {
    var buf: [8]DnfOutdated = undefined;
    const text =
        \\Last metadata expiration check: 0:12:00 ago on Tue 25 Aug 2026.
        \\Available Upgrades
        \\git.x86_64                    2.45.1-1.fc40           updates
        \\firefox.x86_64                129.0-1.fc40            updates
        \\
    ;
    const n = parseDnfUpgrades(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("git", buf[0].name);
    try std.testing.expectEqualStrings("2.45.1-1.fc40", buf[0].latest);
    try std.testing.expectEqualStrings("firefox", buf[1].name);
    try std.testing.expectEqualStrings("129.0-1.fc40", buf[1].latest);
}

test "parseDnfUpgrades skips empty obsoleting" {
    var buf: [4]DnfOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseDnfUpgrades("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseDnfUpgrades("Obsoleting Packages\n", &buf));
}
