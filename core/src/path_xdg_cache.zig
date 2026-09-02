const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-xdg-cache",
    .root_label = ".cache",
    .root = "/home/user/.cache",
    .keep = "fontconfig\nthumbnails\nmesa_shader_cache\ndconf\n",
    .missing_note = "~/.cache is missing. Plugin inactive.",
    .dialog_title = "Remove leftover cache?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses cache root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-cache\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.cache/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
