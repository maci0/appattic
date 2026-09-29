const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const guard = @import("guarded_remove.zig");
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
        if (!jsonbuf.isSafeCmdIdent(name) or !jsonbuf.isSafeCmdIdent(rev)) continue;
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
        if (!jsonbuf.isSafeCmdIdent(name)) continue;
        if (nameInList(name, out[0..n])) continue;
        out[n] = name;
        n += 1;
    }
    return n;
}

/// Join `names` into `buf` as one newline-separated keep list.
///
/// A partial list is worse than none: the list is what tells the snap-home
/// probe which `~/snap/<name>` directories belong to a snap that is still
/// installed, and a name that fell off the end makes an installed snap's
/// data directory an orphan with an `rm -rf` line for it. So a buffer that
/// cannot hold every name returns null and the caller reports the loss
/// instead of scanning with a keep list missing names.
fn keepFromNames(names: []const []const u8, buf: []u8) ?[]const u8 {
    var used: usize = 0;
    for (names) |name| {
        const need = if (used != 0) 1 + name.len else name.len;
        if (used + need > buf.len) return null;
        if (used != 0) {
            buf[used] = '\n';
            used += 1;
        }
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

/// Where snapd keeps the image file of one installed revision. `snap remove`
/// takes that file away and exits nonzero when it is already gone, so this is
/// the presence check: the same read the deno plugin makes of its own install
/// dir. A name and a revision both come from `snap list --all` through
/// `isSafeCmdIdent`, so neither holds a `/` and the join cannot leave the dir.
const snap_file_dir = "/var/lib/snapd/snaps/";

/// Room for one half of the guard below: the joined snapd file path, or the
/// removal naming a snap and a revision, each quoted. A name or a revision
/// longer than the package-name bound has no command to write, and the render
/// says so rather than emitting a truncated one.
const max_snap_cmd_len = 512;

/// `if test -e <dir><name>_<rev>.snap; then snap remove <name> --revision
/// <rev>; fi` into `buf`, or null when it does not fit. A removal naming two
/// values, so neither half is one appended name, and the query is a path rather
/// than a manager listing. Each quoted value gets its own buffer, since
/// `shQuote` returns a slice of the one it wrote and the next call would
/// overwrite it under the reader's feet.
///
/// The caller writes the result with `W.str`, not `W.raw`: `shQuote` writes a
/// value containing `'` as `'\''`, and the backslash of that escape is a JSON
/// escape the host parser would reject.
fn snapRemoveCommand(buf: []u8, name: []const u8, rev: []const u8) ?[]const u8 {
    var name_buf: [jsonbuf.max_pkg_name_len + 8]u8 = undefined;
    var rev_buf: [jsonbuf.max_pkg_name_len + 8]u8 = undefined;
    var file_buf: [max_snap_cmd_len]u8 = undefined;
    const file = std.fmt.bufPrint(&file_buf, "{s}{s}_{s}.snap", .{ snap_file_dir, name, rev }) catch return null;
    var present: [max_snap_cmd_len]u8 = undefined;
    const query = std.fmt.bufPrint(&present, "test -e {s}", .{jsonbuf.shQuote(&name_buf, file) orelse return null}) catch return null;
    var action: [max_snap_cmd_len]u8 = undefined;
    const remove = std.fmt.bufPrint(&action, "snap remove {s} --revision {s}", .{
        jsonbuf.shQuote(&name_buf, name) orelse return null,
        jsonbuf.shQuote(&rev_buf, rev) orelse return null,
    }) catch return null;
    var w = jsonbuf.W{ .buf = buf };
    guard.writeWholeGuard(&w, query, remove);
    return w.slice();
}

/// `rm -rf <shell-quoted path>` into `buf`, or null when it does not fit.
fn rmrfCommand(buf: []u8, q_buf: []u8, path: []const u8) ?[]const u8 {
    const quoted = jsonbuf.shQuote(q_buf, path) orelse return null;
    const prefix = "rm -rf ";
    if (prefix.len + quoted.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..quoted.len], quoted);
    return buf[0 .. prefix.len + quoted.len];
}

fn renderSnapd(
    disabled: []const DisabledRev,
    orphans: []const listing.Orphan,
) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    var cmd_buf: [3 * max_snap_cmd_len]u8 = undefined;
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
        w.raw(",\"status\":\"orphaned\",\"command\":");
        w.str(snapRemoveCommand(&cmd_buf, h.name, h.revision) orelse {
            w.failed = true;
            return false;
        });
        w.raw("}");
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
        w.raw(",\"rootLabel\":\"snap\",\"status\":\"orphaned\",\"command\":");
        w.str(rmrfCommand(&cmd_buf, &q_buf, h.path) orelse {
            w.failed = true;
            return false;
        });
        w.raw("}");
    }
    w.raw("],\"script\":");
    if (disabled.len == 0 and orphans.len == 0) {
        w.raw("null");
    } else {
        // The script is one JSON string, so it is built whole and handed to
        // `w.str`. Writing its lines raw would leave a shell quote escape's
        // backslash unescaped in the JSON.
        var script_buf: [8192]u8 = undefined;
        var s_w = jsonbuf.W{ .buf = &script_buf };
        s_w.raw("#!/bin/sh\nset -e\n# AppAttic snapd. Review before running.\n");
        for (disabled) |h| {
            s_w.raw(snapRemoveCommand(&cmd_buf, h.name, h.revision) orelse {
                s_w.failed = true;
                break;
            });
            s_w.raw("\n");
        }
        for (orphans) |h| {
            s_w.raw(rmrfCommand(&cmd_buf, &q_buf, h.path) orelse {
                s_w.failed = true;
                break;
            });
            s_w.raw("\n");
        }
        w.str(s_w.slice() orelse {
            w.failed = true;
            return false;
        });
    }
    w.raw(",\"dialog\":{\"title\":\"Remove snap leftovers?\",\"body\":\"Named disabled revisions and orphan ~/snap dirs only. Installed snap apps stay on Stale Apps. Nothing runs until you confirm.\"}");
    note.write(&w);
    w.raw("}");
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
    note.addTruncatedRows(n_disabled, disabled.len);

    var installed_names: [64][]const u8 = undefined;
    const n_installed = parseInstalledSnapNames(snap_text, installed_names[0..]);
    note.addTruncatedRows(n_installed, installed_names.len);
    // Room for 64 names of 255 bytes each (`NAME_MAX` on `~/snap`, so the
    // longest directory a snap name can make) plus their separators. The parser
    // caps no name length, so a longer row from `snap list --all` overflows
    // this; `keepFromNames` then returns null and the orphan list is skipped
    // whole, rather than built from a partial keep list.
    var keep_buf: [64 * (255 + 1)]u8 = undefined;
    const keep = keepFromNames(installed_names[0..n_installed], &keep_buf);

    var orphans: [32]listing.Orphan = undefined;
    var paths: [1024]u8 = undefined;
    var n_orphans: usize = 0;
    const nls = host_exec.run(snap_home_cmd, &snap_home_exec_buf);
    note.add(snap_home_cmd, nls);
    if (keep) |keep_list| {
        if (nls >= 0) {
            var store_dropped: usize = 0;
            n_orphans = listing.parseListing(
                snap_home_exec_buf[0..@intCast(nls)],
                keep_list,
                snap_home_root,
                &orphans,
                &paths,
                "",
                &store_dropped,
            );
            note.addTruncatedRows(n_orphans, orphans.len);
            note.addDroppedRows(store_dropped);
        }
    } else {
        // No complete keep list, so no orphan list: the snap-home probe
        // cannot tell an installed snap's directory from a leftover one.
        note.addDroppedRows(n_installed);
    }

    return note.renderShrinkingPair(renderSnapd, &disabled, &n_disabled, &orphans, &n_orphans);
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

test "keepFromNames refuses a store that cannot hold every name" {
    // A store too small for the whole list is refused rather than filled to
    // its last byte, because a short list reads as a complete one and turns
    // an installed snap's `~/snap/<name>` into an `rm -rf` line.
    const names = [_][]const u8{ "a", "bb", "ccc", "dddd" };
    var exact: [13]u8 = undefined;
    try std.testing.expectEqualStrings("a\nbb\nccc\ndddd", keepFromNames(&names, &exact).?);
    var short: [12]u8 = undefined;
    try std.testing.expect(keepFromNames(&names, &short) == null);
    var empty: [0]u8 = undefined;
    try std.testing.expect(keepFromNames(&names, &empty) == null);
    try std.testing.expectEqualStrings("", keepFromNames(&.{}, &empty).?);
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
    try std.testing.expect(jsonbuf.isValidJson(json));
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
    // Both the row command and the script line are guarded: `snap remove`
    // exits nonzero for a revision it cannot find, so an unguarded line would
    // stop a rerun of the script at the first already-removed revision and
    // strand the rest.
    const guard_line = "if test -e /var/lib/snapd/snaps/chromium_1846.snap; then " ++
        "snap remove chromium --revision 1846; fi";
    try std.testing.expect(std.mem.indexOf(u8, json, guard_line) != null);
    // core22 is the first revision the script removes, so the header is
    // followed by its guard and the script is a run of guarded lines.
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "# AppAttic snapd. Review before running.\\nif test -e /var/lib/snapd/snaps/core22_1033.snap; " ++
            "then snap remove core22 --revision 1033; fi\\n",
    ) != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}

test "renderSnapd shell-quotes a snap name and an orphan path" {
    const disabled = [_]DisabledRev{.{ .name = "x'; reboot; '", .revision = "1; reboot; '" }};
    const orphans = [_]listing.Orphan{.{ .name = "a b", .path = "/home/user/snap/a'; reboot; '" }};
    try std.testing.expect(renderSnapd(&disabled, &orphans));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    // The injected `;` is inside one single-quoted word, so the script that
    // gets run under pkexec holds one argv entry per value. The backslash of
    // `'\''` is JSON-escaped in the result, so the text carries `\\''`.
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf '/home/user/snap/a'\\\\''; reboot; '\\\\'''") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "snap remove 'x'\\\\''; reboot; '\\\\''' --revision '1; reboot; '") != null);
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
    if (keepFromNames(names[0..nn], &store)) |kept| {
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
    } else {
        // A store too small for the whole list yields nothing at all: a
        // partial keep list would read as a complete one and put an
        // `rm -rf` line on an installed snap's data directory.
        try std.testing.expect(nn > 0);
    }

    // The store is the only bound on the join, so a store of any size can
    // never yield more bytes than it holds. A zero-byte store is the branch
    // where an off-by-one would write the separator alone.
    inline for (.{ 0, 1, 2, 3, 8, 33 }) |cap| {
        var buf: [cap]u8 = undefined;
        if (keepFromNames(names[0..nn], &buf)) |joined| {
            try std.testing.expect(joined.len <= cap);
            try std.testing.expect(sliceInside(&buf, joined));
        } else {
            // Refused rather than short: the list never holds fewer names
            // than were handed to it.
            try std.testing.expect(nn != 0);
        }
    }
}
