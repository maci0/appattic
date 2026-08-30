const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");

pub const Dep = struct {
    name: []const u8,
    version: []const u8,
};

pub fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }
    return j;
}

pub fn parseJsonString(s: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= s.len or s[i.*] != '"') return null;
    i.* += 1;
    const start = i.*;
    while (i.* < s.len) {
        const c = s[i.*];
        if (c == '\\') {
            i.* += 1;
            if (i.* < s.len) i.* += 1;
            continue;
        }
        if (c == '"') {
            const inner = s[start..i.*];
            i.* += 1;
            return inner;
        }
        i.* += 1;
    }
    return null;
}

fn skipDelim(s: []const u8, i: *usize, open: u8, close: u8) bool {
    if (i.* >= s.len or s[i.*] != open) return false;
    var depth: u32 = 0;
    var in_str = false;
    var esc = false;
    while (i.* < s.len) {
        const c = s[i.*];
        i.* += 1;
        if (in_str) {
            if (esc) {
                esc = false;
                continue;
            }
            if (c == '\\') {
                esc = true;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return true;
        }
    }
    return false;
}

pub fn skipJsonValue(s: []const u8, i: *usize) bool {
    i.* = skipWs(s, i.*);
    if (i.* >= s.len) return false;
    const c = s[i.*];
    if (c == '"') return parseJsonString(s, i) != null;
    if (c == '{') return skipDelim(s, i, '{', '}');
    if (c == '[') return skipDelim(s, i, '[', ']');
    while (i.* < s.len) {
        const d = s[i.*];
        if (d == ',' or d == '}' or d == ']' or d == ' ' or d == '\n' or d == '\t' or d == '\r') break;
        i.* += 1;
    }
    return true;
}

fn takeVersionSkipObject(s: []const u8, i: *usize) []const u8 {
    var version: []const u8 = "";
    if (i.* >= s.len or s[i.*] != '{') {
        _ = skipJsonValue(s, i);
        return version;
    }
    i.* += 1;
    while (i.* < s.len) {
        i.* = skipWs(s, i.*);
        if (i.* >= s.len) break;
        if (s[i.*] == '}') {
            i.* += 1;
            break;
        }
        if (s[i.*] == ',') {
            i.* += 1;
            continue;
        }
        const key = parseJsonString(s, i) orelse break;
        i.* = skipWs(s, i.*);
        if (i.* >= s.len or s[i.*] != ':') break;
        i.* += 1;
        i.* = skipWs(s, i.*);
        if (std.mem.eql(u8, key, "version") and i.* < s.len and s[i.*] == '"') {
            if (parseJsonString(s, i)) |v| {
                if (version.len == 0) version = v;
            }
        } else {
            if (!skipJsonValue(s, i)) break;
        }
    }
    return version;
}

fn parseDepsObject(s: []const u8, i: *usize, out: []Dep) usize {
    var n: usize = 0;
    if (i.* >= s.len or s[i.*] != '{') return 0;
    i.* += 1;
    while (i.* < s.len) {
        i.* = skipWs(s, i.*);
        if (i.* >= s.len) break;
        if (s[i.*] == '}') {
            i.* += 1;
            break;
        }
        if (s[i.*] == ',') {
            i.* += 1;
            continue;
        }
        const name = parseJsonString(s, i) orelse break;
        i.* = skipWs(s, i.*);
        if (i.* >= s.len or s[i.*] != ':') break;
        i.* += 1;
        i.* = skipWs(s, i.*);
        var version: []const u8 = "";
        if (i.* < s.len and s[i.*] == '{') {
            version = takeVersionSkipObject(s, i);
        } else if (i.* < s.len and s[i.*] == '"') {
            version = parseJsonString(s, i) orelse "";
        } else {
            if (!skipJsonValue(s, i)) break;
        }
        if (n < out.len and jsonbuf.isSafePkgName(name)) {
            out[n] = .{ .name = name, .version = version };
            n += 1;
        }
    }
    return n;
}

/// Top-level (and sibling) `"dependencies"` objects. Does not walk nested dep trees.
pub fn parseJsonDependencies(text: []const u8, out: []Dep) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        if (text[i] != '"') {
            i += 1;
            continue;
        }
        const key = parseJsonString(text, &i) orelse break;
        i = skipWs(text, i);
        if (i >= text.len or text[i] != ':') continue;
        i += 1;
        i = skipWs(text, i);
        if (std.mem.eql(u8, key, "dependencies") and i < text.len and text[i] == '{') {
            n += parseDepsObject(text, &i, out[n..]);
        }
    }
    return n;
}

pub fn findJsonStringField(text: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '"') {
            i += 1;
            continue;
        }
        const key = parseJsonString(text, &i) orelse return null;
        i = skipWs(text, i);
        if (i >= text.len or text[i] != ':') continue;
        i += 1;
        i = skipWs(text, i);
        if (std.mem.eql(u8, key, field)) {
            if (i < text.len and text[i] == '"') return parseJsonString(text, &i);
            return null;
        }
    }
    return null;
}

test "parseJsonDependencies object and array" {
    var buf: [8]Dep = undefined;
    const obj =
        \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
    ;
    const n = parseJsonDependencies(obj, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
    try std.testing.expectEqualStrings("prettier", buf[1].name);
    try std.testing.expectEqualStrings("3.3.0", buf[1].version);

    const arr =
        \\[{"dependencies":{"nx":{"version":"19.0.0"}}}]
    ;
    const n2 = parseJsonDependencies(arr, &buf);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("nx", buf[0].name);
    try std.testing.expectEqualStrings("19.0.0", buf[0].version);
}

test "parseJsonDependencies scoped and skips nested trees" {
    var buf: [8]Dep = undefined;
    const text =
        \\{"dependencies":{"@vue/cli":{"version":"5.0.8","dependencies":{"evil":{"version":"1.0.0"}}}}}
    ;
    const n = parseJsonDependencies(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("@vue/cli", buf[0].name);
    try std.testing.expectEqualStrings("5.0.8", buf[0].version);
}

test "parseJsonDependencies empty junk" {
    var buf: [4]Dep = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("not json", &buf));
}

test "isSafePkgName scoped" {
    try std.testing.expect(jsonbuf.isSafePkgName("typescript"));
    try std.testing.expect(jsonbuf.isSafePkgName("@vue/cli"));
    try std.testing.expect(!jsonbuf.isSafePkgName("@vue"));
    try std.testing.expect(!jsonbuf.isSafePkgName("foo/bar/baz"));
    try std.testing.expect(!jsonbuf.isSafePkgName("../etc"));
    try std.testing.expect(!jsonbuf.isSafePkgName("foo;rm"));
}
