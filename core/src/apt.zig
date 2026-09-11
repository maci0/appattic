const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "apt";
const query_cmd = "apt-get -s autoremove";
const outdated_cmd = "apt list --upgradable";
const dpkg_cmd = "dpkg -l";
const ppa_cmd = "ls -1 /etc/apt/sources.list.d";

var result_buf: [65536]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var exec_up_buf: [65536]u8 = undefined;
var exec_dpkg_buf: [262144]u8 = undefined;
var exec_ppa_buf: [16384]u8 = undefined;

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

pub const DpkgRc = struct {
    name: []const u8,
    version: []const u8,
};

pub const PpaSource = struct {
    name: []const u8,
    path: []const u8,
};

fn isPpaFile(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    if (std.mem.eql(u8, name, "ubuntu.sources") or std.mem.eql(u8, name, "debian.sources")) return false;
    var tmp: [128]u8 = undefined;
    const n = @min(name.len, tmp.len);
    for (name[0..n], 0..) |c, i| tmp[i] = std.ascii.toLower(c);
    const low = tmp[0..n];
    return std.mem.indexOf(u8, low, "ppa") != null or std.mem.indexOf(u8, low, "launchpad") != null;
}

/// Parse `dpkg -l`. Keep `rc` rows (removed, config remains).
pub fn parseDpkgRc(text: []const u8, out: []DpkgRc) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 4) continue;
        if (!(line[0] == 'r' and line[1] == 'c' and (line[2] == ' ' or line[2] == '\t'))) continue;
        var it = std.mem.tokenizeAny(u8, line[2..], " \t");
        const name = it.next() orelse continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        const version = it.next() orelse "";
        out[n] = .{ .name = name, .version = version };
        n += 1;
    }
    return n;
}

/// Parse `ls -1 /etc/apt/sources.list.d`. Keep PPA-looking names.
pub fn parsePpaSources(text: []const u8, out: []PpaSource) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name = blk: {
            if (std.mem.lastIndexOfScalar(u8, line, '/')) |i| break :blk line[i + 1 ..];
            break :blk line;
        };
        if (!isPpaFile(name)) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .name = name, .path = line };
        n += 1;
    }
    return n;
}

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

fn renderApt(
    orphans: []const AptOrphan,
    outdated: []const AptOutdated,
    rc_pkgs: []const DpkgRc,
    ppas: []const PpaSource,
) bool {
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
    for (rc_pkgs) |h| {
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
        w.raw("\",\"manager\":\"dpkg\",\"summary\":\"Removed package still has config files\",\"reason\":\"dpkg status rc: the package is gone, config remnants remain. Purge drops them.\"}");
    }
    for (ppas) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"ppa\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":\"/etc/apt/sources.list.d/");
        w.raw(h.name);
        w.raw("\",\"status\":\"review\",\"manager\":\"apt\",\"summary\":\"Third-party apt source\",\"reason\":\"PPA or Launchpad source under /etc/apt/sources.list.d. Removing it needs root and is not done automatically.\"}");
    }
    for (outdated) |h| {
        if (!first) w.raw(",");
        first = false;
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "apt", "apt-get -y install --only-upgrade ", true);
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
    w.raw(",\"dialog\":{\"title\":\"Remove apt orphans?\",\"body\":\"Named autoremove leaves only. Named apt install --only-upgrade waits for confirm. Not a full apt upgrade. Nothing runs until you confirm.\"}}");
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
    var orphans: [128]AptOrphan = undefined;
    var n_orph: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    if (nexec >= 0) n_orph = parseAptAutoremove(exec_buf[0..@intCast(nexec)], &orphans);

    var outdated: [128]AptOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_up_buf);
    if (nq >= 0) n_out = parseAptUpgradable(exec_up_buf[0..@intCast(nq)], &outdated);

    var rc_pkgs: [128]DpkgRc = undefined;
    var n_rc: usize = 0;
    const nd = host_exec.run(dpkg_cmd, &exec_dpkg_buf);
    if (nd >= 0) n_rc = parseDpkgRc(exec_dpkg_buf[0..@intCast(nd)], &rc_pkgs);

    var ppas: [32]PpaSource = undefined;
    var n_ppa: usize = 0;
    const np = host_exec.run(ppa_cmd, &exec_ppa_buf);
    if (np >= 0) n_ppa = parsePpaSources(exec_ppa_buf[0..@intCast(np)], &ppas);

    while (true) {
        if (renderApt(orphans[0..n_orph], outdated[0..n_out], rc_pkgs[0..n_rc], ppas[0..n_ppa])) return 0;
        if (n_out > 0) {
            n_out -= 1;
            continue;
        }
        if (n_ppa > 0) {
            n_ppa -= 1;
            continue;
        }
        if (n_rc > 0) {
            n_rc -= 1;
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
    try std.testing.expect(std.mem.indexOf(u8, json, "apt-get upgrade") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, json, "apt-get -y install --only-upgrade git") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt-get upgrade") == null);
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

test "parseDpkgRc keeps rc skips ii" {
    var buf: [8]DpkgRc = undefined;
    const text =
        \\ii  bash           5.2.15-2     amd64        GNU Bourne Again SHell
        \\rc  oldpkg         1.0-1        amd64        leftover config
        \\rc  gone-lib       2.2-3        amd64        unused leftover
        \\
    ;
    const n = parseDpkgRc(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("oldpkg", buf[0].name);
    try std.testing.expectEqualStrings("1.0-1", buf[0].version);
    try std.testing.expectEqualStrings("gone-lib", buf[1].name);
}

test "parsePpaSources keeps ppa files" {
    var buf: [8]PpaSource = undefined;
    const text =
        \\google-chrome.list
        \\deadsnakes-ubuntu-ppa-noble.list
        \\ubuntu.sources
        \\
    ;
    const n = parsePpaSources(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("deadsnakes-ubuntu-ppa-noble.list", buf[0].name);
}

test "plugin_query present JSON includes dpkg rc and ppa source" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "oldpkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"manager\":\"dpkg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deadsnakes-ubuntu-ppa-noble.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"ppa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /etc/apt") == null);
}
