const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-xdg-data",
    .root_label = ".local/share",
    .root = "/home/user/.local/share",
    .keep = "applications\nicons\nthemes\nflatpak\nmime\ndconf\n",
    .missing_note = "~/.local/share is missing. Plugin inactive.",
    .dialog_title = "Remove leftover data?",
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

test "plugin_query present JSON uses data root" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/share/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
