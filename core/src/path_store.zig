const std = @import("std");

/// Path helpers shared by the path plugins. Findings keep their names and
/// paths in one caller-owned byte store instead of allocating per root.
pub fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
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

test "basenameOf takes the last path segment" {
    try std.testing.expectEqualStrings("gone-app", basenameOf("/home/user/.local/bin/gone-app"));
    try std.testing.expectEqualStrings("gone-app", basenameOf("gone-app"));
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
