const std = @import("std");
const listing = @import("path_listing.zig");

const spec = listing.Spec{
    .id = "path-home-dot",
    .root_label = "home",
    .root = "/home/user",
    .keep = "dconf\n",
    .missing_note = "$HOME is missing. Plugin inactive.",
    .dialog_title = "Remove leftover home dirs?",
    .query_cmd = "ls -1A",
};

comptime {
    listing.bind(spec);
}

test "plugin_query present JSON uses home-dot root" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-home-dot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.mozilla") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.wine") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idleDays\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idleDays\":90") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), listing.query(spec, 0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
