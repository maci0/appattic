const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-launchagents",
    .root_label = "LaunchAgents",
    .root = "/Users/user/Library/LaunchAgents",
    .keep = "dconf\n",
    .missing_note = "~/Library/LaunchAgents is missing. Plugin inactive.",
    .dialog_title = "Remove leftover launch agents?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses launchagents root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-launchagents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/user/Library/LaunchAgents/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
