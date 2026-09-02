const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-httpstorages",
    .root_label = "HTTPStorages",
    .root = "/Users/user/Library/HTTPStorages",
    .keep = "dconf\n",
    .missing_note = "~/Library/HTTPStorages is missing. Plugin inactive.",
    .dialog_title = "Remove leftover HTTP storage?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses httpstorages root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-httpstorages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/HTTPStorages/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
