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
    std.debug.assert(open != close);
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
            if (depth == 0) return false;
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
        } else {
            if (!skipJsonValue(text, &i)) break;
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

    const sibling =
        \\{"other":{"dependencies":{"evil":{"version":"1.0.0"}}},"dependencies":{"typescript":{"version":"5.4.5"}}}
    ;
    const n2 = parseJsonDependencies(sibling, &buf);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
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

fn sliceInside(hay: []const u8, n: []const u8) bool {
    if (n.len == 0) return true;
    const h0 = @intFromPtr(hay.ptr);
    const n0 = @intFromPtr(n.ptr);
    return n0 >= h0 and n0 + n.len <= h0 + hay.len;
}

fn packFuzzSlice(comptime s: []const u8) [4 + s.len]u8 {
    var out: [4 + s.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4..], s);
    return out;
}

const fuzz_npm_obj = packFuzzSlice(
    \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
);
const fuzz_npm_arr = packFuzzSlice(
    \\[{"dependencies":{"nx":{"version":"19.0.0"}}}]
);
const fuzz_npm_scoped = packFuzzSlice(
    \\{"dependencies":{"@vue/cli":{"version":"5.0.8","dependencies":{"evil":{"version":"1.0.0"}}}}}
);
const fuzz_npm_sibling = packFuzzSlice(
    \\{"other":{"dependencies":{"evil":{"version":"1.0.0"}}},"dependencies":{"typescript":{"version":"5.4.5"}}}
);
const fuzz_npm_string_ver = packFuzzSlice(
    \\{"dependencies":{"leftpad":"1.3.0","@scope/pkg":{"version":"0.1.0"}}}
);
const fuzz_truncated = packFuzzSlice(
    \\{"dependencies":{"typescript":{"version":"5.4
);
const fuzz_unclosed = packFuzzSlice("{\"dependencies\":{\"x\":\"abc");
const fuzz_nested = packFuzzSlice("{\"a\":{\"b\":{\"c\":[1,2,{\"d\":\"e\"}]}}}");
const fuzz_escapes = packFuzzSlice("{\"dependencies\":{\"a\\\"b\":{\"version\":\"1\\n2\"}}}");
const fuzz_ws = packFuzzSlice(" \t\n\r{\"dependencies\" : { } }");
const fuzz_nulls = packFuzzSlice("{\"dependencies\":{\"x\":null,\"y\":true,\"z\":false}}");
const fuzz_not_json = packFuzzSlice("not json {{{");
const fuzz_empty_obj = packFuzzSlice("{}");
const fuzz_deep = packFuzzSlice("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<{{{{{{{{{{{{{{{{}}}}}}}}}}}}}}}}");

test "fuzz jsonscan parsers" {
    try std.testing.fuzz({}, fuzzJsonScan, .{ .corpus = &.{
        &fuzz_npm_obj,
        &fuzz_npm_arr,
        &fuzz_npm_scoped,
        &fuzz_npm_sibling,
        &fuzz_npm_string_ver,
        &fuzz_truncated,
        &fuzz_unclosed,
        &fuzz_nested,
        &fuzz_escapes,
        &fuzz_ws,
        &fuzz_nulls,
        &fuzz_not_json,
        &fuzz_empty_obj,
        &fuzz_deep,
    } });
}

fn fuzzJsonScan(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const n = smith.slice(&raw);
    const text = raw[0..n];

    var deps: [32]Dep = undefined;
    const got = parseJsonDependencies(text, &deps);
    try std.testing.expect(got <= deps.len);
    for (deps[0..got]) |d| {
        try std.testing.expect(sliceInside(text, d.name));
        try std.testing.expect(d.version.len == 0 or sliceInside(text, d.version));
        try std.testing.expect(jsonbuf.isSafePkgName(d.name));
    }

    var i: usize = 0;
    _ = skipJsonValue(text, &i);
    try std.testing.expect(i <= text.len);

    var j: usize = 0;
    if (parseJsonString(text, &j)) |s| {
        try std.testing.expect(sliceInside(text, s));
        try std.testing.expect(j <= text.len);
        try std.testing.expect(j >= 2);
    } else {
        try std.testing.expect(j <= text.len);
    }

    if (findJsonStringField(text, "version")) |v| {
        try std.testing.expect(sliceInside(text, v));
    }
    if (findJsonStringField(text, "name")) |v| {
        try std.testing.expect(sliceInside(text, v));
    }

    var k: usize = 0;
    var steps: usize = 0;
    while (k < text.len) {
        steps += 1;
        try std.testing.expect(steps <= text.len + 2);
        const before = k;
        k = skipWs(text, k);
        if (k >= text.len) break;
        switch (text[k]) {
            ',', ':', '}', ']' => k += 1,
            else => {
                if (!skipJsonValue(text, &k)) break;
                if (k <= before) k += 1;
            },
        }
    }
}
