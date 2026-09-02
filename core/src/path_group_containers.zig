const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-group-containers",
    .root_label = "Group Containers",
    .root = "/Users/user/Library/Group Containers",
    .keep = "dconf\n",
    .missing_note = "~/Library/Group Containers is missing. Plugin inactive.",
    .dialog_title = "Remove leftover group containers?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses group-containers root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-group-containers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/Group Containers/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
