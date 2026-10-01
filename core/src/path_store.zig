const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");

/// Path helpers shared by the path plugins. Findings keep their names and
/// paths in one caller-owned byte store instead of allocating per root.
/// The placeholder a path plugin writes in place of the account's home
/// directory. A guest has no environment, so a root it names has to be a
/// constant; `host.exec` rewrites the placeholder to `$HOME` (or to the XDG
/// root the variable points at) in the argv it executes, and the native shell
/// rewrites it in the finding paths and commands it reads back
/// (`expandHomeUserPlaceholder`, `ui/linux-qt/finding.cpp`). Mirrored on the
/// host as `APPATTIC_HOME_SENTINEL` in `core/host/hostexec.h`.
///
/// Every root a path plugin names starts with this, and a root is either the
/// placeholder itself or the placeholder followed by `/`: the host's rewrite
/// matches the prefix and then requires that boundary, so a root like
/// `/home/userdata` would be listed under a name no account has and turned
/// into an `rm -rf` target from that listing. `isHomeRoot` is that rule, and
/// `path_listing.specById` refuses a table entry that breaks it at compile
/// time rather than at scan time.
pub const home_sentinel = "/home/user";

/// True when `path` is `home_sentinel` or a path below it. Mirrors
/// `rewrite_home_user_argv` in `core/host/hostexec.c`.
pub fn isHomeRoot(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, home_sentinel)) return false;
    const rest = path[home_sentinel.len..];
    return rest.len == 0 or rest[0] == '/';
}

pub fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// Copy `slice` into `store` at `used.*`, or null when the store is full.
/// `used.*` is left where it was on failure.
pub fn copyInto(slice: []const u8, store: []u8, used: *usize) ?[]const u8 {
    if (used.* + slice.len > store.len) return null;
    const start = used.*;
    @memcpy(store[used.*..][0..slice.len], slice);
    used.* += slice.len;
    return store[start..used.*];
}

/// Copy `dir` + '/' + `name` into `store` at `used.*`, or null when the store
/// is full. `used.*` is left where it was on failure.
pub fn joinPath(dir: []const u8, name: []const u8, store: []u8, used: *usize) ?[]const u8 {
    const need = dir.len + 1 + name.len;
    if (used.* + need > store.len) return null;
    const start = used.*;
    @memcpy(store[used.*..][0..dir.len], dir);
    used.* += dir.len;
    store[used.*] = '/';
    used.* += 1;
    @memcpy(store[used.*..][0..name.len], name);
    used.* += name.len;
    return store[start..used.*];
}

/// One octal digit, or null when the byte is not one. `ls -b` spells every
/// byte it does not have a short form for as a backslash and three of these,
/// with no `0` prefix: ESC is `\033`, DEL is `\177`.
fn octalDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '7') return c - '0';
    return null;
}

/// The short forms `ls -b` uses, each two bytes for one. Everything else it
/// escapes goes out as `\NNN`, and the caller handles that.
///
/// `\e` is deliberately absent. `ls -b` writes ESC as `\033`, so decoding
/// `\e` here would turn a name that really does spell those two characters
/// into a control character the listing never carried.
fn lsBEscapeByte(b: u8) ?u8 {
    return switch (b) {
        'n' => 0x0A,
        't' => 0x09,
        'r' => 0x0D,
        'a' => 0x07,
        'b' => 0x08,
        'f' => 0x0C,
        'v' => 0x0B,
        '\\' => '\\',
        else => null,
    };
}

/// Undo `ls -b`'s escaping across a whole listing, in place, and return the
/// length the text now occupies.
///
/// Every escape `ls -b` writes is at least two bytes and stands for exactly
/// one, so the text only ever shrinks and unescaping into the same buffer
/// cannot overwrite a byte it has yet to read. The result is the listing
/// `ls -1` would have printed for names holding no such byte, and a name
/// holding one is back on a single line, which is what every reader here
/// assumes.
///
/// The alternative was splitting `ls -1` output on `\n` and treating each
/// line as a name, and a directory holding one entry called `we<LF>ird` then
/// listed as the two names `we` and `ird`: both pass `jsonbuf.isSafeIdent`,
/// both are joined onto the root, and both become `rm -rf` rows naming paths
/// that do not exist. The Swift tree reads directories with `readdir` and
/// never sees this; it is the `ls` the guest plugins run that turns one name
/// into two.
///
/// A backslash that begins no escape `ls` writes is kept as a backslash and
/// the byte after it is kept too, so an unrecognised pair stays text rather
/// than losing a byte.
pub fn unescapeLsB(buf: []u8) usize {
    var r: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (buf[i] != '\\') {
            buf[r] = buf[i];
            r += 1;
            i += 1;
            continue;
        }
        if (i + 1 < buf.len) {
            if (lsBEscapeByte(buf[i + 1])) |v| {
                buf[r] = v;
                r += 1;
                i += 2;
                continue;
            }
            // `\NNN`, three octal digits and nothing else. A backslash is not
            // among them, so a name spelled `\102` arrives here as `\0102`
            // and is read as the `\010` `ls` escaped it to, followed by `2`.
            if (i + 3 < buf.len) {
                const d0 = octalDigit(buf[i + 1]);
                const d1 = octalDigit(buf[i + 2]);
                const d2 = octalDigit(buf[i + 3]);
                if (d0 != null and d1 != null and d2 != null) {
                    buf[r] = d0.? * 64 + d1.? * 8 + d2.?;
                    r += 1;
                    i += 4;
                    continue;
                }
            }
        }
        buf[r] = '\\';
        r += 1;
        i += 1;
    }
    return r;
}

/// Names an `ls -1b` listing carries, after `unescapeLsB`: one basename per
/// line. Dot names, empty names, and names outside `jsonbuf.isSafeIdent` are
/// dropped. A leading `-` is kept: these names are always joined onto a
/// constant root before they reach a command, so a dash there is inert. A name
/// a package manager reads as its own argument needs `jsonbuf.isSafeCmdIdent`
/// instead.
/// `keep` is a newline name list to skip as well; pass "" for none.
pub fn listingNames(listing: []const u8, names: [][]const u8, keep: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        if (n == names.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name = basenameOf(line);
        if (name.len == 0 or name[0] == '.') continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        if (keep.len != 0 and nameInList(name, keep)) continue;
        names[n] = name;
        n += 1;
    }
    return n;
}

/// Membership in a newline-separated name list. `list` is a keep list, an
/// allow list, or any other set written one name per line; blank lines are
/// skipped and each line is trimmed, so the table entries in path_listing can
/// be indented to match the file.
pub fn nameInList(name: []const u8, list: []const u8) bool {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const k = std.mem.trim(u8, raw, " \t\r");
        if (k.len == 0) continue;
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

test "isHomeRoot takes the placeholder and what is under it" {
    try std.testing.expect(isHomeRoot(home_sentinel));
    try std.testing.expect(isHomeRoot("/home/user/.config"));
    try std.testing.expect(isHomeRoot("/home/user/.local/share/app"));
    try std.testing.expect(!isHomeRoot("/home/userdata"));
    try std.testing.expect(!isHomeRoot("/etc/apt"));
    try std.testing.expect(!isHomeRoot(""));
    try std.testing.expect(!isHomeRoot("/home"));
}

test "basenameOf takes the last path segment" {
    try std.testing.expectEqualStrings("gone-app", basenameOf("/home/user/.local/bin/gone-app"));
    try std.testing.expectEqualStrings("gone-app", basenameOf("gone-app"));
}

test "nameInList matches whole lines only" {
    try std.testing.expect(nameInList("dconf", "dconf\nfonts\n"));
    try std.testing.expect(nameInList("fonts", "dconf\n  fonts  \n"));
    try std.testing.expect(!nameInList("dcon", "dconf\n"));
    try std.testing.expect(!nameInList("", "dconf\n"));
    try std.testing.expect(!nameInList("dconf", ""));
}

test "listingNames skips dot names and unsafe names" {
    var names: [8][]const u8 = undefined;
    const n = listingNames("\n  .mozilla  \ngone-app\nfoo;rm\n", &names, "");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", names[0]);
    try std.testing.expectEqual(
        @as(usize, 0),
        listingNames("dconf\n", &names, "dconf\n"),
    );
}

test "joinPath appends to the store and stops at its bound" {
    var store: [64]u8 = undefined;
    var used: usize = 0;
    const first = joinPath("/home/user/.local/bin", "gone-app", &store, &used).?;
    try std.testing.expectEqualStrings("/home/user/.local/bin/gone-app", first);
    const second = joinPath("/home/user/bin", "other", &store, &used).?;
    try std.testing.expectEqualStrings("/home/user/bin/other", second);
    try std.testing.expectEqualStrings(first, store[0..first.len]);

    var small: [8]u8 = undefined;
    var small_used: usize = 0;
    try std.testing.expectEqual(@as(?[]const u8, null), joinPath("/home/user", "gone-app", &small, &small_used));
    try std.testing.expectEqual(@as(usize, 0), small_used);
}

test "unescapeLsB takes ls -b escaping back off in place" {
    const Case = struct {
        escaped: []const u8,
        plain: []const u8,
    };
    const cases = [_]Case{
        // A name `ls -1` printed as two lines. One line, one name again.
        .{ .escaped = "we\\nird\n", .plain = "we\nird\n" },
        .{ .escaped = "a\\\\b\n", .plain = "a\\b\n" },
        .{ .escaped = "c\\td\n", .plain = "c\td\n" },
        .{ .escaped = "\\102\\033\\177\n", .plain = "B\x1B\x7F\n" },
        .{ .escaped = "\\001ctl\n", .plain = "\x01ctl\n" },
        .{ .escaped = "caf\u{00e9}\nplain-name\n", .plain = "caf\u{00e9}\nplain-name\n" },
        // A name that really does spell `\102` reaches the listing with its
        // backslash escaped first, so the decoder reads `\010` and the `2`
        // after it as two separate things, which is what the name is.
        .{ .escaped = "a\\0102\n", .plain = "a\x082\n" },
        // A backslash that begins no escape ls writes stays a backslash, and
        // the byte after it is not swallowed with it.
        .{ .escaped = "a\\qb\n", .plain = "a\\qb\n" },
        .{ .escaped = "trailing\\\n", .plain = "trailing\\\n" },
        .{ .escaped = "\\", .plain = "\\" },
        .{ .escaped = "", .plain = "" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..c.escaped.len], c.escaped);
        const len = unescapeLsB(buf[0..c.escaped.len]);
        // The text only ever shrinks, which is what makes the in-place pass
        // safe: every escape is at least two bytes and stands for one.
        try std.testing.expect(len <= c.escaped.len);
        try std.testing.expectEqualStrings(c.plain, buf[0..len]);
    }
}

test "unescapeLsB decodes every escape ls -b writes" {
    const pairs = [_][2][]const u8{
        .{ "\\n", "\n" },   .{ "\\t", "\t" },   .{ "\\r", "\r" },
        .{ "\\a", "\x07" }, .{ "\\b", "\x08" }, .{ "\\f", "\x0C" },
        .{ "\\v", "\x0B" }, .{ "\\\\", "\\" },
    };
    for (pairs) |p| {
        var buf: [4]u8 = undefined;
        @memcpy(buf[0..p[0].len], p[0]);
        try std.testing.expectEqual(@as(usize, 1), unescapeLsB(buf[0..p[0].len]));
        try std.testing.expectEqual(p[1][0], buf[0]);
    }
}
