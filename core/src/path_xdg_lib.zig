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

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses lib root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-lib\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/lib/gone-app") != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
