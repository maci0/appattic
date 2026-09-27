const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");

/// How a manager's own listing spells the row that names one package, so a
/// presence check can grep for it. `npm ls -g` writes `libfoo@1.2.3`, `pipx
/// list` writes `package libfoo 1.2.3`, `uv tool list` writes `libfoo v1.2.3`.
pub const Row = struct {
    before: []const u8 = "",
    after: []const u8 = "",
};

/// The row a listing prints for one package: `before` + name + `after`.
fn composeRow(buf: []u8, row: Row, name: []const u8) ?[]const u8 {
    const need = row.before.len + name.len + row.after.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..row.before.len], row.before);
    @memcpy(buf[row.before.len..][0..name.len], name);
    @memcpy(buf[row.before.len + name.len ..][0..row.after.len], row.after);
    return buf[0..need];
}

/// `if <present> <name>; then <remove> <name>; fi`, where `<present>` is a
/// read-only query that exits 0 only while the package is still installed.
///
/// Every generated script runs under `set -e`, so a second run over a target
/// the first run already removed would exit nonzero there and strand every
/// line below it. The guard makes an already-removed target a no-op. Same
/// shape as Swift `guardedRemoveCommand`, so the Qt `rootcmd` escalation reads
/// both the same way.
pub fn writeNameGuard(
    w: *jsonbuf.W,
    q_buf: []u8,
    present: []const u8,
    remove: []const u8,
    name: []const u8,
) void {
    w.raw("if ");
    w.raw(present);
    jsonbuf.rawShQuote(w, q_buf, name);
    w.raw("; then ");
    w.raw(remove);
    jsonbuf.rawShQuote(w, q_buf, name);
    w.raw("; fi");
}

/// `if <list> | grep -qF -- '<row>'; then <remove> <name>; fi`. For the
/// managers that have no per-package query and answer only with a listing.
pub fn writeRowGuard(
    w: *jsonbuf.W,
    q_buf: []u8,
    list: []const u8,
    row: Row,
    remove: []const u8,
    name: []const u8,
) void {
    w.raw("if ");
    w.raw(list);
    w.raw(" | grep -qF -- ");
    var row_buf: [jsonbuf.max_pkg_name_len + 64]u8 = undefined;
    const composed = composeRow(&row_buf, row, name) orelse {
        w.failed = true;
        return;
    };
    jsonbuf.rawShQuote(w, q_buf, composed);
    w.raw("; then ");
    w.raw(remove);
    jsonbuf.rawShQuote(w, q_buf, name);
    w.raw("; fi");
}

test "name guard skips a target that is already gone" {
    var buf: [256]u8 = undefined;
    var q_buf: [64]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeNameGuard(&w, &q_buf, "dpkg -s ", "apt-get purge -y ", "libfoo");
    try std.testing.expectEqualStrings(
        "if dpkg -s libfoo; then apt-get purge -y libfoo; fi",
        w.slice() orelse return error.Overflow,
    );
}

test "name guard quotes an injected name in both halves" {
    var buf: [512]u8 = undefined;
    var q_buf: [128]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeNameGuard(&w, &q_buf, "test -e ~/.deno/bin/", "deno uninstall --global ", "x'; reboot; '");
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got, "if test -e ~/.deno/bin/'x'\\''; reboot; '\\'''; then ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "deno uninstall --global 'x'\\''; reboot; '\\'''; fi") != null);
}

test "row guard greps the manager listing the parsers already pin" {
    var buf: [512]u8 = undefined;
    var q_buf: [128]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeRowGuard(&w, &q_buf, "npm ls -g --depth=0", .{ .after = "@" }, "npm -g uninstall ", "libfoo");
    try std.testing.expectEqualStrings(
        "if npm ls -g --depth=0 | grep -qF -- libfoo@; then npm -g uninstall libfoo; fi",
        w.slice() orelse return error.Overflow,
    );
}

test "row guard spells a pipx row with its leading and trailing text" {
    var buf: [512]u8 = undefined;
    var q_buf: [128]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeRowGuard(&w, &q_buf, "pipx list", .{ .before = "package ", .after = " " }, "pipx uninstall ", "black");
    try std.testing.expectEqualStrings(
        "if pipx list | grep -qF -- 'package black '; then pipx uninstall black; fi",
        w.slice() orelse return error.Overflow,
    );
}
