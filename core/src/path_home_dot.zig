const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-home-dot",
    .root_label = "home",
    .root = "/home/user",
    .keep = "dconf\n",
    .missing_note = "$HOME is missing. Plugin inactive.",
    .dialog_title = "Remove leftover home dirs?",
    .query_cmd = "ls -1A",
};

export fn plugin_abi_version() i32 {
    return listing.abiVersion();
}

export fn plugin_id_ptr() i32 {
    return @intCast(@intFromPtr(spec.id.ptr));
}

export fn plugin_id_len() i32 {
    return @intCast(spec.id.len);
}

export fn plugin_query(present: i32) i32 {
    return listing.query(spec, present);
}

export fn result_ptr() i32 {
    return listing.resultPtr();
}

export fn result_len() i32 {
    return listing.resultLen();
}

test "plugin_query present JSON uses home-dot root" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-home-dot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.mozilla") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.wine") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idleDays\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idleDays\":90") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
