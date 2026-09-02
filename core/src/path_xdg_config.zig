const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-xdg-config",
    .root_label = ".config",
    .root = "/home/user/.config",
    .keep = "dconf\n",
    .missing_note = "~/.config is missing. Plugin inactive.",
    .dialog_title = "Remove leftover config?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON comes from listing fixture" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "orphan-cfg") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf /home/user/.config/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
