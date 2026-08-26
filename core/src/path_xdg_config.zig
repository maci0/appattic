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

pub const XdgOrphan = listing.Orphan;
pub const parseXdgConfigListing = listing.parseListing;

export fn plugin_abi_version() i32 {
    return listing.abiVersion();
}

export fn plugin_id_ptr() i32 {
    return @intCast(@intFromPtr(spec.id.ptr));
}

export fn plugin_id_len() i32 {
    return @intCast(spec.id.len);
}

export fn plugin_query(present: i32) i32 {
    return listing.query(spec, present);
}

export fn result_ptr() i32 {
    return listing.resultPtr();
}

export fn result_len() i32 {
    return listing.resultLen();
}

test "parseXdgConfigListing orphans names not in keep" {
    var hits: [8]XdgOrphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseXdgConfigListing(
        "dconf\ngone-app\nhtop\n",
        "dconf\nhtop\n",
        "/home/user/.config",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.config/gone-app", hits[0].path);
}

test "parseXdgConfigListing accepts full paths, skips . and .., keeps other dots" {
    var hits: [8]XdgOrphan = undefined;
    var paths: [512]u8 = undefined;
    const n = parseXdgConfigListing(
        "/home/user/.config/gone-app\n.config-secret\n.\n..\n\n",
        "",
        "/home/user/.config",
        &hits,
        &paths,
    );
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("gone-app", hits[0].name);
    try std.testing.expectEqualStrings("/home/user/.config/gone-app", hits[0].path);
    try std.testing.expectEqualStrings(".config-secret", hits[1].name);
    try std.testing.expectEqualStrings("/home/user/.config/.config-secret", hits[1].path);
}

test "parseXdgConfigListing empty listing" {
    var hits: [2]XdgOrphan = undefined;
    var paths: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseXdgConfigListing("", "dconf", "/home/user/.config", &hits, &paths));
}

test "plugin_query present JSON comes from listing fixture" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-xdg-config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "orphan-cfg") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf /home/user/.config/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = listing.resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
