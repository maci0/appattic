const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-saved-state",
    .root_label = "Saved Application State",
    .root = "/Users/user/Library/Saved Application State",
    .keep = "dconf\n",
    .missing_note = "~/Library/Saved Application State is missing. Plugin inactive.",
    .dialog_title = "Remove leftover saved state?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses saved-state root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-saved-state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/Saved Application State/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
