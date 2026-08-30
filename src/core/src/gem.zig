const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "gem";
const query_cmd = "gem outdated";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [8192]u8 = undefined;

const none_json =
    \\{"plugin":"gem","engine":null,"findings":[],"script":null,"dialog":{"title":"No gem","body":"gem is not on PATH. Plugin inactive."},"note":"gem missing"}
;

pub const GemOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

/// Parse `gem outdated`. Rows look like `sass (3.7.4 < 3.7.5)`.
pub fn parseGemOutdated(text: []const u8, out: []GemOutdated) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '*') continue;
        const open = std.mem.indexOf(u8, line, " (") orelse continue;
        const name = line[0..open];
        if (!jsonbuf.isSafeIdent(name)) continue;
        const rest = line[open + 2 ..];
        const lt = std.mem.indexOf(u8, rest, " < ") orelse continue;
        const current = std.mem.trim(u8, rest[0..lt], " \t");
        const after = rest[lt + 3 ..];
        const close = std.mem.indexOfScalar(u8, after, ')') orelse continue;
        const latest = std.mem.trim(u8, after[0..close], " \t");
        if (current.len == 0 or latest.len == 0) continue;
        out[n] = .{ .name = name, .current = current, .latest = latest };
        n += 1;
    }
    return n;
}

fn renderGem(hits: []const GemOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"gem\",\"engine\":\"gem\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        jsonbuf.writeOutdated(&w, h.name, h.current, h.latest, "gem", "gem update ");
    }
    w.raw("],\"script\":null");
    w.raw(",\"dialog\":{\"title\":\"Outdated RubyGems?\",\"body\":\"User-install gems from gem outdated. Report-only. Named gem update waits for confirm. AppAttic does not run this upgrade.\"}}");
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
        if (!renderGem(&.{})) return 1;
        return 0;
    }
    var hits: [32]GemOutdated = undefined;
    const n = parseGemOutdated(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderGem(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseGemOutdated name current latest" {
    var buf: [8]GemOutdated = undefined;
    const text =
        \\*** LOCAL GEMS ***
        \\
        \\sass (3.7.4 < 3.7.5)
        \\nokogiri (1.16.0 < 1.16.7)
        \\
    ;
    const n = parseGemOutdated(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("sass", buf[0].name);
    try std.testing.expectEqualStrings("3.7.4", buf[0].current);
    try std.testing.expectEqualStrings("3.7.5", buf[0].latest);
    try std.testing.expectEqualStrings("nokogiri", buf[1].name);
    try std.testing.expectEqualStrings("1.16.0", buf[1].current);
    try std.testing.expectEqualStrings("1.16.7", buf[1].latest);
}

test "parseGemOutdated empty junk skips unsafe" {
    var buf: [4]GemOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseGemOutdated("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseGemOutdated("*** LOCAL GEMS ***\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseGemOutdated("not gem output\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseGemOutdated("foo;rm (1.0 < 2.0)\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseGemOutdated("sass (3.7.4)\n", &buf));
}

test "plugin_query present JSON comes from gem outdated fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"gem\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sass") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "3.7.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "3.7.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nokogiri") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gem update sass") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"script\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gem uninstall") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gem missing") != null);
}
