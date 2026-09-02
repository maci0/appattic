const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-containers",
    .root_label = "Containers",
    .root = "/Users/user/Library/Containers",
    .keep = "dconf\n",
    .missing_note = "~/Library/Containers is missing. Plugin inactive.",
    .dialog_title = "Remove leftover containers?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses containers root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-containers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/Containers/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
