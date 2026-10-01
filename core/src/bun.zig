const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "bun";
const query_cmd = "bun pm ls -g";

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [32768]u8 = undefined;

const none_json =
    \\{"plugin":"bun","engine":null,"findings":[],"script":null,"dialog":{"title":"No bun","body":"bun is not on PATH. Plugin inactive."},"note":"bun missing"}
;

pub const BunGlobal = struct {
    name: []const u8,
    version: []const u8,
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '@' or c == '_';
}

fn stripTree(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (isIdentStart(line[i])) return line[i..];
    }
    return line[0..0];
}

fn splitNameVer(s: []const u8) ?BunGlobal {
    if (s.len == 0) return null;
    const at: usize = blk: {
        if (s[0] == '@') {
            const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
            const rel = std.mem.indexOfScalar(u8, s[slash + 1 ..], '@') orelse return null;
            break :blk slash + 1 + rel;
        }
        break :blk std.mem.indexOfScalar(u8, s, '@') orelse return null;
    };
    if (at == 0 or at + 1 >= s.len) return null;
    const name = s[0..at];
    var version = s[at + 1 ..];
    if (std.mem.indexOfAny(u8, version, " \t")) |sp| version = version[0..sp];
    if (!jsonbuf.isSafePkgName(name)) return null;
    if (version.len == 0) return null;
    return .{ .name = name, .version = version };
}

/// `bun pm ls -g` prefixes every package row with a box-drawing glyph. The
/// global `node_modules` path it prints on the first line is not a row: with an
/// `@` anywhere in `$HOME` it splits into a package and a version, and the scan
/// offers to remove a directory that is not one.
fn isTreeRow(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "\u{251C}") or std.mem.startsWith(u8, line, "\u{2514}");
}

/// Parse `bun pm ls -g` tree (`name@version` rows). Path headers skipped.
pub fn parseBunGlobalList(text: []const u8, out: []BunGlobal) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!isTreeRow(line)) continue;
        const rest = stripTree(line);
        const hit = splitNameVer(rest) orelse continue;
        out[n] = hit;
        n += 1;
    }
    return n;
}

fn renderBun(hits: []const BunGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"bun\",\"engine\":\"bun\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeRowGuard(&cmd_w, &q_buf, "bun pm ls -g", .{ .after = "@" }, "bun remove -g ", h.name);
        jsonbuf.writeGlobal(&w, h.name, h.version, cmd_w.slice(), "bun");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic bun. Review before running.\\n");
        for (hits) |h| {
            guard.writeRowGuard(&w, &q_buf, "bun pm ls -g", .{ .after = "@" }, "bun remove -g ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove bun globals?\",\"body\":\"User-global bun packages only. Named remove waits for confirm.\"}");
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
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec < 0) {
        if (!renderBun(&.{})) return 1;
        return 0;
    }
    var hits: [128]BunGlobal = undefined;
    var n = parseBunGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderBun, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "parseBunGlobalList tree" {
    var buf: [8]BunGlobal = undefined;
    const text =
        \\/home/user/.bun/install/global/node_modules
        \\├── typescript@5.4.5
        \\└── prettier@3.3.0
        \\
    ;
    const n = parseBunGlobalList(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
    try std.testing.expectEqualStrings("prettier", buf[1].name);
    try std.testing.expectEqualStrings("3.3.0", buf[1].version);
}

test "parseBunGlobalList scoped and empty" {
    var buf: [4]BunGlobal = undefined;
    const n = parseBunGlobalList("└── @vue/cli@5.0.8\n", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("@vue/cli", buf[0].name);
    try std.testing.expectEqualStrings("5.0.8", buf[0].version);
    try std.testing.expectEqual(@as(usize, 0), parseBunGlobalList("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseBunGlobalList("/home/user/.bun/install/global/node_modules\n", &buf));
}

test "plugin_query present JSON comes from bun pm ls -g fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"bun\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "prettier") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bun remove -g typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if bun pm ls -g | grep -qF -- typescript@; then bun remove -g typescript; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bun add") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "package.json") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bun missing") != null);
}

test "parseBunGlobalList skips the node_modules header with an at in the home" {
    var buf: [8]BunGlobal = undefined;
    const text =
        \\/home/first.last@corp.example.com/.bun/install/global/node_modules
        \\├── typescript@5.4.5
        \\└── prettier@3.3.0
        \\
    ;
    const n = parseBunGlobalList(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
    try std.testing.expectEqualStrings("prettier", buf[1].name);
    try std.testing.expectEqualStrings("3.3.0", buf[1].version);
}

// `bun pm ls -g` rows arrive as a box-drawing tree under a `node_modules`
// header line, so the parser has to tell a row from a path with an `@` in it
// before it splits `name@version`. The seeds cover the header, a scoped row,
// a row that stops before the `@`, a row with no version, and the byte
// sequences (NUL, C0, an invalid UTF-8 lead) that break the tree prefix scan.
const fuzz_bun_tree = packFuzzSlice(
    \\/home/user/.bun/install/global/node_modules
    \\├── typescript@5.4.5
    \\└── @vue/cli@5.0.8
);
const fuzz_bun_at_home = packFuzzSlice(
    \\/home/first.last@corp.example.com/.bun/install/global/node_modules
    \\├── typescript@5.4.5
);
const fuzz_bun_truncated = packFuzzSlice(
    \\├── typescript
    \\├── typescript@
    \\├── @scope/
    \\├── @/pkg@1.0.0
    \\├── @scope@1.0.0
);
const fuzz_bun_unsafe = packFuzzSlice(
    \\├── typescript;rm -rf /@1.0.0
    \\├── ../escape@1.0.0
    \\├── -dashname@1.0.0
    \\├── $(id)@1.0.0
);
const fuzz_bun_junk = packFuzzSlice("├── a@1\x00.0\n└� \t\r\n├@1.2.3");
const fuzz_bun_empty = packFuzzSlice("");

test "fuzz parseBunGlobalList" {
    try std.testing.fuzz({}, fuzzBunGlobalList, .{ .corpus = &.{
        &fuzz_bun_tree,
        &fuzz_bun_at_home,
        &fuzz_bun_truncated,
        &fuzz_bun_unsafe,
        &fuzz_bun_junk,
        &fuzz_bun_empty,
    } });
}

fn fuzzBunGlobalList(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var buf: [32]BunGlobal = undefined;
    const n = parseBunGlobalList(text, &buf);
    try std.testing.expect(n <= buf.len);
    for (buf[0..n]) |h| {
        // The name reaches `bun remove -g <name>`, so it must be one the
        // guard accepts and a slice of this input, never a pointer past it.
        try std.testing.expect(jsonbuf.isSafePkgName(h.name));
        try std.testing.expect(sliceInside(text, h.name));
        try std.testing.expect(sliceInside(text, h.version));
        try std.testing.expect(h.version.len > 0);
        // A version stops at the first blank, so whitespace in one means the
        // split ran past the row.
        try std.testing.expect(std.mem.indexOfAny(u8, h.version, " \t\r\n") == null);
        // The split leaves the `@` with the version side; an empty name, or a
        // name still carrying the separator, was never a package row.
        try std.testing.expect(h.name.len > 0);
        try std.testing.expect(h.name[0] != '@' or std.mem.indexOfScalar(u8, h.name, '@') == 0);
    }
}
