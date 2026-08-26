const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "pip";
const query_cmds = [_][]const u8{
    "pip list --user --outdated --format=json",
    "pip3 list --user --outdated --format=json",
};

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [8192]u8 = undefined;

const none_json =
    \\{"plugin":"pip","engine":null,"findings":[],"script":null,"dialog":{"title":"No pip","body":"pip is not on PATH. Plugin inactive."},"note":"pip missing"}
;

pub const PipOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

fn parseItem(s: []const u8, i: *usize, out: *PipOutdated) bool {
    if (i.* >= s.len or s[i.*] != '{') {
        _ = jsonscan.skipJsonValue(s, i);
        return false;
    }
    i.* += 1;
    var name: []const u8 = "";
    var current: []const u8 = "";
    var latest: []const u8 = "";
    while (i.* < s.len) {
        i.* = jsonscan.skipWs(s, i.*);
        if (i.* >= s.len) break;
        if (s[i.*] == '}') {
            i.* += 1;
            break;
        }
        if (s[i.*] == ',') {
            i.* += 1;
            continue;
        }
        const key = jsonscan.parseJsonString(s, i) orelse break;
        i.* = jsonscan.skipWs(s, i.*);
        if (i.* >= s.len or s[i.*] != ':') break;
        i.* += 1;
        i.* = jsonscan.skipWs(s, i.*);
        if (std.mem.eql(u8, key, "name") and i.* < s.len and s[i.*] == '"') {
            name = jsonscan.parseJsonString(s, i) orelse "";
        } else if (std.mem.eql(u8, key, "version") and i.* < s.len and s[i.*] == '"') {
            current = jsonscan.parseJsonString(s, i) orelse "";
        } else if (std.mem.eql(u8, key, "latest_version") and i.* < s.len and s[i.*] == '"') {
            latest = jsonscan.parseJsonString(s, i) orelse "";
        } else {
            if (!jsonscan.skipJsonValue(s, i)) break;
        }
    }
    if (!jsonbuf.isSafeIdent(name)) return false;
    out.* = .{ .name = name, .current = current, .latest = latest };
    return true;
}

/// Parse `pip list --user --outdated --format=json`. Array of {name, version, latest_version}.
pub fn parsePipOutdatedJSON(text: []const u8, out: []PipOutdated) usize {
    var n: usize = 0;
    var i: usize = jsonscan.skipWs(text, 0);
    if (i >= text.len or text[i] != '[') return 0;
    i += 1;
    while (i < text.len) {
        i = jsonscan.skipWs(text, i);
        if (i >= text.len) break;
        if (text[i] == ']') break;
        if (text[i] == ',') {
            i += 1;
            continue;
        }
        if (n >= out.len) {
            if (!jsonscan.skipJsonValue(text, &i)) break;
            continue;
        }
        if (parseItem(text, &i, &out[n])) n += 1;
    }
    return n;
}

fn renderPip(hits: []const PipOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"pip\",\"engine\":\"pip\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"outdated\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        if (h.current.len > 0) {
            w.raw(",\"current_version\":");
            w.str(h.current);
        }
        if (h.latest.len > 0) {
            w.raw(",\"latest_version\":");
            w.str(h.latest);
        }
        w.raw(",\"status\":\"outdated\",\"updatable\":false,\"command\":null,\"manager\":\"pip\"}");
    }
    w.raw("],\"script\":null");
    w.raw(",\"dialog\":{\"title\":\"Outdated pip user-site?\",\"body\":\"User-site packages from pip list --user --outdated. Report-only. AppAttic does not run this upgrade.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn runQuery(buf: []u8) i32 {
    for (query_cmds) |cmd| {
        const n = host_exec.run(cmd, buf);
        if (n >= 0) return n;
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
    const nexec = runQuery(&exec_buf);
    if (nexec < 0) {
        if (!renderPip(&.{})) return 1;
        return 0;
    }
    var hits: [32]PipOutdated = undefined;
    const n = parsePipOutdatedJSON(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderPip(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parsePipOutdatedJSON name version latest_version" {
    var buf: [8]PipOutdated = undefined;
    const text =
        \\[{"name":"requests","version":"2.28.1","latest_version":"2.32.3","latest_filetype":"wheel"},{"name":"urllib3","version":"1.26.18","latest_version":"2.2.2"}]
    ;
    const n = parsePipOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("requests", buf[0].name);
    try std.testing.expectEqualStrings("2.28.1", buf[0].current);
    try std.testing.expectEqualStrings("2.32.3", buf[0].latest);
    try std.testing.expectEqualStrings("urllib3", buf[1].name);
    try std.testing.expectEqualStrings("1.26.18", buf[1].current);
    try std.testing.expectEqualStrings("2.2.2", buf[1].latest);
}

test "parsePipOutdatedJSON pretty printed and dotted name" {
    var buf: [4]PipOutdated = undefined;
    const text =
        \\[
        \\  {"name": "backports.zoneinfo", "version": "0.2.1", "latest_version": "0.2.2"}
        \\]
    ;
    const n = parsePipOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("backports.zoneinfo", buf[0].name);
    try std.testing.expectEqualStrings("0.2.1", buf[0].current);
    try std.testing.expectEqualStrings("0.2.2", buf[0].latest);
}

test "parsePipOutdatedJSON empty junk skips unsafe" {
    var buf: [4]PipOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("[]", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON("not json", &buf));
    const bad =
        \\[{"name":"requests;rm","version":"1","latest_version":"2"}]
    ;
    try std.testing.expectEqual(@as(usize, 0), parsePipOutdatedJSON(bad, &buf));
}

test "plugin_query present JSON comes from pip list --user --outdated fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"pip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.28.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2.32.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "urllib3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"script\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip install") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip uninstall") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip3 install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pip missing") != null);
}
