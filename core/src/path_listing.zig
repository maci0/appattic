const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const pstore = @import("path_store.zig");
const fuzzsupport = @import("fuzzsupport.zig");

pub const Orphan = struct {
    name: []const u8,
    path: []const u8,
};

pub const Spec = struct {
    id: []const u8,
    root_label: []const u8,
    root: []const u8,
    keep: []const u8,
    missing_note: []const u8,
    dialog_title: []const u8,
    /// `ls -1Ab` for home-dot leftovers (`.mozilla`, `.wine`). Others: `ls -1b`.
    ///
    /// `-b` is what keeps a name that holds a newline on one line: `ls -1`
    /// prints such an entry as two lines, and both halves pass
    /// `jsonbuf.isSafeIdent` and are joined onto the root, so one leftover
    /// became two `rm -rf` rows for paths that do not exist. The escaping is
    /// left on through the split and `parseListing` unescapes each name as it
    /// reads it, so `isSafeIdent` sees the real bytes and drops such a row.
    query_cmd: []const u8 = "ls -1b",
    /// If non-empty, only these names (newline list) are leftovers. Home-dot
    /// is a whitelist; other path plugins stay denylist-only.
    allow: []const u8 = "",
};

/// The contract `root` has to keep for the host's rewrite and for `ls`:
/// under the home placeholder, and free of whitespace because `host.exec`
/// splits a command on it. `specById` checks a table entry at compile time;
/// this is the rule it checks, exposed so the table and the check cannot
/// drift apart.
pub fn rootIsWellFormed(root: []const u8) bool {
    return pstore.isHomeRoot(root) and std.mem.indexOfAny(u8, root, " \t") == null;
}

/// Every spec-only path plugin in one table: the roots differ, the code does
/// not. Each root module names its spec here and binds it, so adding a path
/// root is a table entry instead of another copy of the plugin.
pub const spec_table = [_]Spec{
    .{
        .id = "path-home-dot",
        .root_label = "home",
        .root = pstore.home_sentinel,
        .keep = "dconf\n",
        .missing_note = "$HOME is missing. Plugin inactive.",
        .dialog_title = "Remove leftover home dirs?",
        .query_cmd = "ls -1Ab",
        .allow = ".mozilla\n.thunderbird\n.steam\n.wine\n.java\n.gradle\n.android\n.m2\n",
    },
    .{
        .id = "path-var-app",
        .root_label = ".var/app",
        .root = pstore.home_sentinel ++ "/.var/app",
        .keep = "dconf\n",
        .missing_note = "~/.var/app is missing. Plugin inactive.",
        .dialog_title = "Remove leftover Flatpak data?",
    },
    .{
        .id = "path-xdg-cache",
        .root_label = ".cache",
        .root = pstore.home_sentinel ++ "/.cache",
        .keep = "fontconfig\nthumbnails\nmesa_shader_cache\ndconf\n",
        .missing_note = "~/.cache is missing. Plugin inactive.",
        .dialog_title = "Remove leftover cache?",
    },
    .{
        .id = "path-xdg-config",
        .root_label = ".config",
        .root = pstore.home_sentinel ++ "/.config",
        .keep = "dconf\n",
        .missing_note = "~/.config is missing. Plugin inactive.",
        .dialog_title = "Remove leftover config?",
    },
    .{
        .id = "path-xdg-data",
        .root_label = ".local/share",
        .root = pstore.home_sentinel ++ "/.local/share",
        .keep = "applications\nicons\nthemes\nflatpak\nmime\ndconf\n",
        .missing_note = "~/.local/share is missing. Plugin inactive.",
        .dialog_title = "Remove leftover data?",
    },
    .{
        .id = "path-xdg-lib",
        .root_label = ".local/lib",
        .root = pstore.home_sentinel ++ "/.local/lib",
        .keep = "dconf\n",
        .missing_note = "~/.local/lib is missing. Plugin inactive.",
        .dialog_title = "Remove leftover libraries?",
    },
    .{
        .id = "path-xdg-state",
        .root_label = ".local/state",
        .root = pstore.home_sentinel ++ "/.local/state",
        .keep = "dconf\n",
        .missing_note = "~/.local/state is missing. Plugin inactive.",
        .dialog_title = "Remove leftover state?",
    },
};

/// The spec a root module binds, checked at compile time.
pub fn specById(comptime id: []const u8) Spec {
    inline for (spec_table) |spec| {
        if (comptime std.mem.eql(u8, spec.id, id)) {
            // A root the host cannot rewrite, or that `ls` cannot be handed,
            // is a compile error rather than a scan of something else: the
            // names that come back are joined onto this root and become
            // `rm -rf` lines, so a wrong root is a wrong deletion target.
            if (comptime !rootIsWellFormed(spec.root)) {
                @compileError("root " ++ spec.root ++ " for " ++ spec.id ++
                    " must be the home placeholder or a path under it, with no whitespace");
            }
            return spec;
        }
    }
    @compileError("no path plugin spec named " ++ id);
}

/// `ls` the leftover root. The root is always named: a root with whitespace
/// would split into extra argv tokens and the host refuses the command, which
/// the plugin reports as a command that did not answer. Dropping the root
/// instead used to make `ls` list the process working directory, and those
/// names were then joined onto the root that was never listed.
pub fn queryCommand(comptime spec: Spec) []const u8 {
    return spec.query_cmd ++ " " ++ spec.root;
}

const linux_system_names = @embedFile("linux-system-names.txt");

/// Entry count and lowered-byte total the embedded list needs, measured at
/// comptime. The tables are sized from these instead of from round numbers: a
/// name that does not fit a fixed table is dropped, and a dropped name reads
/// as a leftover orphan, so the table would grow an `rm -rf` for a system
/// directory the day someone added enough lines. Sizing from the file makes
/// that unreachable, and a list that no longer fits is a compile error rather
/// than a silent truncation at scan time.
const sys_table_entries = blk: {
    @setEvalBranchQuota(10000);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, linux_system_names, '\n');
    while (it.next()) |raw| {
        if (std.mem.trim(u8, raw, " \t\r").len != 0) n += 1;
    }
    break :blk n;
};

const sys_table_bytes = blk: {
    @setEvalBranchQuota(10000);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, linux_system_names, '\n');
    while (it.next()) |raw| n += std.mem.trim(u8, raw, " \t\r").len;
    break :blk n;
};

/// Longest name in the list, so the candidate buffer below cannot be the
/// thing that decides a system name is not one.
const sys_table_max_name = blk: {
    @setEvalBranchQuota(10000);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, linux_system_names, '\n');
    while (it.next()) |raw| {
        n = @max(n, std.mem.trim(u8, raw, " \t\r").len);
    }
    break :blk n;
};

/// Sorted table of the embedded names, stored lowered. Parsed once on first
/// use into static storage (WASM plugins are single-threaded; no atomics).
/// The old code re-split and re-trimmed the whole text per candidate with
/// `eqlIgnoreCase` per entry: ~1.5 µs per miss. Binary search: ~8 probes.
var sys_name_table: [sys_table_entries][]const u8 = undefined;
var sys_name_count: usize = 0;
var sys_table_low: [sys_table_bytes]u8 = undefined;
var sys_table_ready: bool = false;

fn ensureSysTable() void {
    if (sys_table_ready) return;
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, linux_system_names, '\n');
    while (lines.next()) |raw| {
        const k = std.mem.trim(u8, raw, " \t\r");
        if (k.len == 0) continue;
        std.debug.assert(sys_name_count < sys_name_table.len);
        std.debug.assert(used + k.len <= sys_table_low.len);
        for (k) |c| {
            sys_table_low[used] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            used += 1;
        }
        sys_name_table[sys_name_count] = sys_table_low[used - k.len .. used];
        sys_name_count += 1;
    }
    std.debug.assert(used == sys_table_low.len);
    std.debug.assert(sys_name_count == sys_name_table.len);
    // Insertion sort: one entry per line of the embedded table, trivial.
    var i: usize = 1;
    while (i < sys_name_count) : (i += 1) {
        const key = sys_name_table[i];
        var j: usize = i;
        while (j > 0 and std.mem.order(u8, key, sys_name_table[j - 1]) == .lt) {
            sys_name_table[j] = sys_name_table[j - 1];
            j -= 1;
        }
        sys_name_table[j] = key;
    }
    sys_table_ready = true;
}

/// Case-insensitive membership in the system-names table. The candidate is
/// lowered into a buffer sized from the longest table entry, so no name the
/// list can hold is skipped for want of buffer.
fn nameInSysTable(name: []const u8) bool {
    if (name.len == 0 or name.len > sys_table_max_name) return false;
    ensureSysTable();
    var low: [sys_table_max_name]u8 = undefined;
    for (name, 0..) |c, i| low[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    const key = low[0..name.len];
    var lo: usize = 0;
    var hi: usize = sys_name_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, sys_name_table[mid], key)) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

const snap_system_names = [_][]const u8{
    "bare",
    "core",
    "snapd",
    "gtk-common-themes",
    "gtk3-common-themes",
    "cups",
    "mesa-2404",
};

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Prefixes a name carries to belong to a desktop environment or a runtime, not
/// to an app whose owner is gone. `core` is not here: it also has to be followed
/// by a version.
const system_name_prefixes = [_][]const u8{
    "gtk-",
    "kde",
    "kwin",
    "baloo",
    "plasma",
    "xdg",
};

/// Same rules as Swift `classifyLinuxSystemName`: these are not leftover orphans.
pub fn isSystemLeftoverName(name: []const u8) bool {
    var n = name;
    while (n.len > 0 and n[0] == '.') n = n[1..];
    if (n.len == 0) return false;
    if (nameInSysTable(n)) return true;
    for (snap_system_names) |s| {
        if (std.ascii.eqlIgnoreCase(s, n)) return true;
    }
    for (system_name_prefixes) |prefix| {
        if (n.len >= prefix.len and std.ascii.eqlIgnoreCase(n[0..prefix.len], prefix)) return true;
    }
    if (n.len > 2 and (n[n.len - 2] == 'r' or n[n.len - 2] == 'R') and (n[n.len - 1] == 'c' or n[n.len - 1] == 'C')) {
        if (nameInSysTable(n[0 .. n.len - 2])) return true;
    }
    if (n.len >= 4 and std.ascii.eqlIgnoreCase(n[0..4], "core")) {
        if (n.len == 4 or isAllDigits(n[4..])) return true;
    }
    if (n.len > 6 and std.ascii.eqlIgnoreCase(n[0..6], "gnome-")) {
        if (std.mem.lastIndexOfScalar(u8, n, '-')) |dash| {
            if (isAllDigits(n[dash + 1 ..])) return true;
        }
    }
    return false;
}

/// Parse `ls -1b` / `ls -1Ab` of a leftover root. Skip `.` and `..`,
/// Linux/snap system names, and names in `keep` (newline list).
///
/// `dropped` counts the rows the path store could not hold. A name that is a
/// leftover but has nowhere to put its joined path is still a leftover, so it
/// belongs in the note: `addTruncatedRows` covers the `out` array running
/// full, and a full store used to shorten the list in the same silent way until
/// `addDroppedRows` gave it the same `note` field.
pub fn parseListing(
    listing: []const u8,
    keep: []const u8,
    root: []const u8,
    out: []Orphan,
    path_store: []u8,
    allow: []const u8,
    dropped: *usize,
) usize {
    var n: usize = 0;
    var used: usize = 0;
    dropped.* = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // The row is still `ls -b` text here. Unescaping it before the split
        // put a name carrying a newline back across a line boundary, so one
        // leftover became two rows joined onto the root, and both halves are
        // plain ident bytes. Splitting first and unescaping the name here is
        // what keeps the row count the way `ls -1b` printed it.
        const escaped_name = pstore.basenameOf(line);
        if (escaped_name.len == 0) continue;
        if (std.mem.eql(u8, escaped_name, ".") or std.mem.eql(u8, escaped_name, "..")) continue;
        // Room for the unescaped name, which is never longer than the escaped
        // one: every `ls -b` escape is at least two bytes and stands for one.
        if (used + escaped_name.len > path_store.len) {
            dropped.* += 1;
            continue;
        }
        const name_start = used;
        @memcpy(path_store[used..][0..escaped_name.len], escaped_name);
        used += escaped_name.len;
        const name_len = pstore.unescapeLsB(path_store[name_start..used]);
        const name = path_store[name_start..][0..name_len];
        // `isSafeIdent` now sees the real bytes, so a name holding a newline,
        // a backslash, or any other escaped byte is dropped here rather than
        // becoming an `rm -rf` row for a path that does not exist.
        if (!jsonbuf.isSafeIdent(name)) continue;
        if (isSystemLeftoverName(name)) continue;
        if (pstore.nameInList(name, keep)) continue;
        if (allow.len > 0 and !pstore.nameInList(name, allow)) continue;
        // The path is always `root` joined with the validated basename, never
        // the line as printed. `ls -1` prints a bare basename, so a line that
        // is already absolute is accepted only when it says exactly that; a
        // listing that spells out anything else (`/root/../../etc`) is dropped
        // rather than turned into an `rm -rf` target.
        const joined = pstore.joinPath(root, name, path_store, &used) orelse {
            dropped.* += 1;
            continue;
        };
        if (line[0] == '/' and !std.mem.eql(u8, line, joined)) continue;
        out[n] = .{ .name = name, .path = joined };
        n += 1;
    }
    return n;
}

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var exec_buf: [65536]u8 = undefined;
var none_json_buf: [512]u8 = undefined;

fn renderRows(spec: Spec, hits: []const Orphan) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":");
    w.str(spec.id);
    w.raw(",\"engine\":null,\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"orphan-dir\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"rootLabel\":");
        w.str(spec.root_label);
        w.raw(",\"status\":\"orphaned\"");
        jsonbuf.writeRmCommand(&w, &q_buf, "rm -rf ", h.path);
        w.raw("}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        // Built whole and escaped once: the `'\''` that `shQuote` writes for a
        // value holding a quote would be a broken JSON escape if the lines were
        // written raw.
        var script_buf: [8192]u8 = undefined;
        var s_w = jsonbuf.W{ .buf = &script_buf };
        s_w.raw("#!/bin/sh\nset -e\n# AppAttic ");
        s_w.raw(spec.id);
        s_w.raw(". Review before running.\n");
        for (hits) |h| {
            s_w.raw("rm -rf ");
            s_w.raw(jsonbuf.shQuote(&q_buf, h.path) orelse {
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
    w.raw(",\"dialog\":{\"title\":");
    w.str(spec.dialog_title);
    w.raw(",\"body\":\"Named dirs only. Nothing runs until you confirm.\"}");
    note.write(&w);
    w.raw("}");
    const s = w.slice() orelse {
        result_nbytes = 0;
        return false;
    };
    result_nbytes = @intCast(s.len);
    return true;
}

fn missingJson(comptime spec: Spec) []const u8 {
    var w = jsonbuf.W{ .buf = &none_json_buf };
    w.raw("{\"plugin\":");
    w.str(spec.id);
    w.raw(",\"engine\":null,\"findings\":[],\"script\":null,\"dialog\":{\"title\":\"No leftover root\",\"body\":");
    w.str(spec.missing_note);
    w.raw("},\"note\":\"path missing\"}");
    return w.slice() orelse "{}";
}

/// The `Spec` a render needs beside its list, so the shared single-list
/// shrinker can call `render` and every path plugin does not keep its own copy
/// of the shrink loop. See `querynote.callRender`.
const WithSpec = struct {
    spec: Spec,
    pub fn render(self: WithSpec, hits: []const Orphan) bool {
        return renderRows(self.spec, hits);
    }
};

pub fn query(comptime spec: Spec, present: i32) i32 {
    note = .{};
    if (present == 0) {
        const none = missingJson(spec);
        plugin_abi.publishMissing(result_buf[0..], &result_nbytes, none);
        return 0;
    }
    const nexec = host_exec.run(queryCommand(spec), &exec_buf);
    note.add(queryCommand(spec), nexec);
    if (nexec < 0) {
        if (!renderRows(spec, &.{})) return 1;
        return 0;
    }
    var hits: [256]Orphan = undefined;
    var paths: [32768]u8 = undefined;
    var store_dropped: usize = 0;
    // The listing is handed to parseListing with `ls -b` escaping still on it.
    // Unescaping it here instead would put a name holding a newline back across
    // a line boundary before the split, which is the bug parseListing now
    // handles: it splits first and unescapes each name as it reads it.
    var n = parseListing(exec_buf[0..@intCast(nexec)], spec.keep, spec.root, &hits, &paths, spec.allow, &store_dropped);
    note.addTruncatedRows(n, hits.len);
    note.addDroppedRows(store_dropped);
    return note.renderShrinking(WithSpec{ .spec = spec }, &hits, &n);
}

pub fn resultSlice() []const u8 {
    return result_buf[0..result_nbytes];
}

/// WASM ABI for one leftover-root plugin. Each `path_*.zig` is a separate
/// compilation; `comptime { listing.bind(spec); }` exports the guest symbols.
pub fn bind(comptime spec: Spec) void {
    const SpecQuery = struct {
        fn run(present: i32) i32 {
            return query(spec, present);
        }
    };
    plugin_abi.bind(spec.id, SpecQuery.run, &result_buf, &result_nbytes);
}

test "a note lands inside the result object" {
    const spec = Spec{
        .id = "path-xdg-config",
        .root_label = ".config",
        .root = "/home/user/.config",
        .keep = "",
        .missing_note = "",
        .dialog_title = "Remove leftover config?",
    };
    note = .{};
    note.add("ls -1b /home/user/.config", host_exec.fail);
    try std.testing.expect(renderRows(spec, &.{}));
    note = .{};
    try std.testing.expect(jsonbuf.isValidJson(resultSlice()));
}

test "parseListing orphans names not in keep" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        "dconf\ngone-app\nhtop\n",
        "dconf\nhtop\n",
        "/home/user/.local/share",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.local/share/gone-app", hits[0].path);
}

test "parseListing keeps home-dot leftovers and skips only . and .." {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        ".mozilla\n.wine\n.\n..\ndconf\n",
        "dconf\n",
        "/home/user",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(".mozilla", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.mozilla", hits[0].path);
    try std.testing.expectEqualStrings(".wine", hits[1].name);
    try std.testing.expectEqualStrings("/home/user/.wine", hits[1].path);
}

test "parseListing accepts full paths, skips . and .., keeps other dots" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        "/home/user/.cache/gone-app\n.cache-secret\n.\n..\n\n",
        "",
        "/home/user/.cache",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.cache/gone-app", hits[0].path);
    try std.testing.expectEqualStrings(".cache-secret", hits[1].name);
    try std.testing.expectEqualStrings("/home/user/.cache/.cache-secret", hits[1].path);
}

test "parseListing drops an absolute line that is not root joined with the name" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    // The basename validates, so only the path spelling can keep
    // `/home/user/.cache/../../etc` from becoming an `rm -rf` argument.
    const n = parseListing(
        "/home/user/.cache/../../etc\n/home/user/.cache/gone-app\n",
        "",
        "/home/user/.cache",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("/home/user/.cache/gone-app", hits[0].path);
}

test "parseListing empty listing" {
    var hits: [2]Orphan = undefined;
    var paths: [64]u8 = undefined;
    var dropped: usize = 0;
    try std.testing.expectEqual(@as(usize, 0), parseListing("", "dconf", "/home/user/.config", &hits, &paths, "", &dropped));
}

test "parseListing keeps utf8 leftover names" {
    var hits: [4]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        "café\ngone-app\n",
        "",
        "/home/user/.config",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("café", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.config/café", hits[0].path);
    try std.testing.expectEqualStrings("gone-app", hits[1].name);
}

test "a name holding a newline is one row, not two" {
    // `we` and `ird`, both passed `isSafeIdent` and were joined onto the root,
    // so one leftover became two `rm -rf` rows naming paths that do not exist.
    // The listing is handed over still escaped, exactly as the reader does:
    // the row is one line, and unescaping the name inside it is what exposes
    // the newline to `isSafeIdent`, which drops the row.
    const listing = "we\\nird\n";

    var hits: [4]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(listing, "", "/home/user/.config", &hits, &paths, "", &dropped);
    try std.testing.expectEqual(@as(usize, 0), n);

    // The escaped form is what the name unescapes to, kept honest here rather
    // than only through `parseListing`: `\n` is the two bytes `ls -b` writes
    // for one LF, and a listing carrying the real LF is two rows again.
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..8], "we\\nird\n");
    try std.testing.expectEqualStrings("we\nird\n", buf[0..pstore.unescapeLsB(buf[0..8])]);

    // A name whose only escape is a backslash is a real entry too, and
    // `isSafeIdent` refuses the backslash, so it is dropped rather than
    // turned into a path that names something else.
    const n2 = parseListing("a\\\\b\n", "", "/home/user/.config", &hits, &paths, "", &dropped);
    try std.testing.expectEqual(@as(usize, 0), n2);

    var buf2: [32]u8 = undefined;
    @memcpy(buf2[0..5], "a\\\\b\n");
    try std.testing.expectEqualStrings("a\\b\n", buf2[0..pstore.unescapeLsB(buf2[0..5])]);

    // The names around it are untouched: escaping only ever shrinks, so a
    // listing with nothing to unescape is the text `ls -1` printed.
    var buf3: [64]u8 = undefined;
    @memcpy(buf3[0..21], "gone-app\nplain-name\n\n");
    try std.testing.expectEqual(@as(usize, 21), pstore.unescapeLsB(buf3[0..21]));
    const n3 = parseListing(buf3[0..21], "", "/home/user/.config", &hits, &paths, "", &dropped);
    try std.testing.expectEqual(@as(usize, 2), n3);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.config/gone-app", hits[0].path);
    try std.testing.expectEqualStrings("plain-name", hits[1].name);
}

test "queryCommand always names the root" {
    const linux = Spec{
        .id = "path-xdg-config",
        .root_label = ".config",
        .root = "/home/user/.config",
        .keep = "",
        .missing_note = "",
        .dialog_title = "",
    };
    try std.testing.expectEqualStrings("ls -1b /home/user/.config", queryCommand(linux));
    const home_dot = Spec{
        .id = "path-home-dot",
        .root_label = "home",
        .root = "/home/user",
        .keep = "",
        .missing_note = "",
        .dialog_title = "",
        .query_cmd = "ls -1Ab",
    };
    try std.testing.expectEqualStrings("ls -1Ab /home/user", queryCommand(home_dot));
    // A root the host cannot take is named and refused, not dropped: dropping
    // it made `ls` list the process working directory, and those names were
    // then joined onto a root the run never listed.
    const spaced = Spec{
        .id = "path-xdg-config",
        .root_label = "Application Support",
        .root = "/home/user/Application Support",
        .keep = "",
        .missing_note = "",
        .dialog_title = "",
    };
    try std.testing.expectEqualStrings("ls -1b /home/user/Application Support", queryCommand(spaced));
    try std.testing.expect(!rootIsWellFormed(spaced.root));
}

test "every spec table root is a path the host can rewrite and ls can take" {
    for (spec_table) |spec| {
        try std.testing.expect(rootIsWellFormed(spec.root));
    }
    try std.testing.expect(!rootIsWellFormed("/etc/apt/sources.list.d"));
    try std.testing.expect(!rootIsWellFormed("/home/userdata"));
    try std.testing.expect(!rootIsWellFormed(pstore.home_sentinel ++ "/Application Support"));
    try std.testing.expect(rootIsWellFormed(pstore.home_sentinel ++ "/.config"));
}

test "render keeps a large leftover list" {
    const spec = Spec{
        .id = "path-xdg-config",
        .root_label = ".config",
        .root = "/home/user/.config",
        .keep = "",
        .missing_note = "",
        .dialog_title = "Remove leftover config?",
    };
    var hits: [80]Orphan = undefined;
    var names: [80][12]u8 = undefined;
    var paths: [80][48]u8 = undefined;
    for (0..80) |i| {
        const n = std.fmt.bufPrint(&names[i], "app-{d:0>2}", .{i}) catch unreachable;
        const p = std.fmt.bufPrint(&paths[i], "/home/user/.config/{s}", .{n}) catch unreachable;
        hits[i] = .{ .name = n, .path = p };
    }
    try std.testing.expect(renderRows(spec, &hits));
    try std.testing.expect(std.mem.indexOf(u8, resultSlice(), "app-00") != null);
    try std.testing.expect(std.mem.indexOf(u8, resultSlice(), "app-79") != null);
}

test "parseListing skips system names even without keep" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        "gtk-3.0\n.git\n.ssh\n.aws\n.docker\ngnome-42\ncore22\ngone-app\n",
        "",
        "/home/user/.config",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expect(isSystemLeftoverName("gtk-3.0"));
    try std.testing.expect(isSystemLeftoverName("go-build"));
    try std.testing.expect(isSystemLeftoverName("swift-build"));
    try std.testing.expect(isSystemLeftoverName("kubebuilder-envtest"));
    try std.testing.expect(isSystemLeftoverName("kdeconnect"));
    try std.testing.expect(isSystemLeftoverName("kwinrc"));
    try std.testing.expect(isSystemLeftoverName("plasma-org.kde.plasma.desktop-appletsrc"));
    try std.testing.expect(isSystemLeftoverName("dolphinrc"));
    try std.testing.expect(isSystemLeftoverName("baloofilerc"));
    try std.testing.expect(isSystemLeftoverName(".ssh"));
    try std.testing.expect(isSystemLeftoverName(".aws"));
    try std.testing.expect(isSystemLeftoverName(".docker"));
    try std.testing.expect(isSystemLeftoverName("dconf"));
    try std.testing.expect(!isSystemLeftoverName("gone-app"));
    try std.testing.expect(!isSystemLeftoverName(".mozilla"));
    try std.testing.expect(!isSystemLeftoverName("git-cola"));
    try std.testing.expect(!isSystemLeftoverName("docker-desktop"));
    try std.testing.expect(!isSystemLeftoverName("npm-check-updates"));
}

test "parseListing home-dot allowlist skips .config and shell rc" {
    var hits: [8]Orphan = undefined;
    var paths: [512]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        ".mozilla\n.config\n.bashrc\n.local\n.cache\n.wine\n.profile\n",
        "dconf\n",
        "/home/user",
        &hits,
        &paths,
        ".mozilla\n.wine\n",
        &dropped,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(".mozilla", hits[0].name);
    try std.testing.expectEqualStrings(".wine", hits[1].name);
}

/// Runtime check for one table spec, so the inline loop below can pass the
/// spec into a comptime parameter.
pub fn expectSpecBinds(comptime spec: Spec) !void {
    try std.testing.expectEqual(@as(i32, 0), query(spec, 1));
    const json = resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, spec.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, spec.root) != null);
    // The fixture feeds `ls -1b` or `ls -1Ab` per spec; both list leftovers.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") == null);
    // `keep` names are not leftovers for any of these roots.
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
    try std.testing.expectEqual(@as(i32, 0), query(spec, 0));
    try std.testing.expect(std.mem.indexOf(u8, resultSlice(), "\"findings\":[]") != null);
}

test "every spec-only path plugin binds, filters and reports" {
    inline for (spec_table) |spec| try expectSpecBinds(spec);
    // Home-dot is the one whitelist root: shell rc files stay.
    const dot = comptime specById("path-home-dot");
    try std.testing.expectEqual(@as(i32, 0), query(dot, 1));
    const json = resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.mozilla") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.wine") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, ".bashrc") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, ".config") == null);
}

const sliceInside = fuzzsupport.sliceInside;
const packFuzzSlice = fuzzsupport.packFuzzSlice;

const fuzz_listing_names = packFuzzSlice("dconf\ngone-app\nhtop\n.cache-secret\n");
const fuzz_listing_abs = packFuzzSlice("/home/user/.cache/gone-app\n.cache-secret\n.\n..\n\n");
const fuzz_listing_home_dot = packFuzzSlice(".mozilla\n.wine\n.\n..\n.bashrc\ndconf\n");
const fuzz_listing_systems = packFuzzSlice("gtk-3.0\n.git\n.ssh\n.aws\n.docker\ngnome-42\ncore22\ndolphinrc\nxrc\n");
const fuzz_listing_shell = packFuzzSlice("x'; reboot; '\nrm -rf /\n$(id)\n`id`\na b\na|b\n~/x\n--flag\n");
const fuzz_listing_utf8 = packFuzzSlice("café\nnaïve\n\u{1F600}\n\xc3\n\xff\xfe\n");
const fuzz_listing_crlf = packFuzzSlice("  gone-app \r\n\tgone\t \r\n\rcr-app\r\n");
const fuzz_listing_dupes = packFuzzSlice("gone-app\ngone-app\n./gone-app\n../gone-app\n/home/user/x/gone-app\n");
const fuzz_listing_trunc = packFuzzSlice("gone-ap");
const fuzz_listing_empty = packFuzzSlice("");
const fuzz_listing_ws = packFuzzSlice(" \t \n\n\r");
const fuzz_listing_slashes = packFuzzSlice("/\n//\n///\na/\n/a\n./x\n");
const fuzz_listing_long = packFuzzSlice("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");

test "fuzz parseListing" {
    try std.testing.fuzz({}, fuzzParseListing, .{ .corpus = &.{
        &fuzz_listing_names,
        &fuzz_listing_abs,
        &fuzz_listing_home_dot,
        &fuzz_listing_systems,
        &fuzz_listing_shell,
        &fuzz_listing_utf8,
        &fuzz_listing_crlf,
        &fuzz_listing_dupes,
        &fuzz_listing_trunc,
        &fuzz_listing_empty,
        &fuzz_listing_ws,
        &fuzz_listing_slashes,
        &fuzz_listing_long,
    } });
}

/// `parseListing` turns directory names an untrusted process (any program that
/// can write into a leftover root) chose into `rm -rf` lines the UI runs under
/// pkexec. Every spec in the table is exercised each round so the whitelist
/// root and the denylist roots share one corpus.
fn fuzzParseListing(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];

    var dropped: usize = 0;
    for (spec_table) |spec| {
        var hits: [16]Orphan = undefined;
        var paths: [2048]u8 = undefined;
        const n = parseListing(text, spec.keep, spec.root, &hits, &paths, spec.allow, &dropped);
        try std.testing.expect(n <= hits.len);
        for (hits[0..n]) |hit| {
            // The name is a copy in the store, unescaped from the row it was
            // read out of. It is not a slice of the listing: an `ls -b` name
            // holding an escape has to be decoded before anything can judge
            // it, and the decoded bytes do not exist in the listing text.
            // The store is what both the name and the joined path live in, so
            // that is the buffer each is checked against.
            try std.testing.expect(sliceInside(&paths, hit.name));
            // A leftover that reaches the script must survive shell quoting
            // unchanged, so nothing the parser kept can carry a metacharacter.
            // This is the assertion that catches an escape left undecoded: the
            // backslash of `\n` is not an ident byte, so a name the parser
            // failed to unescape is refused here.
            try std.testing.expect(jsonbuf.isSafeIdent(hit.name));
            try std.testing.expect(!isSystemLeftoverName(hit.name));
            try std.testing.expect(!pstore.nameInList(hit.name, spec.keep));
            if (spec.allow.len != 0) try std.testing.expect(pstore.nameInList(hit.name, spec.allow));

            // The path is a root-joined copy inside the store, never the line
            // as printed. A path from anywhere else is a pointer into a dead
            // frame.
            try std.testing.expect(sliceInside(&paths, hit.path));
            try std.testing.expectEqualStrings(hit.name, pstore.basenameOf(hit.path));
            const joined = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ spec.root, hit.name });
            defer std.testing.allocator.free(joined);
            try std.testing.expectEqualStrings(joined, hit.path);
        }

        // `out` is fixed, so a listing longer than it must stop at the bound
        // instead of writing past it.
        var one: [1]Orphan = undefined;
        var one_path: [16]u8 = undefined;
        const n1 = parseListing(text, spec.keep, spec.root, &one, &one_path, spec.allow, &dropped);
        try std.testing.expect(n1 <= 1);
        if (n1 == 1) {
            try std.testing.expect(sliceInside(&one_path, one[0].path) or sliceInside(text, one[0].path));
        }
    }
}

test "the system-name table holds every line of the embedded list" {
    ensureSysTable();
    var expected: usize = 0;
    var it = std.mem.splitScalar(u8, linux_system_names, '\n');
    while (it.next()) |raw| {
        if (std.mem.trim(u8, raw, " \t\r").len == 0) continue;
        expected += 1;
    }
    try std.testing.expectEqual(expected, sys_name_count);
    try std.testing.expectEqual(expected, sys_name_table.len);
    // Every entry is reachable: the table is sorted and the search is a
    // binary search over it, so a name that never compares equal is a name
    // the scan would report as a deletable leftover.
    for (sys_name_table[0..sys_name_count]) |entry| {
        try std.testing.expect(nameInSysTable(entry));
        var upper: [sys_table_max_name]u8 = undefined;
        for (entry, 0..) |c, i| {
            upper[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        try std.testing.expect(nameInSysTable(upper[0..entry.len]));
    }
}

test "a full finding array reaches the result JSON as a note" {
    // The plugin's own array is 256 rows; a listing past that is a machine
    // with more leftovers than the table holds, which is the case that used to
    // report the first 256 as if they were all of them.
    var listing: [4096]u8 = undefined;
    var used: usize = 0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const line = try std.fmt.bufPrint(listing[used..], "gone-{d}\n", .{i});
        used += line.len;
    }
    var hits: [256]Orphan = undefined;
    var paths: [32768]u8 = undefined;
    const spec = specById("path-xdg-data");
    var dropped: usize = 0;
    const n = parseListing(listing[0..used], spec.keep, spec.root, &hits, &paths, spec.allow, &dropped);
    try std.testing.expectEqual(hits.len, n);

    var log = querynote.Log{};
    log.addTruncatedRows(n, hits.len);
    var buf: [256]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    log.write(&w);
    try std.testing.expectEqualStrings(
        ",\"note\":\"1 list hit the row limit: more rows exist than were shown\"",
        w.slice().?,
    );
}

test "a path store that fills is a dropped row, not a short scan" {
    // The store is smaller than the joined paths of the listing, so the
    // parser runs out of room with leftovers still to account for. `out` is
    // nowhere near full, so `addTruncatedRows` sees nothing: without the
    // store's own count this list reads as the whole root.
    var hits: [16]Orphan = undefined;
    var paths: [64]u8 = undefined;
    var dropped: usize = 0;
    const n = parseListing(
        "gone-app-one\ngone-app-two\ngone-app-three\n",
        "",
        "/home/user/.local/share",
        &hits,
        &paths,
        "",
        &dropped,
    );
    try std.testing.expect(n < 3);
    try std.testing.expectEqual(@as(usize, 3 - n), dropped);

    var log = querynote.Log{};
    log.addDroppedRows(dropped);
    var buf: [128]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    log.write(&w);
    try std.testing.expectEqualStrings(
        ",\"note\":\"1 list hit the row limit: more rows exist than were shown\"",
        w.slice().?,
    );
}
