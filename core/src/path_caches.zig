const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-caches",
    .root_label = "Caches",
    .root = "/Users/user/Library/Caches",
    .keep = "dconf\n",
    .missing_note = "~/Library/Caches is missing. Plugin inactive.",
    .dialog_title = "Remove leftover caches?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses caches root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-caches\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/Caches/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
