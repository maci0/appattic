const listing = @import("path_listing.zig");

/// The plugin is its spec: roots and filtering live in listing.spec_table.
const spec = listing.specById("path-xdg-lib");

comptime {
    listing.bind(spec);
}

test {
    try listing.expectSpecBinds(spec);
}
