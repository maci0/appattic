const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-application-support",
    .root_label = "Application Support",
    .root = "/Users/user/Library/Application Support",
    .keep = "dconf\n",
    .missing_note = "~/Library/Application Support is missing. Plugin inactive.",
    .dialog_title = "Remove leftover application support?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses application-support root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-application-support\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/Application Support/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
