const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "apt";
const query_cmd = "apt-get -s autoremove";
const outdated_cmd = "apt list --upgradable";
const dpkg_cmd = "dpkg -l";
const ppa_cmd = "ls -1 /etc/apt/sources.list.d";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
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
    return std.ascii.indexOfIgnoreCase(name, "ppa") != null or
        std.ascii.indexOfIgnoreCase(name, "launchpad") != null;
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
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
    var q_buf: [1024]u8 = undefined;
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
        w.raw(",\"status\":\"orphaned\",\"command\":\"");
        guard.writeNameGuard(&w, &q_buf, "dpkg -s ", "apt-get purge -y ", h.name);
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
        w.raw(",\"status\":\"orphaned\",\"command\":\"");
        guard.writeNameGuard(&w, &q_buf, "dpkg -s ", "apt-get purge -y ", h.name);
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
        w.str(h.name);
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
            guard.writeNameGuard(&w, &q_buf, "dpkg -s ", "apt-get purge -y ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove apt orphans?\",\"body\":\"Named autoremove leaves only. Named apt install --only-upgrade waits for confirm. Not a full apt upgrade. Nothing runs until you confirm.\"}}");
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
    var orphans: [128]AptOrphan = undefined;
    var n_orph: usize = 0;
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec >= 0) n_orph = parseAptAutoremove(exec_buf[0..@intCast(nexec)], &orphans);

    var outdated: [128]AptOutdated = undefined;
    var n_out: usize = 0;
    const nq = host_exec.run(outdated_cmd, &exec_up_buf);
    note.add(outdated_cmd, nq);
    if (nq >= 0) n_out = parseAptUpgradable(exec_up_buf[0..@intCast(nq)], &outdated);

    var rc_pkgs: [128]DpkgRc = undefined;
    var n_rc: usize = 0;
    const nd = host_exec.run(dpkg_cmd, &exec_dpkg_buf);
    note.add(dpkg_cmd, nd);
    if (nd >= 0) n_rc = parseDpkgRc(exec_dpkg_buf[0..@intCast(nd)], &rc_pkgs);

    var ppas: [32]PpaSource = undefined;
    var n_ppa: usize = 0;
    const np = host_exec.run(ppa_cmd, &exec_ppa_buf);
    note.add(ppa_cmd, np);
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

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
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
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"apt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libfoo0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "libbar1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt-get purge -y libfoo0") != null);
    // `set -e` stops the script at the first nonzero line, so a rerun that
    // already purged the package would never reach the ones after it.
    try std.testing.expect(std.mem.indexOf(u8, json, "if dpkg -s libfoo0; then apt-get purge -y libfoo0; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt-get upgrade") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dist-upgrade") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "apt missing") != null);
}

test "plugin_query present JSON includes apt list --upgradable outdated" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
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
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "oldpkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"manager\":\"dpkg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deadsnakes-ubuntu-ppa-noble.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"ppa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /etc/apt") == null);
}

// Seeds are real `apt` output: `dpkg -l` rc rows, an autoremove dry run, an
// `apt list --upgradable` table, and an `ls -1` of a sources.list.d. The
// mutations that matter to a hand-rolled line parser are the ones below:
// truncated rows, a missing `[...]`, a bare `/` with no version after it, and
// a row that starts with the `rc` marker but carries no name.
const fuzz_apt_rc = packFuzzSlice("rc  libfoo 1.2.3-1\n" ++
    "rc  libbar\n" ++
    "rc\tlibbaz\t9.9\n" ++
    "ii  keepme 1.0\n" ++
    "rc   libquux 4.5-1\n");
const fuzz_apt_autoremove = packFuzzSlice(
    \\Remv libfoo [1.2.3-1]
    \\Remv libbar [0.1]
    \\Remv libfoo [1.2.3-1]
    \\Remv  [1.0]
    \\Remv
);
const fuzz_apt_upgradable = packFuzzSlice(
    \\libfoo/bookworm-security 1.2.4 amd64 [upgradable from: 1.2.3]
    \\libbar/stable 2.0 amd64 [upgradable from: 1.0]
);
const fuzz_apt_upgradable_broken = packFuzzSlice(
    \\libfoo/ 1.2.4 amd64 [upgradable from: 1.2.3]
    \\libbar/stable [upgradable from: ]
    \\libbaz/stable 3.0 amd64 [upgradable from:
);
const fuzz_apt_ppa = packFuzzSlice(
    \\google-chrome.list
    \\deadsnakes-ubuntu-ppa-noble.list
    \\ubuntu.sources
    \\/etc/apt/sources.list.d/launchpad-ppa.list
    \\
);
const fuzz_apt_unsafe = packFuzzSlice(
    \\rc  libfoo;rm -rf / 1.0
    \\Remv ../../etc [1.0]
    \\evil$(id)/stable 9 amd64 [upgradable from: 1]
);
const fuzz_apt_junk = packFuzzSlice("rc\r\n\x00\x01\n \t\nRemv\xff");
const fuzz_apt_empty = packFuzzSlice("");

test "fuzz apt listing parsers" {
    try std.testing.fuzz({}, fuzzAptListings, .{ .corpus = &.{
        &fuzz_apt_rc,
        &fuzz_apt_autoremove,
        &fuzz_apt_upgradable,
        &fuzz_apt_upgradable_broken,
        &fuzz_apt_ppa,
        &fuzz_apt_unsafe,
        &fuzz_apt_junk,
        &fuzz_apt_empty,
    } });
}

/// The four parsers share one input and one set of properties: a name that
/// reaches a generated `apt-get remove` line, and a version that reaches the
/// same line. A name must pass `isSafeIdent`, and every field must be a slice
/// of the input rather than a rebuilt or padded buffer. Each parser also has
/// to leave the row count within `out` and never carry a field across rows.
fn fuzzAptListings(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var rc: [32]DpkgRc = undefined;
    const nrc = parseDpkgRc(text, &rc);
    try std.testing.expect(nrc <= rc.len);
    for (rc[0..nrc]) |r| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(r.name));
        try std.testing.expect(sliceInside(text, r.name));
        try std.testing.expect(sliceInside(text, r.version));
    }

    var orphans: [32]AptOrphan = undefined;
    const nrem = parseAptAutoremove(text, &orphans);
    try std.testing.expect(nrem <= orphans.len);
    for (orphans[0..nrem]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(sliceInside(text, o.version));
    }

    var outdated: [32]AptOutdated = undefined;
    const nup = parseAptUpgradable(text, &outdated);
    try std.testing.expect(nup <= outdated.len);
    for (outdated[0..nup]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(o.current.len > 0);
        try std.testing.expect(sliceInside(text, o.current));
        try std.testing.expect(sliceInside(text, o.latest));
        // A row is only reported when the marker parsed to a version, and
        // neither field may have kept the `[upgradable from: ...]` framing.
        try std.testing.expect(std.mem.indexOfScalar(u8, o.current, '[') == null);
        try std.testing.expect(o.current[o.current.len - 1] != ']');
    }

    var ppas: [32]PpaSource = undefined;
    const nppa = parsePpaSources(text, &ppas);
    try std.testing.expect(nppa <= ppas.len);
    for (ppas[0..nppa]) |p| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(p.name));
        try std.testing.expect(sliceInside(text, p.name));
        try std.testing.expect(sliceInside(text, p.path));
        // The name is the last path component, so it is a suffix of the line.
        try std.testing.expect(p.path.len >= p.name.len);
        try std.testing.expect(std.mem.endsWith(u8, p.path, p.name));
    }

    // Re-running on the same text is the same answer: no parser keeps a
    // cursor or a row count between calls.
    var rc2: [32]DpkgRc = undefined;
    try std.testing.expectEqual(nrc, parseDpkgRc(text, &rc2));
    var up2: [32]AptOutdated = undefined;
    try std.testing.expectEqual(nup, parseAptUpgradable(text, &up2));
    for (up2[0..nup], outdated[0..nup]) |a, b| {
        try std.testing.expect(std.mem.eql(u8, a.name, b.name));
        try std.testing.expect(std.mem.eql(u8, a.latest, b.latest));
    }
}

// A `dpkg -l` row is `rc` plus a name, so a row that keeps the marker must
// yield a name that is really there, and one that does not must yield
// nothing. The version is the second field and may be absent.
test "parseDpkgRc name is a field of the row" {
    var buf: [8]DpkgRc = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        parseDpkgRc("rc  libfoo 1.2.3-1\n", &buf),
    );
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("1.2.3-1", buf[0].version);

    const no_version = parseDpkgRc("rc\tlibbar\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), no_version);
    try std.testing.expectEqualStrings("libbar", buf[0].name);
    try std.testing.expectEqualStrings("", buf[0].version);

    // `dpkg -l` indents its status column, so leading whitespace is normal
    // and must not hide the marker.
    const indented = parseDpkgRc("  rc   libfoo 1.0-1\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), indented);
    try std.testing.expectEqualStrings("libfoo", buf[0].name);
    try std.testing.expectEqualStrings("1.0-1", buf[0].version);

    const rejected = [_][]const u8{ "rc", "rc ", "rc  ", "rc  libfoo;rm", "rc  ../etc", "ir  libfoo" };
    for (rejected) |row| {
        try std.testing.expectEqual(@as(usize, 0), parseDpkgRc(row, &buf));
    }
}
