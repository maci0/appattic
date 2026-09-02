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

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses data root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/share/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
