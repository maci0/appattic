const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");
const fuzzsupport = @import("fuzzsupport.zig");

const packFuzzSlice = fuzzsupport.packFuzzSlice;
const quoteByConstruction = fuzzsupport.quoteByConstruction;
const isQuotedValue = fuzzsupport.isQuotedValue;

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

/// `if <present>; then <action>; fi` where both halves are whole commands the
/// caller has already built and quoted. For a removal that names more than one
/// value, so neither half is a single appended name, and for a presence check
/// that is a path rather than a manager query.
pub fn writeWholeGuard(w: *jsonbuf.W, present: []const u8, action: []const u8) void {
    w.raw("if ");
    w.raw(present);
    w.raw("; then ");
    w.raw(action);
    w.raw("; fi");
}

/// `if <present> <name>; then <remove> <name>; fi`, where `<present>` is a
/// read-only query that exits 0 only while the package is still installed.
///
/// Every generated script runs under `set -e`, so a second run over a target
/// the first run already removed would exit nonzero there and strand every
/// line below it. The guard makes an already-removed target a no-op. Same
/// `if <query> <name>; then <action> <name>; fi` shape as Swift
/// `guardedRemoveCommand`, without its ` >/dev/null 2>&1`: the query is a
/// package manager or a `test`, so its own output is already the answer. The Qt
/// `rootcmd` escalation reads both the same way.
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

/// `if <present> <name> >/dev/null 2>&1; then <upgrade> <name>; fi`.
///
/// `pacman -S <name>` and `paru -S <name>` on a package that is already at the
/// repo's version is a reinstall, not a no-op: the download, the install
/// scripts, and the database entry all happen again, so a script run twice
/// would do the work twice. `present` is the manager's own update check
/// (`pacman -Qu`, `paru -Qu`), which exits 0 only while the package is still
/// behind: the same question the scan asked, asked again.
///
/// Same shape as `writeWholeGuard` with a name and a redirect, which is the
/// spelling the Qt `commandIsShellSafe` guard already accepts, so the `rootcmd`
/// escalation reads a guarded upgrade like a guarded removal.
pub fn writeUpgradeGuard(
    w: *jsonbuf.W,
    q_buf: []u8,
    present: []const u8,
    upgrade: []const u8,
    name: []const u8,
) void {
    w.raw("if ");
    w.raw(present);
    w.raw(" ");
    jsonbuf.rawShQuote(w, q_buf, name);
    w.raw(" >/dev/null 2>&1; then ");
    w.raw(upgrade);
    w.raw(" ");
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
    writeNameGuard(&w, &q_buf, "test -e /home/user/.deno/bin/", "deno uninstall --global ", "x'; reboot; '");
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got, "if test -e /home/user/.deno/bin/'x'\\''; reboot; '\\'''; then ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "deno uninstall --global 'x'\\''; reboot; '\\'''; fi") != null);
}

test "upgrade guard runs only while the package is still behind" {
    var buf: [512]u8 = undefined;
    var q_buf: [128]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeUpgradeGuard(&w, &q_buf, "pacman -Qu", "pacman --noconfirm -S", "vim");
    try std.testing.expectEqualStrings(
        "if pacman -Qu vim >/dev/null 2>&1; then pacman --noconfirm -S vim; fi",
        w.slice() orelse return error.Overflow,
    );
}

test "upgrade guard quotes an injected name in both halves" {
    var buf: [512]u8 = undefined;
    var q_buf: [128]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeUpgradeGuard(&w, &q_buf, "paru -Qu", "paru --noconfirm -S", "x'; reboot; '");
    try std.testing.expectEqualStrings(
        "if paru -Qu 'x'\\''; reboot; '\\''' >/dev/null 2>&1; then paru --noconfirm -S 'x'\\''; reboot; '\\'''; fi",
        w.slice() orelse return error.Overflow,
    );
}

test "whole guard takes both halves whole" {
    var buf: [512]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    writeWholeGuard(&w, "test -e /var/lib/snapd/snaps/chromium_1846.snap", "snap remove chromium --revision 1846");
    try std.testing.expectEqualStrings(
        "if test -e /var/lib/snapd/snaps/chromium_1846.snap; then snap remove chromium --revision 1846; fi",
        w.slice() orelse return error.Overflow,
    );
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

const fuzz_guard_names = packFuzzSlice("libfoo\nblack\ntypescript\n@scope/pkg\n");
const fuzz_guard_quotes = packFuzzSlice("'\n''\n'''\na'b'c\nx'; reboot; '\n");
const fuzz_guard_shell = packFuzzSlice("$(id)\n`id`\na;rm -rf /\na|sh\na&b\na>b\na\\b\n");
const fuzz_guard_control = packFuzzSlice("a\nb\na\rb\na\x00b\na\x01b\na\x7fb\na\tb\n");
const fuzz_guard_utf8 = packFuzzSlice("café\n日本語\n\xff\n\xc3\n");
const fuzz_guard_flags = packFuzzSlice("--force\n-rf\n--registry=evil\n");
const fuzz_guard_long = packFuzzSlice("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'b\n");
const fuzz_guard_empty = packFuzzSlice("");

test "fuzz the removal guards" {
    try std.testing.fuzz({}, fuzzRemovalGuards, .{ .corpus = &.{
        &fuzz_guard_names,
        &fuzz_guard_quotes,
        &fuzz_guard_shell,
        &fuzz_guard_control,
        &fuzz_guard_utf8,
        &fuzz_guard_flags,
        &fuzz_guard_long,
        &fuzz_guard_empty,
    } });
}

/// The guard is the command the UI hands to `pkexec`, so what a shell reads
/// out of it is the property, not the shape of the text. Both guards are
/// `if <query><value>; then <action><value>; fi`, and the package name reaches
/// the query and the action. A name that breaks out of its quoted slot runs a
/// second command as root, and a name that is dropped or cut removes nothing
/// or the wrong thing. So the command is rebuilt from its parts with an oracle
/// that quotes the slow obvious way, and the two have to be the same string:
/// that pins every splice, and the structure around them, in one assertion.
fn fuzzRemovalGuards(_: void, smith: *std.testing.Smith) !void {
    var raw: [256]u8 = undefined;
    const name = raw[0..smith.slice(&raw)];

    // The queries, actions and row affixes the plugins pass. They are the
    // app's own text, so a name that moved one of them is a splice that did
    // not stay in its slot.
    const present = "apt-get show ";
    const remove = "apt-get purge -y ";
    const list = "npm ls -g --depth=0";
    const before = "package ";
    const after = " ";

    var buf: [4096]u8 = undefined;
    var q_buf: [4096]u8 = undefined;
    var quoted: [4096]u8 = undefined;
    var quoted_row_buf: [4096]u8 = undefined;
    var row: [4096]u8 = undefined;
    var expected: [4096]u8 = undefined;

    const quoted_name = quoteByConstruction(&quoted, name, jsonbuf.isSafeShellByte) orelse return;

    var w = jsonbuf.W{ .buf = &buf };
    writeNameGuard(&w, &q_buf, present, remove, name);
    if (w.failed) return error.TestUnexpectedResult;
    // A name that needs quoting has to reach the UI as a form its guard
    // accepts, or the cleanup is refused at the last step.
    if (!std.mem.eql(u8, quoted_name, name)) {
        try std.testing.expect(isQuotedValue(quoted_name));
    }
    const want = try std.fmt.bufPrint(&expected, "if {s}{s}; then {s}{s}; fi", .{
        present, quoted_name, remove, quoted_name,
    });
    try std.testing.expectEqualStrings(want, w.slice() orelse return error.Overflow);

    // The row guard reads the name through the listing, so the value it greps
    // is the row the manager prints, while the action still takes the name.
    const row_text = try std.fmt.bufPrint(&row, "{s}{s}{s}", .{ before, name, after });
    const quoted_row = quoteByConstruction(&quoted_row_buf, row_text, jsonbuf.isSafeShellByte) orelse return;
    if (!std.mem.eql(u8, quoted_row, row_text)) {
        try std.testing.expect(isQuotedValue(quoted_row));
    }
    var w2 = jsonbuf.W{ .buf = &buf };
    writeRowGuard(&w2, &q_buf, list, .{ .before = before, .after = after }, remove, name);
    if (w2.failed) return error.TestUnexpectedResult;
    const want2 = try std.fmt.bufPrint(&expected, "if {s} | grep -qF -- {s}; then {s}{s}; fi", .{
        list, quoted_row, remove, quoted_name,
    });
    try std.testing.expectEqualStrings(want2, w2.slice() orelse return error.Overflow);
}
