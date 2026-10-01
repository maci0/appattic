const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "aur";
const outdated_cmds = [_][]const u8{
    "paru -Qua",
    "yay -Qua",
    "pikaur -Qua",
};

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_up_buf: [65536]u8 = undefined;

const none_json =
    \\{"plugin":"aur","engine":null,"findings":[],"script":null,"dialog":{"title":"No AUR helper","body":"paru, yay, or pikaur is not on PATH. Plugin inactive."},"note":"aur helper missing"}
;

const AurOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

/// Same line shape as `pacman -Qu`: name current -> latest.
pub fn parseAurQua(text: []const u8, out: []AurOutdated) usize {
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

fn helperFromCmd(cmd: []const u8) []const u8 {
    if (std.mem.startsWith(u8, cmd, "yay") or std.mem.indexOf(u8, cmd, "/yay ") != null) return "yay";
    if (std.mem.startsWith(u8, cmd, "pikaur") or std.mem.indexOf(u8, cmd, "/pikaur ") != null) return "pikaur";
    return "paru";
}

fn upgradeAction(helper: []const u8) []const u8 {
    if (std.mem.eql(u8, helper, "yay")) return "yay --noconfirm -S";
    if (std.mem.eql(u8, helper, "pikaur")) return "pikaur --noconfirm -S";
    return "paru --noconfirm -S";
}

fn renderAur(outdated: []const AurOutdated, helper: []const u8) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"aur\",\"engine\":");
    w.str(helper);
    w.raw(",\"findings\":[");
    const action = upgradeAction(helper);
    for (outdated, 0..) |h, i| {
        if (i != 0) w.raw(",");
        // The row is read from the helper's own `paru -Qu` (or `yay` / `pikaur`),
        // the same update check the scan asked, so the guard closes only while
        // the package is still behind.
        var cmd_buf: [1024]u8 = undefined;
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        var query_buf: [32]u8 = undefined;
        const query = std.fmt.bufPrint(&query_buf, "{s} -Qu", .{helper}) catch {
            w.failed = true;
            return false;
        };
        guard.writeUpgradeGuard(&cmd_w, &q_buf, query, action, h.name);
        const cmd = cmd_w.slice() orelse {
            w.failed = true;
            return false;
        };
        jsonbuf.writeOutdatedCommand(&w, h.name, h.current, h.latest, "aur", cmd, true);
    }
    w.raw("],\"script\":null,\"dialog\":{\"title\":\"AUR packages outdated\",\"body\":\"Named paru/yay/pikaur -S waits for confirm. Nothing runs until you confirm.\"}");
    note.write(&w);
    w.raw("}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn query_impl(present: i32) i32 {
    note = .{};
    if (present == 0) {
        plugin_abi.publishMissing(result_buf[0..], &result_nbytes, none_json);
        return 0;
    }
    var outdated: [128]AurOutdated = undefined;
    var used: []const u8 = outdated_cmds[0];
    var n_out: usize = 0;
    const nq = host_exec.runFirst(&exec_up_buf, &outdated_cmds, &used, &note);
    if (nq >= 0) n_out = parseAurQua(exec_up_buf[0..@intCast(nq)], &outdated);
    note.addTruncatedRows(n_out, outdated.len);
    // `renderAur` takes the helper name beside the list, so the shared
    // single-list shrinker cannot call it. The drop is recorded as the first
    // row goes, not once the render succeeds: `renderAur` writes the note
    // itself.
    const n_parsed = n_out;
    while (true) {
        if (renderAur(outdated[0..n_out], helperFromCmd(used))) return 0;
        if (n_out == 0) return 1;
        if (n_out == n_parsed) note.addDroppedRows(1);
        n_out -= 1;
    }
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "plugin_query present JSON includes AUR outdated from paru -Qua fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"aur\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "coreutils") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "paru --noconfirm -S coreutils") != null);
    // Guarded on the version the scan saw, so a script that runs twice does
    // not reinstall the package.
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "if paru -Qu coreutils >/dev/null 2>&1; then paru --noconfirm -S coreutils; fi",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "-Syu") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "aur helper missing") != null);
}

test "helperFromCmd" {
    try std.testing.expectEqualStrings("paru", helperFromCmd("paru -Qua"));
    try std.testing.expectEqualStrings("yay", helperFromCmd("yay -Qua"));
    try std.testing.expectEqualStrings("pikaur", helperFromCmd("/usr/bin/pikaur -Qua"));
}

// Same line shape as `pacman -Qu`, so the seeds are the same with the AUR
// noise lines: the arrow with nothing after it, and `error:`/`warning:` rows.
const fuzz_aur_rows = packFuzzSlice(
    \\libfoo 1.0-1 -> 2.0-1
    \\libbar 0.1-1 -> 0.2-1 [ignored]
);
const fuzz_aur_broken = packFuzzSlice(
    \\libfoo -> 
    \\ -> 1.0
    \\libfoo 1.0 ->
);
const fuzz_aur_unsafe = packFuzzSlice(
    \\libfoo;rm -rf / 1.0 -> 2.0
    \\$(id) 1.0 -> 2.0
    \\../../etc 1.0-1 -> 2.0-1
);
const fuzz_aur_junk = packFuzzSlice("warning: x\nlibfoo\x00 1.0 -> 2.0\r\n\xff");
const fuzz_aur_empty = packFuzzSlice("");

test "fuzz parseAurQua" {
    try std.testing.fuzz({}, fuzzAurQua, .{ .corpus = &.{
        &fuzz_aur_rows,
        &fuzz_aur_broken,
        &fuzz_aur_unsafe,
        &fuzz_aur_junk,
        &fuzz_aur_empty,
    } });
}

fn fuzzAurQua(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var buf: [32]AurOutdated = undefined;
    const n = parseAurQua(text, &buf);
    try std.testing.expect(n <= buf.len);
    for (buf[0..n]) |o| {
        try std.testing.expect(jsonbuf.isSafeCmdIdent(o.name));
        try std.testing.expect(sliceInside(text, o.name));
        try std.testing.expect(sliceInside(text, o.current));
        try std.testing.expect(sliceInside(text, o.latest));
        try std.testing.expect(o.current.len > 0);
        try std.testing.expect(o.latest.len > 0);
    }
}
