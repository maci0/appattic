const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-var-app",
    .root_label = ".var/app",
    .root = "/home/user/.var/app",
    .keep = "dconf\n",
    .missing_note = "~/.var/app is missing. Plugin inactive.",
    .dialog_title = "Remove leftover Flatpak data?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses var-app root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-var-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.var/app/gone-app") != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
