const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-xdg-lib",
    .root_label = ".local/lib",
    .root = "/home/user/.local/lib",
    .keep = "dconf\n",
    .missing_note = "~/.local/lib is missing. Plugin inactive.",
    .dialog_title = "Remove leftover libraries?",
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

test "plugin_query present JSON uses lib root" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-lib\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/lib/gone-app") != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
