const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const packFuzzSlice = fuzzsupport.packFuzzSlice;
const sliceInside = fuzzsupport.sliceInside;

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

/// Undo `ls -b`'s escaping across one line, in place, and return the length
/// the text now occupies.
///
/// Every escape `ls -b` writes is at least two bytes and stands for exactly
/// one, so the text only ever shrinks and unescaping into the same buffer
/// cannot overwrite a byte it has yet to read. A line that decoded clean comes
/// back as the line `ls -1` would have printed for a name holding no such byte.
///
/// **Call this on a line, after splitting the listing, never on a whole
/// listing.** A directory holding one entry called `we<LF>ird` lists as the
/// single line `we\nird`, so decoding the whole listing first writes a real LF
/// into the middle of it, and the reader that splits next sees the two names
/// `we` and `ird`: both pass `jsonbuf.isSafeIdent`, both are joined onto the
/// root, and both become `rm` rows naming paths that do not exist. The Swift
/// tree reads directories with `readdir` and never sees this; it is the `ls`
/// the guest plugins run that turns one name into two. `listingNames` splits
/// first and decodes each line, and `parseListing` in `path_listing.zig`
/// inlines the same pass.
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

/// Names an `ls -1b` listing carries: one basename per line, unescaped and
/// trimmed. Dot names, empty names, and names outside `jsonbuf.isSafeIdent`
/// are dropped. A leading `-` is kept: these names are always joined onto a
/// constant root before they reach a command, so a dash there is inert. A name
/// a package manager reads as its own argument needs `jsonbuf.isSafeCmdIdent`
/// instead.
/// `keep` is a newline name list to skip as well; pass "" for none.
///
/// `listing` is the `ls -1b` text and is taken as mutable because each line is
/// unescaped in place, after the split, and every name this returns is a slice
/// of it. The order is the whole point: `ls -b` prints a file named `we<LF>ird`
/// as the single line `we\nird`, so unescaping the whole listing first and
/// splitting afterwards puts a decoded LF back across a line boundary and the
/// one entry becomes the two names `we` and `ird` — both plain ident bytes,
/// both joined onto the root, both `rm` rows naming paths that are not there.
/// Splitting first and unescaping the name leaves the decoded LF inside the
/// name, where `isSafeIdent` refuses it, so the row is dropped instead of
/// doubled.
///
/// The in-place pass is safe for the same reason the whole-listing one was:
/// unescaping only shrinks, so every byte written for a line lands before the
/// `\n` that `splitScalar` has already stopped at, and the scan for the next
/// delimiter never reads a byte this pass moved. The caller hands the buffer
/// over; nothing reads it again afterwards, which is what lets every name here
/// be a slice of it rather than a copy.
/// `parseListing` in `path_listing.zig` inlines the same pass for the same
/// reason.
pub fn listingNames(listing: []u8, names: [][]const u8, keep: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |const_line| {
        if (n == names.len) break;
        const raw: []u8 = @constCast(const_line);
        const line = std.mem.trim(u8, raw[0..unescapeLsB(raw)], " \t\r");
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

const fuzz_listing_names = packFuzzSlice("gone-app\nhtop\ndconf\n.cache-secret\n");
const fuzz_listing_escaped = packFuzzSlice("we\\nird\na\\\\b\nc\\td\n\\102x\nwe\\0102\n");
const fuzz_listing_utf8 = packFuzzSlice("café\nnaïve\n😀\n\xc3\n\xff\xfe\n");
const fuzz_listing_control = packFuzzSlice("a\tb\na\rb\na\x00b\na\x1bb\na\x7fb\n");
const fuzz_listing_dots = packFuzzSlice(".\n..\n./\n.hidden\n..hidden\n");
const fuzz_listing_crlf = packFuzzSlice("  gone-app \r\n\tgone\t \r\n\r\n");
const fuzz_listing_empty = packFuzzSlice("");
const fuzz_listing_blank = packFuzzSlice(" \t \n\n\r\n");
const fuzz_listing_trunc = packFuzzSlice("\\102\\1");
const fuzz_listing_slashes = packFuzzSlice("/\n//\na/\n/a\n./x\n");

test "fuzz an ls -b listing yields one row per entry, cut from the listing" {
    try std.testing.fuzz({}, fuzzListingNames, .{ .corpus = &.{
        &fuzz_listing_names,
        &fuzz_listing_escaped,
        &fuzz_listing_utf8,
        &fuzz_listing_control,
        &fuzz_listing_dots,
        &fuzz_listing_crlf,
        &fuzz_listing_empty,
        &fuzz_listing_blank,
        &fuzz_listing_trunc,
        &fuzz_listing_slashes,
    } });
}

/// Every name this listing reader hands to a removal command is a slice of the
/// listing, and one `ls -1b` entry is one name. A fuzzer on the parser alone
/// cannot say either: the property that broke was the *order* of two passes, so
/// the harness states it. It holds when the entry is one line, when it decodes
/// to a name with no line break in it, and when reading the same listing twice
/// gives the same names.
fn fuzzListingNames(_: void, smith: *std.testing.Smith) !void {
    var seed: [4096]u8 = undefined;
    const escaped = seed[0..smith.slice(&seed)];
    var raw: [4096]u8 = undefined;
    @memcpy(raw[0..escaped.len], escaped);

    var names: [64][]const u8 = undefined;
    const kept = listingNames(raw[0..escaped.len], &names, "");
    try std.testing.expect(kept <= names.len);

    // One entry is one name: no name may carry a line break, and every one is
    // cut from the listing the caller still owns. A reader that unescaped the
    // whole listing before splitting put the decoded LF back across the
    // boundary, so the one entry `we\nird` came back as the two safe names
    // `we` and `ird`, and both became rows.
    for (names[0..kept]) |name| {
        try std.testing.expect(std.mem.indexOfScalar(u8, name, '\n') == null);
        try std.testing.expect(sliceInside(&raw, name));
        // The reader is the only gate between a name and a command, so it
        // keeps the identifier the rest of the core gates on.
        try std.testing.expect(jsonbuf.isSafeIdent(name));
        try std.testing.expect(name[0] != '.');
    }

    // The same escaped text read twice gives the same names. The pass decodes
    // in place, so the second read runs against a fresh copy of the seed
    // rather than the buffer the first read already rewrote.
    var again: [64][]const u8 = undefined;
    var second: [4096]u8 = undefined;
    @memcpy(second[0..escaped.len], escaped);
    const kept2 = listingNames(second[0..escaped.len], &again, "");
    try std.testing.expectEqual(kept, kept2);
    for (names[0..kept], again[0..kept2]) |a, b| {
        try std.testing.expectEqualStrings(a, b);
    }

    // The rows are bounded by the array, not by the listing: a listing with
    // more entries than the array holds stops at the bound.
    var one: [1][]const u8 = undefined;
    try std.testing.expect(listingNames(raw[0..escaped.len], &one, "") <= 1);
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
    var buf: [32]u8 = undefined;
    const listing = "\n  .mozilla  \ngone-app\nfoo;rm\n";
    @memcpy(buf[0..listing.len], listing);
    const n = listingNames(buf[0..listing.len], &names, "");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", names[0]);
    var kept: [8]u8 = undefined;
    @memcpy(kept[0.."dconf\n".len], "dconf\n");
    try std.testing.expectEqual(
        @as(usize, 0),
        listingNames(kept[0.."dconf\n".len], &names, "dconf\n"),
    );
}

test "a name holding a newline is one entry and no row, not two rows" {
    // What `ls -1b` prints for a single file named `we<LF>ird`, and what
    // happens when a file called `we` or `ird` sits beside it in the same
    // directory. Unescaping the listing before splitting it made the entry
    // come back as those two names, both plain ident bytes, and each one was
    // joined onto the root as its own `rm` row for a path that is not there.
    var names: [8][]const u8 = undefined;
    var buf: [64]u8 = undefined;
    const listing = "we\\nird\n";
    @memcpy(buf[0..listing.len], listing);
    try std.testing.expectEqual(
        @as(usize, 0),
        listingNames(buf[0..listing.len], &names, ""),
    );

    // The same reading with a real file beside it: the neighbours are still
    // reported, so the dropped entry is dropped and not the whole listing.
    var with_neighbours: [64]u8 = undefined;
    const mixed = "gone-app\nwe\\nird\nhtop\n";
    @memcpy(with_neighbours[0..mixed.len], mixed);
    const n = listingNames(with_neighbours[0..mixed.len], &names, "");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("gone-app", names[0]);
    try std.testing.expectEqualStrings("htop", names[1]);

    // An escape that decodes to a byte `isSafeIdent` accepts is still one row
    // carrying the decoded byte, so the reader is not simply refusing anything
    // `ls -b` escaped: `\102` is `B`.
    var octal: [64]u8 = undefined;
    const spelled = "go\\102ne-app\n";
    @memcpy(octal[0..spelled.len], spelled);
    try std.testing.expectEqual(
        @as(usize, 1),
        listingNames(octal[0..spelled.len], &names, ""),
    );
    try std.testing.expectEqualStrings("goBne-app", names[0]);

    // A name that decodes to a byte outside the ident class is still refused,
    // so the newline fix did not become a licence to pass anything through.
    var backslash: [64]u8 = undefined;
    const spelled_back = "a\\\\b\n";
    @memcpy(backslash[0..spelled_back.len], spelled_back);
    try std.testing.expectEqual(
        @as(usize, 0),
        listingNames(backslash[0..spelled_back.len], &names, ""),
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
