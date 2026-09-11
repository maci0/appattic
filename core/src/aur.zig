const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "aur";
const outdated_cmds = [_][]const u8{
    "paru -Qua",
    "yay -Qua",
    "pikaur -Qua",
};

var result_buf: [65536]u8 = undefined;
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
        if (!jsonbuf.isSafeIdent(name)) continue;
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

fn upgradePrefix(helper: []const u8) []const u8 {
    if (std.mem.eql(u8, helper, "yay")) return "yay --noconfirm -S ";
    if (std.mem.eql(u8, helper, "pikaur")) return "pikaur --noconfirm -S ";
    return "paru --noconfirm -S ";
}

fn renderAur(outdated: []const AurOutdated, helper: []const u8) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"aur\",\"engine\":");
    w.str(helper);
    w.raw(",\"findings\":[");
    const prefix = upgradePrefix(helper);
    for (outdated, 0..) |h, i| {
        if (i != 0) w.raw(",");
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "aur", prefix, true);
    }
    w.raw("],\"script\":null,\"dialog\":{\"title\":\"AUR packages outdated\",\"body\":\"Named paru/yay/pikaur -S waits for confirm. Nothing runs until you confirm.\"}}");
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
    var outdated: [128]AurOutdated = undefined;
    var used: []const u8 = outdated_cmds[0];
    var n_out: usize = 0;
    const nq = runQuery(&exec_up_buf, &outdated_cmds, &used);
    if (nq >= 0) n_out = parseAurQua(exec_up_buf[0..@intCast(nq)], &outdated);
    while (true) {
        if (renderAur(outdated[0..n_out], helperFromCmd(used))) return 0;
        if (n_out == 0) return 1;
        n_out -= 1;
    }
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "plugin_query present JSON includes AUR outdated from paru -Qua fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"aur\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "coreutils") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "paru --noconfirm -S coreutils") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "-Syu") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "aur helper missing") != null);
}

test "helperFromCmd" {
    try std.testing.expectEqualStrings("paru", helperFromCmd("paru -Qua"));
    try std.testing.expectEqualStrings("yay", helperFromCmd("yay -Qua"));
    try std.testing.expectEqualStrings("pikaur", helperFromCmd("/usr/bin/pikaur -Qua"));
}
