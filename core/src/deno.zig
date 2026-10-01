const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const path_store = @import("path_store.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const plugin_id = "deno";
// `-b`, like every other directory listing this core reads: `ls` escapes the
// bytes that would otherwise break the listing's one-entry-per-line shape, and
// `parseDenoGlobalList` takes the escaping back off per line after the split.
const query_cmd = "ls -1b " ++ path_store.home_sentinel ++ "/.deno/bin";

var result_buf: [8192]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"deno","engine":null,"findings":[],"script":null,"dialog":{"title":"No deno","body":"deno is not on PATH. Plugin inactive."},"note":"deno missing"}
;

pub const DenoGlobal = struct {
    name: []const u8,
};

fn skipName(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "deno") or std.mem.eql(u8, name, "deno.exe");
}

/// Parse `ls -1b ~/.deno/bin`. Dot names and the `deno` / `deno.exe` runtime are
/// skipped; everything else that passes `jsonbuf.isSafeCmdIdent` is reported.
///
/// Each line is unescaped in place *after* the split, which is the order every
/// other listing reader here uses and the only one that keeps one entry one
/// row. `ls -1` prints a binary named `we\nird` as the two lines `we` and
/// `ird`, both of which pass `isSafeCmdIdent`, so one entry became two
/// `deno uninstall --global` rows for names that were never on disk. With `-b`
/// the entry stays one line, the decode puts the real newline back inside the
/// name, and `isSafeCmdIdent` drops it there.
pub fn parseDenoGlobalList(text: []u8, out: []DenoGlobal) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |const_line| {
        if (n == out.len) break;
        const raw: []u8 = @constCast(const_line);
        const line = std.mem.trim(u8, raw[0..path_store.unescapeLsB(raw)], " \t\r");
        if (line.len == 0) continue;
        const name = path_store.basenameOf(line);
        if (skipName(name)) continue;
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
        out[n] = .{ .name = name };
        n += 1;
    }
    return n;
}

/// The presence check every guarded removal opens with, and the half the
/// guard wrapper appends the quoted name to. `test -e <prefix><name>` has to
/// name a path `/bin/sh` resolves, because the guard runs in the generated
/// script and not through `host.exec`. `~` is not one: tilde expansion is an
/// interactive-shell extension that POSIX `sh` does not perform, so a script
/// carrying `test -e ~/.deno/bin/name` tests a directory named `~` under the
/// working directory, finds nothing, and skips the removal on every run. It
/// also fails the embedder's byte gate for a scripted command, which refuses
/// `~` outright.
///
/// The sentinel is what the query above already uses, and it is what the
/// embedder expands: `core/host/hostexec.c` rewrites it in `host.exec` argv,
/// and the Qt ingest rewrites it in `command` and `update_command`, so a guard
/// that carries it reaches the script as the account's real home.
const presence_check = "test -e " ++ path_store.home_sentinel ++ "/.deno/bin/";

// The `-b` in the query is the control for the newline case, so it is pinned
// rather than assumed: without it `ls` prints the entry holding a newline as
// two lines and `parseDenoGlobalList` accepts both halves as two removals.
test "the deno listing asks ls to escape the names" {
    try std.testing.expect(std.mem.indexOf(u8, query_cmd, "ls -1b ") != null);
    try std.testing.expect(std.mem.endsWith(u8, query_cmd, "/.deno/bin"));
}

fn renderDeno(hits: []const DenoGlobal) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"deno\",\"engine\":\"deno\",\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        var cmd_w = jsonbuf.W{ .buf = &cmd_buf };
        guard.writeNameGuard(&cmd_w, &q_buf, presence_check, "deno uninstall --global ", h.name);
        jsonbuf.writeGlobal(&w, h.name, "", cmd_w.slice(), "deno");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic deno. Review before running.\\n");
        for (hits) |h| {
            guard.writeNameGuard(&w, &q_buf, presence_check, "deno uninstall --global ", h.name);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove Deno globals?\",\"body\":\"User-global Deno installs in ~/.deno/bin only. Named uninstall waits for confirm.\"}");
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
        if (!renderDeno(&.{})) return 1;
        return 0;
    }
    var hits: [128]DenoGlobal = undefined;
    var n = parseDenoGlobalList(exec_buf[0..@intCast(nexec)], &hits);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderDeno, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "parseDenoGlobalList skips runtime" {
    var buf: [8]DenoGlobal = undefined;
    const text = "deno\n" ++ "file_server\n" ++ "deployctl\n" ++ "\n";
    var listing: [text.len]u8 = undefined;
    @memcpy(&listing, text);
    const n = parseDenoGlobalList(&listing, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("file_server", buf[0].name);
    try std.testing.expectEqualStrings("deployctl", buf[1].name);
}

test "parseDenoGlobalList empty and unsafe" {
    var buf: [4]DenoGlobal = undefined;
    var empty: [1]u8 = undefined;
    empty[0] = '\n';
    try std.testing.expectEqual(@as(usize, 0), parseDenoGlobalList(empty[0..0], &buf));
    var runtime = [_]u8{ 'd', 'e', 'n', 'o', '\n' };
    try std.testing.expectEqual(@as(usize, 0), parseDenoGlobalList(&runtime, &buf));
    var injected = [_]u8{ 'f', 'o', 'o', ';', 'r', 'm', '\n' };
    try std.testing.expectEqual(@as(usize, 0), parseDenoGlobalList(&injected, &buf));
}

// With `-b` in the query, an entry whose name holds a byte `ls` must escape
// arrives as one line carrying a backslash, and `isSafeCmdIdent` refuses it:
// a backslash is not an ident byte. One entry in, no row out, rather than the
// two rows the unescaped `ls -1` listing turned that one entry into. The
// plain entry beside it is the control, so this also pins that a name `ls`
// prints verbatim still becomes a removal.
test "parseDenoGlobalList drops an escaped name and keeps a plain one" {
    var buf: [8]DenoGlobal = undefined;
    // What `ls -1b` prints: the escaped entry on one line, then a plain one.
    var listing = [_]u8{
        'w', 'e',  '\\', 'n', 'i', 'r', 'd', '\n',
        'd', 'e',  'p',  'l', 'o', 'y', 'c', 't',
        'l', '\n',
    };
    const n = parseDenoGlobalList(&listing, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("deployctl", buf[0].name);
}

// Every escape `ls -b` writes is refused, so no entry whose name holds a byte
// needing one can reach a removal command as a row for the escaped spelling.
// The plain entry is the control: `ls` prints it verbatim, so it must survive.
test "parseDenoGlobalList drops every escape ls -b writes" {
    var buf: [8]DenoGlobal = undefined;
    var listing = [_]u8{
        't', 'a',  'b', '\\', 't',  'h',  'e', 'r',  'e', '\n',
        'b', 'a',  'c', 'k',  '\\', '\\', 's', 'l',  'a', 'n',
        'd', '\n', 'p', 'l',  'a',  'i',  'n', '\n',
    };
    const n = parseDenoGlobalList(&listing, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("plain", buf[0].name);
}

test "plugin_query present JSON comes from deno bin listing fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"deno\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "file_server") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deployctl") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deno uninstall --global file_server") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "if test -e " ++ path_store.home_sentinel ++ "/.deno/bin/file_server; then deno uninstall --global file_server; fi") != null);
    // The guard runs in a generated `/bin/sh` script, which performs no tilde
    // expansion: `test -e ~/.deno/bin/name` tests a directory named `~` under
    // the working directory, never finds it, and skips the removal on every
    // run. Only the sentinel, which the embedder expands to the account's real
    // home, survives that. The dialog body still spells the directory the way a
    // person reads it; this is about the shell line.
    try std.testing.expect(std.mem.indexOf(u8, json, "test -e ~") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "; then deno uninstall --global ~") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"deno\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deno install") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "deno missing") != null);
}

// `ls -1b ~/.deno/bin` prints one entry per line, each a full path whose last
// component becomes the name of a `deno uninstall --global <name>` command.
// The seeds cover the runtime entry that must be skipped, a path with no
// directory, trailing slashes and `..`, names the command guard rejects, and
// the bytes (NUL, C0, invalid UTF-8) a directory name can hold on disk.
const fuzz_deno_listing = packFuzzSlice(
    \\deno
    \\/home/user/.deno/bin/deployctl
    \\/home/user/.deno/bin/file_server
);
const fuzz_deno_paths = packFuzzSlice(
    \\/home/user/.deno/bin/
    \\/home/user/.deno/bin/../escape
    \\/home/user/.deno/bin/.hidden
    \\trailing/slash/
);
const fuzz_deno_unsafe = packFuzzSlice(
    \\/home/user/.deno/bin/foo;rm -rf /
    \\/home/user/.deno/bin/-dash
    \\/home/user/.deno/bin/$(id)
    \\/home/user/.deno/bin/with space
);
const fuzz_deno_junk = packFuzzSlice("/home/user/.deno/bin/a\x00b\n\t\r\n/home/user/.deno/bin/\xff");
// What `ls -b` writes for the names the unescaped seeds imply: the escaped
// form of a newline, a tab, a backslash and a carriage return, so the corpus
// exercises the decode the reader now runs and not only the shape it replaced.
const fuzz_deno_escaped = packFuzzSlice(
    \\/home/user/.deno/bin/we\nird
    \\/home/user/.deno/bin/tab\there
    \\/home/user/.deno/bin/back\\slash
    \\/home/user/.deno/bin/car\rriage
    \\/home/user/.deno/bin/plain
);
const fuzz_deno_empty = packFuzzSlice("");

test "fuzz parseDenoGlobalList" {
    try std.testing.fuzz({}, fuzzDenoGlobalList, .{ .corpus = &.{
        &fuzz_deno_listing,
        &fuzz_deno_paths,
        &fuzz_deno_unsafe,
        &fuzz_deno_junk,
        &fuzz_deno_escaped,
        &fuzz_deno_empty,
    } });
}

fn fuzzDenoGlobalList(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var buf: [32]DenoGlobal = undefined;
    const n = parseDenoGlobalList(text, &buf);
    try std.testing.expect(n <= buf.len);
    for (buf[0..n]) |h| {
        // The name reaches a shell command, so it must pass the ident guard
        // and be a slice of this input, not a pointer past it.
        try std.testing.expect(jsonbuf.isSafeCmdIdent(h.name));
        try std.testing.expect(sliceInside(text, h.name));
        try std.testing.expect(h.name.len > 0);
        // `basenameOf` keeps what follows the last separator, so no reported
        // name carries a path, and the runtime never becomes a finding.
        try std.testing.expect(std.mem.indexOfScalar(u8, h.name, '/') == null);
        try std.testing.expect(!std.mem.eql(u8, h.name, "deno"));
        try std.testing.expect(!std.mem.eql(u8, h.name, "deno.exe"));
    }
}
