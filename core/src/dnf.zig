const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

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
var note: querynote.Log = .{};
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
        out[n] = .{ .name = name, .latest = latest };
        n += 1;
    }
    return n;
}

fn skipDnfNoise(line: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(line, "last metadata")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "packages")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "finding")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "available upgrade")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "obsoleting")) return true;
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
        if (std.ascii.isDigit(c)) return true;
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
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
    var q_buf: [1024]u8 = undefined;
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
        guard.writeNameGuard(&w, &q_buf, "rpm -q ", rm, h.name);
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
            guard.writeNameGuard(&w, &q_buf, "rpm -q ", rm, h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove dnf unneeded?\",\"body\":\"Named repoquery --unneeded packages only. Named dnf/yum upgrade waits for confirm. Not a full distro upgrade. Nothing runs until you confirm.\"}");
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
    var orphans: [128]DnfOrphan = undefined;
    var n_orph: usize = 0;
    var used_q: []const u8 = query_cmds[0];
    const nexec = host_exec.runFirst(&exec_buf, &query_cmds, &used_q, &note);
    if (nexec >= 0) n_orph = parseDnfUnneeded(exec_buf[0..@intCast(nexec)], &orphans);
    note.addTruncatedRows(n_orph, orphans.len);

    var outdated: [128]DnfOutdated = undefined;
    var n_out: usize = 0;
    var used_u: []const u8 = outdated_cmds[0];
    const nq = host_exec.runFirst(&exec_up_buf, &outdated_cmds, &used_u, &note);
    if (nq >= 0) n_out = parseDnfUpgrades(exec_up_buf[0..@intCast(nq)], &outdated);
    note.addTruncatedRows(n_out, outdated.len);

    const mgr = if (nexec >= 0) managerFromCmd(used_q) else managerFromCmd(used_u);
    // `renderDnf` takes the manager name beside the two lists, so the shared
    // two-list shrinker cannot call it. The drop is recorded as the first row
    // goes, not once the render succeeds: `renderDnf` writes the note itself.
    var noted = false;
    while (true) {
        if (renderDnf(orphans[0..n_orph], outdated[0..n_out], mgr)) return 0;
        if (n_out > 0) {
            n_out -= 1;
        } else if (n_orph > 0) {
            n_orph -= 1;
        } else {
            return 1;
        }
        if (!noted) {
            note.addDroppedRows(1);
            noted = true;
        }
    }
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
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
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"dnf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "python3-bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf remove -y libfoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if rpm -q libfoo; then dnf remove -y libfoo; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf leaves") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dnf missing") != null);
}

test "plugin_query present JSON includes dnf list --upgrades outdated" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
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

test "runFirst names every command that did not answer" {
    const none = [_][]const u8{ "appattic-no-such-cmd one", "appattic-no-such-cmd two" };
    var log = querynote.Log{};
    var used: []const u8 = none[0];
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(host_exec.fail, host_exec.runFirst(&buf, &none, &used, &log));
    try std.testing.expectEqual(@as(usize, 2), log.n);
    try std.testing.expectEqualStrings("appattic-no-such-cmd one", log.items[0][0]);
    try std.testing.expectEqualStrings("appattic-no-such-cmd two", log.items[1][0]);
}

// Seeds are `dnf check-update` and `dnf repoquery --unneeded` output, plus the
// noise lines dnf prints on the same stream and the arch suffix both parsers
// have to see through.
const fuzz_dnf_upgrades = packFuzzSlice(
    \\libfoo.x86_64    1.2.4-1.fc39      updates
    \\libbar.noarch     0.1-1.fc39        baseos
    \\Last metadata expired check.
);
const fuzz_dnf_unneeded = packFuzzSlice(
    \\libfoo.x86_64
    \\libbar.noarch
    \\libbaz.aarch64
);
const fuzz_dnf_noise = packFuzzSlice(
    \\Available Upgrades
    \\Obsoleting Packages
    \\Nothing to do.
    \\last metadata expired
);
const fuzz_dnf_unsafe = packFuzzSlice(
    \\libfoo;rm -rf / 1.0 updates
    \\$(id) 1.0 baseos
    \\../../etc 1.0 updates
);
const fuzz_dnf_junk = packFuzzSlice("libfoo\x00 1.0 updates\r\n\xff\nx86_64");
const fuzz_dnf_empty = packFuzzSlice("");

test "fuzz dnf listing parsers" {
    try std.testing.fuzz({}, fuzzDnfListings, .{ .corpus = &.{
        &fuzz_dnf_upgrades,
        &fuzz_dnf_unneeded,
        &fuzz_dnf_noise,
        &fuzz_dnf_unsafe,
        &fuzz_dnf_junk,
        &fuzz_dnf_empty,
    } });
}

/// `stripDnfArch` returns a prefix of the token it was given, so a reported
/// name is still inside the input even when the arch is stripped, and the
/// upgrade version is the second field, which must carry a digit.
fn fuzzDnfListings(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var outdated: [32]DnfOutdated = undefined;
    const nout = parseDnfUpgrades(text, &outdated);
    try std.testing.expect(nout <= outdated.len);
    for (outdated[0..nout]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(sliceInside(text, o.latest));
        try std.testing.expect(o.latest.len > 0);
        // A version is reported only when it has a digit, so stripping the
        // arch never leaves a name that ends in a bare arch suffix.
        try std.testing.expect(hasDigit(o.latest));
    }

    var orphans: [32]DnfOrphan = undefined;
    const nord = parseDnfUnneeded(text, &orphans);
    try std.testing.expect(nord <= orphans.len);
    for (orphans[0..nord]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(o.name.len > 0);
    }
}
