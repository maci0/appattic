const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const jsonscan = @import("jsonscan.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "brew";
const query_cmd = "brew outdated --json=v2";

var result_buf: [8192]u8 = undefined;
var result_nbytes: u32 = 0;
var exec_buf: [8192]u8 = undefined;

const none_json =
    \\{"plugin":"brew","engine":null,"findings":[],"script":null,"dialog":{"title":"No brew","body":"brew is not on PATH. Plugin inactive."},"note":"brew missing"}
;

pub const BrewOutdated = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
    cask: bool,
};

fn isSafeBrewName(s: []const u8) bool {
    if (s.len == 0 or s.len > 214) return false;
    var at: usize = 0;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '+' or c == '@';
        if (!ok) return false;
        if (c == '@') at += 1;
    }
    if (at > 1) return false;
    if (s[0] == '@' or s[s.len - 1] == '@') return false;
    return true;
}

fn firstStringInArray(s: []const u8, i: *usize) []const u8 {
    var first: []const u8 = "";
    if (i.* >= s.len or s[i.*] != '[') return first;
    i.* += 1;
    while (i.* < s.len) {
        i.* = jsonscan.skipWs(s, i.*);
        if (i.* >= s.len) break;
        if (s[i.*] == ']') {
            i.* += 1;
            break;
        }
        if (s[i.*] == ',') {
            i.* += 1;
            continue;
        }
        if (s[i.*] == '"' and first.len == 0) {
            first = jsonscan.parseJsonString(s, i) orelse "";
        } else {
            if (!jsonscan.skipJsonValue(s, i)) break;
        }
    }
    return first;
}

fn parseItem(s: []const u8, i: *usize, out: *BrewOutdated, cask: bool) bool {
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
        } else if (std.mem.eql(u8, key, "current_version") and i.* < s.len and s[i.*] == '"') {
            latest = jsonscan.parseJsonString(s, i) orelse "";
        } else if (std.mem.eql(u8, key, "installed_versions")) {
            if (i.* < s.len and s[i.*] == '"') {
                current = jsonscan.parseJsonString(s, i) orelse "";
            } else if (i.* < s.len and s[i.*] == '[') {
                current = firstStringInArray(s, i);
            } else {
                if (!jsonscan.skipJsonValue(s, i)) break;
            }
        } else {
            if (!jsonscan.skipJsonValue(s, i)) break;
        }
    }
    if (!isSafeBrewName(name)) return false;
    out.* = .{ .name = name, .current = current, .latest = latest, .cask = cask };
    return true;
}

fn parseItems(s: []const u8, i: *usize, out: []BrewOutdated, cask: bool) usize {
    var n: usize = 0;
    if (i.* >= s.len or s[i.*] != '[') return 0;
    i.* += 1;
    while (i.* < s.len) {
        i.* = jsonscan.skipWs(s, i.*);
        if (i.* >= s.len) break;
        if (s[i.*] == ']') {
            i.* += 1;
            break;
        }
        if (s[i.*] == ',') {
            i.* += 1;
            continue;
        }
        if (n >= out.len) {
            if (!jsonscan.skipJsonValue(s, i)) break;
            continue;
        }
        if (parseItem(s, i, &out[n], cask)) n += 1;
    }
    return n;
}

/// Parse `brew outdated --json=v2`. Formulae then casks. Matches Swift `parseBrewOutdatedJSON`.
pub fn parseBrewOutdatedJSON(text: []const u8, out: []BrewOutdated) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        if (text[i] != '"') {
            i += 1;
            continue;
        }
        const key = jsonscan.parseJsonString(text, &i) orelse break;
        i = jsonscan.skipWs(text, i);
        if (i >= text.len or text[i] != ':') continue;
        i += 1;
        i = jsonscan.skipWs(text, i);
        const is_formulae = std.mem.eql(u8, key, "formulae");
        const is_casks = std.mem.eql(u8, key, "casks");
        if ((is_formulae or is_casks) and i < text.len and text[i] == '[') {
            n += parseItems(text, &i, out[n..], is_casks);
        }
    }
    return n;
}

fn writeUpgrade(w: *jsonbuf.W, h: BrewOutdated) void {
    if (h.cask) {
        w.raw("brew upgrade --cask ");
    } else {
        w.raw("brew upgrade ");
    }
    w.raw(h.name);
}

fn renderBrew(hits: []const BrewOutdated) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"brew\",\"engine\":\"brew\",\"findings\":[");
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
        w.raw(",\"status\":\"outdated\",\"updatable\":true,\"command\":\"");
        writeUpgrade(&w, h);
        w.raw("\",\"manager\":");
        w.str(if (h.cask) "brew-cask" else "brew-formula");
        w.raw("}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic brew. Review before running.\\n");
        for (hits) |h| {
            writeUpgrade(&w, h);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Update Homebrew packages?\",\"body\":\"User-global formulae and casks from brew outdated. Named brew upgrade waits for confirm. Nothing runs until you confirm.\"}}");
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
        if (!renderBrew(&.{})) return 1;
        return 0;
    }
    var hits: [32]BrewOutdated = undefined;
    const n = parseBrewOutdatedJSON(exec_buf[0..@intCast(nexec)], &hits);
    if (!renderBrew(hits[0..n])) return 1;
    return 0;
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseBrewOutdatedJSON formulae and casks" {
    var buf: [8]BrewOutdated = undefined;
    const text =
        \\{"formulae":[{"name":"wget","installed_versions":["1.21.4"],"current_version":"1.24.5","pinned":false,"pinned_version":null}],"casks":[{"name":"visual-studio-code","installed_versions":["1.90.0"],"current_version":"1.92.1","pinned":false,"pinned_version":null}]}
    ;
    const n = parseBrewOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("wget", buf[0].name);
    try std.testing.expectEqualStrings("1.21.4", buf[0].current);
    try std.testing.expectEqualStrings("1.24.5", buf[0].latest);
    try std.testing.expectEqual(false, buf[0].cask);
    try std.testing.expectEqualStrings("visual-studio-code", buf[1].name);
    try std.testing.expectEqualStrings("1.90.0", buf[1].current);
    try std.testing.expectEqualStrings("1.92.1", buf[1].latest);
    try std.testing.expectEqual(true, buf[1].cask);
}

test "parseBrewOutdatedJSON installed_versions string and versioned formula" {
    var buf: [4]BrewOutdated = undefined;
    const text =
        \\{"formulae":[{"name":"python@3.12","installed_versions":"3.12.4","current_version":"3.12.5"}],"casks":[]}
    ;
    const n = parseBrewOutdatedJSON(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("python@3.12", buf[0].name);
    try std.testing.expectEqualStrings("3.12.4", buf[0].current);
    try std.testing.expectEqualStrings("3.12.5", buf[0].latest);
    try std.testing.expectEqual(false, buf[0].cask);
}

test "parseBrewOutdatedJSON empty junk skips unsafe" {
    var buf: [4]BrewOutdated = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseBrewOutdatedJSON("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseBrewOutdatedJSON("{\"formulae\":[],\"casks\":[]}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseBrewOutdatedJSON("not json", &buf));
    const bad =
        \\{"formulae":[{"name":"wget;rm","installed_versions":["1"],"current_version":"2"}],"casks":[]}
    ;
    try std.testing.expectEqual(@as(usize, 0), parseBrewOutdatedJSON(bad, &buf));
}

test "plugin_query present JSON comes from brew outdated fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"brew\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"outdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "wget") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.21.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1.24.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "visual-studio-code") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "brew-formula") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "brew-cask") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "brew upgrade wget") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "brew upgrade --cask visual-studio-code") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "brew uninstall") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "--greedy") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "brew missing") != null);
}
