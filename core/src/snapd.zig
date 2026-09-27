const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const listing = @import("path_listing.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const plugin_id = "snapd";
const query_cmd = "snap list --all";
const snap_home_cmd = "ls -1 /home/user/snap";
const snap_home_root = "/home/user/snap";

pub const DisabledRev = struct {
    name: []const u8,
    revision: []const u8,
};

fn notesHasDisabled(notes: []const u8) bool {
    var it = std.mem.splitScalar(u8, notes, ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "disabled")) return true;
    }
    return false;
}

/// Parse `snap list --all` text. Only rows whose Notes include `disabled`.
/// `out` holds slices into `text`. Returns count written.
pub fn parseSnapListAll(text: []const u8, out: []DisabledRev) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "Name")) continue;
        _ = it.next() orelse continue;
        const rev = it.next() orelse continue;
        var notes: []const u8 = "";
        while (it.next()) |tok| notes = tok;
        if (!notesHasDisabled(notes)) continue;
        if (!jsonbuf.isSafeIdent(name) or !jsonbuf.isSafeIdent(rev)) continue;
        out[n] = .{ .name = name, .revision = rev };
        n += 1;
    }
    return n;
}

fn nameInList(name: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Unique snap names with at least one non-disabled revision in `snap list --all`.
pub fn parseInstalledSnapNames(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "Name")) continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        var notes: []const u8 = "";
        while (it.next()) |tok| notes = tok;
        if (notesHasDisabled(notes)) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        if (nameInList(name, out[0..n])) continue;
        out[n] = name;
        n += 1;
    }
    return n;
}

fn keepFromNames(names: []const []const u8, buf: []u8) []const u8 {
    var used: usize = 0;
    for (names) |name| {
        if (used != 0) {
            if (used >= buf.len) break;
            buf[used] = '\n';
            used += 1;
        }
        if (used + name.len > buf.len) break;
        @memcpy(buf[used..][0..name.len], name);
        used += name.len;
    }
    return buf[0..used];
}

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var snap_home_exec_buf: [16384]u8 = undefined;

const none_json =
    \\{"plugin":"snapd","engine":null,"findings":[],"script":null,"dialog":{"title":"No snapd","body":"snap is not on PATH. Plugin inactive."},"note":"snapd missing"}
;

const snap_list_all_fixture =
    \\Name     Version                     Rev    Tracking         Publisher     Notes
    \\bare     1.0                         5      latest/stable    canonical**   base
    \\core22   20240111                    1122   latest/stable    canonical*    base
    \\core22   20231123                    1033   latest/stable    canonical*    disabled
    \\chromium 120.0.6099.224              1846   latest/stable    canonical**   disabled
    \\core20   20230622                    1974   latest/stable    canonical**   base,disabled
    \\firefox  129.0                       4336   latest/stable    mozilla**     -
    \\
;

fn renderSnapd(
    disabled: []const DisabledRev,
    orphans: []const listing.Orphan,
) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"snapd\",\"engine\":\"snap\",\"findings\":[");
    var first = true;
    for (disabled) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"disabled-revision\",\"id\":\"");
        w.escaped(h.name);
        w.raw("_");
        w.escaped(h.revision);
        w.raw("\",\"name\":");
        w.str(h.name);
        w.raw(",\"revision\":");
        w.str(h.revision);
        w.raw(",\"status\":\"orphaned\",\"command\":\"snap remove ");
        jsonbuf.rawShQuote(&w, &q_buf, h.name);
        w.raw(" --revision ");
        jsonbuf.rawShQuote(&w, &q_buf, h.revision);
        w.raw("\"}");
    }
    for (orphans) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"orphan-dir\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"rootLabel\":\"snap\",\"status\":\"orphaned\",\"command\":\"rm -rf ");
        jsonbuf.rawShQuote(&w, &q_buf, h.path);
        w.raw("\"}");
    }
    w.raw("],\"script\":");
    if (disabled.len == 0 and orphans.len == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic snapd. Review before running.\\n");
        for (disabled) |h| {
            w.raw("snap remove ");
            jsonbuf.rawShQuote(&w, &q_buf, h.name);
            w.raw(" --revision ");
            jsonbuf.rawShQuote(&w, &q_buf, h.revision);
            w.raw("\\n");
        }
        for (orphans) |h| {
            w.raw("rm -rf ");
            jsonbuf.rawShQuote(&w, &q_buf, h.path);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove snap leftovers?\",\"body\":\"Named disabled revisions and orphan ~/snap dirs only. Installed snap apps stay on Stale Apps. Nothing runs until you confirm.\"}}");
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
    const nexec = host_exec.run(query_cmd, &exec_buf);
    note.add(query_cmd, nexec);
    if (nexec < 0) {
        if (!renderSnapd(&.{}, &.{})) return 1;
        return 0;
    }
    const snap_text = exec_buf[0..@intCast(nexec)];
    var disabled: [32]DisabledRev = undefined;
    var n_disabled = parseSnapListAll(snap_text, &disabled);

    var installed_names: [64][]const u8 = undefined;
    const n_installed = parseInstalledSnapNames(snap_text, installed_names[0..]);
    var keep_buf: [512]u8 = undefined;
    const keep = keepFromNames(installed_names[0..n_installed], &keep_buf);

    var orphans: [32]listing.Orphan = undefined;
    var paths: [1024]u8 = undefined;
    var n_orphans: usize = 0;
    const nls = host_exec.run(snap_home_cmd, &snap_home_exec_buf);
    note.add(snap_home_cmd, nls);
    if (nls >= 0) {
        n_orphans = listing.parseListing(
            snap_home_exec_buf[0..@intCast(nls)],
            keep,
            snap_home_root,
            &orphans,
            &paths,
            "",
        );
    }

    while (true) {
        if (renderSnapd(disabled[0..n_disabled], orphans[0..n_orphans])) return 0;
        if (n_orphans > 0) {
            n_orphans -= 1;
            continue;
        }
        if (n_disabled > 0) {
            n_disabled -= 1;
            continue;
        }
        return 1;
    }
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "parseSnapListAll keeps disabled revisions only" {
    var buf: [8]DisabledRev = undefined;
    const n = parseSnapListAll(snap_list_all_fixture, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("core22", buf[0].name);
    try std.testing.expectEqualStrings("1033", buf[0].revision);
    try std.testing.expectEqualStrings("chromium", buf[1].name);
    try std.testing.expectEqualStrings("1846", buf[1].revision);
    try std.testing.expectEqualStrings("core20", buf[2].name);
    try std.testing.expectEqualStrings("1974", buf[2].revision);
}

test "parseInstalledSnapNames keeps active snaps only" {
    var buf: [16][]const u8 = undefined;
    const n = parseInstalledSnapNames(snap_list_all_fixture, buf[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("bare", buf[0]);
    try std.testing.expectEqualStrings("core22", buf[1]);
    try std.testing.expectEqualStrings("firefox", buf[2]);
}

test "parseSnapListAll empty and header-only" {
    var buf: [4]DisabledRev = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseSnapListAll("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseSnapListAll("Name Version Rev Tracking Publisher Notes\n", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseSnapListAll("firefox  129.0  4336  latest/stable  mozilla**  -\n", &buf));
}

test "plugin_query present JSON comes from snap list --all fixture" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"snapd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "disabled-revision") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "chromium") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1846") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1033") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "snap remove chromium --revision 1846") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "orphan-dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf /home/user/snap/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/snap/firefox") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "snap remove --purge") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm /usr/bin/snap") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}

test "renderSnapd shell-quotes a snap name and an orphan path" {
    const disabled = [_]DisabledRev{.{ .name = "x'; reboot; '", .revision = "1; reboot; '" }};
    const orphans = [_]listing.Orphan{.{ .name = "a b", .path = "/home/user/snap/a'; reboot; '" }};
    try std.testing.expect(renderSnapd(&disabled, &orphans));
    const json = result_buf[0..result_nbytes];
    // The injected `;` is inside one single-quoted word, so the script that
    // gets run under pkexec holds one argv entry per value.
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf '/home/user/snap/a'\\''; reboot; '\\'''") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "snap remove 'x'\\''; reboot; '\\''' --revision '1; reboot; '") != null);
    // Unquoted, the name would have ended the word and run a second command.
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf /home/user/snap/a'; reboot; '") == null);
    // The finding id is JSON, so a quote in the name must be escaped there too.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"x'; reboot; '_1; reboot; '\"") != null);
}

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const fuzz_snap_fixture = packFuzzSlice(
    \\Name     Version                     Rev    Tracking         Publisher     Notes
    \\bare     1.0                         5      latest/stable    canonical**   base
    \\core22   20240111                    1122   latest/stable    canonical*    base
    \\core22   20231123                    1033   latest/stable    canonical*    disabled
    \\chromium 120.0.6099.224              1846   latest/stable    canonical**   disabled
    \\core20   20230622                    1974   latest/stable    canonical**   base,disabled
    \\firefox  129.0                       4336   latest/stable    mozilla**     -
    \\
);
const fuzz_snap_header = packFuzzSlice("Name Version Rev Tracking Publisher Notes\n");
const fuzz_snap_empty = packFuzzSlice("");
const fuzz_snap_ws = packFuzzSlice(" \t\r\n  \n\t\n");
const fuzz_snap_trunc = packFuzzSlice("core22  20231123  1033  latest/sta");
const fuzz_snap_short_rows = packFuzzSlice("core22\ncore22  1\ncore22  1  2\ncore22  1  2  3  disabled\n");
const fuzz_snap_notes = packFuzzSlice("a 1 2 t p disabled\nb 1 2 t p disabled,disabled\nc 1 2 t p xdisabled\nd 1 2 t p DISABLED\n");
const fuzz_snap_shell = packFuzzSlice("x'; reboot; ' 1; reboot; ' t p disabled\n$(id) 1 t p disabled\n`id` 1 t p disabled\nrm -rf / 1 t p disabled\n");
const fuzz_snap_utf8 = packFuzzSlice("café 1 2 t p disabled\nnaïve 1 2 t p disabled\n\xff\xfe 1 2 t p disabled\n");
const fuzz_snap_dupes = packFuzzSlice("core22 1 2 t p disabled\ncore22 3 4 t p disabled\ncore22 5 6 t p -\n");
const fuzz_snap_crlf = packFuzzSlice("core22\t1\t2\tt\tp\tdisabled\r\n\r\n");

test "fuzz snap list parsers" {
    try std.testing.fuzz({}, fuzzSnapList, .{ .corpus = &.{
        &fuzz_snap_fixture,
        &fuzz_snap_header,
        &fuzz_snap_empty,
        &fuzz_snap_ws,
        &fuzz_snap_trunc,
        &fuzz_snap_short_rows,
        &fuzz_snap_notes,
        &fuzz_snap_shell,
        &fuzz_snap_utf8,
        &fuzz_snap_dupes,
        &fuzz_snap_crlf,
    } });
}

/// `snap list --all` is a table of names and revisions the scanner turns into
/// `snap remove --revision N` and `rm -rf` script lines, so every field that
/// reaches a finding has to be a safe ident sliced from the listing.
fn fuzzSnapList(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var disabled: [16]DisabledRev = undefined;
    const nd = parseSnapListAll(text, &disabled);
    try std.testing.expect(nd <= disabled.len);
    for (disabled[0..nd]) |row| {
        try std.testing.expect(sliceInside(text, row.name));
        try std.testing.expect(sliceInside(text, row.revision));
        try std.testing.expect(jsonbuf.isSafeIdent(row.name));
        try std.testing.expect(jsonbuf.isSafeIdent(row.revision));
        // Only a disabled row is a finding, and a disabled row whose snap is
        // still installed must not be a duplicate of a name already emitted.
        try std.testing.expect(!std.ascii.eqlIgnoreCase(row.name, "Name"));
    }

    var names: [16][]const u8 = undefined;
    const nn = parseInstalledSnapNames(text, &names);
    try std.testing.expect(nn <= names.len);
    for (names[0..nn], 0..) |name, i| {
        try std.testing.expect(sliceInside(text, name));
        try std.testing.expect(jsonbuf.isSafeIdent(name));
        // The parser dedups: a snap with any active revision appears once.
        for (names[0..i]) |earlier| {
            try std.testing.expect(!std.mem.eql(u8, earlier, name));
        }
    }
    // A snap can be both installed and have a disabled old revision, so the
    // two parsers overlap by design; only each one's own output is checked.

    // keepFromNames is what bounds the snap-home probe list, so its output
    // must always be whole names joined by single newlines: no leading,
    // trailing, or doubled separator, and nothing truncated mid-name.
    var store: [64]u8 = undefined;
    const kept = keepFromNames(names[0..nn], &store);
    try std.testing.expect(sliceInside(&store, kept));
    try std.testing.expect(kept.len == 0 or kept[kept.len - 1] != '\n');
    if (nn != 0 and kept.len != 0) try std.testing.expect(kept[0] != '\n');
    try std.testing.expect(std.mem.indexOf(u8, kept, "\n\n") == null);
    var lines = std.mem.splitScalar(u8, kept, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        seen += 1;
        try std.testing.expect(jsonbuf.isSafeIdent(line));
        // A name is dropped whole or kept whole, never clipped to the store.
        try std.testing.expect(std.mem.indexOf(u8, text, line) != null);
    }
    try std.testing.expect(seen <= nn);

    // The store is the only bound on the join, so a store of any size can
    // never yield more bytes than it holds. A zero-byte store is the branch
    // where an off-by-one would write the separator alone.
    inline for (.{ 0, 1, 2, 3, 8, 33 }) |cap| {
        var buf: [cap]u8 = undefined;
        const joined = keepFromNames(names[0..nn], &buf);
        try std.testing.expect(joined.len <= cap);
        try std.testing.expect(sliceInside(&buf, joined));
    }
}
