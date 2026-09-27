const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");

/// Path helpers shared by the path plugins. Findings keep their names and
/// paths in one caller-owned byte store instead of allocating per root.
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

/// Names an `ls -1` listing carries: one basename per line, dot names and
/// names a shell or a package manager would read as an option or a command
/// dropped. `keep` is a newline name list to skip as well; pass "" for none.
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
