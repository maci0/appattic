const std = @import("std");
const listing = @import("path_listing.zig");

/// The plugin is its spec: roots and filtering live in listing.spec_table.
const spec = listing.specById("path-xdg-config");

comptime {
    listing.bind(spec);
}

test {
    std.testing.refAllDecls(@This());
    try listing.expectSpecBinds(spec);
}
