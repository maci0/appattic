const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-xdg-state",
    .root_label = ".local/state",
    .root = "/home/user/.local/state",
    .keep = "dconf\n",
    .missing_note = "~/.local/state is missing. Plugin inactive.",
    .dialog_title = "Remove leftover state?",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses state root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/state/gone-app") != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
