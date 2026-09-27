const std = @import("std");
const fuzzsupport = @import("fuzzsupport.zig");

const packFuzzSlice = fuzzsupport.packFuzzSlice;
const isQuotedValue = fuzzsupport.isQuotedValue;
const unquote = fuzzsupport.unquote;

/// Fixed-buffer JSON writer for WASM plugins. No allocator.
pub const W = struct {
    buf: []u8,
    i: usize = 0,
    failed: bool = false,

    pub fn raw(self: *W, s: []const u8) void {
        if (self.failed) return;
        if (self.i + s.len > self.buf.len) {
            self.failed = true;
            return;
        }
        @memcpy(self.buf[self.i..][0..s.len], s);
        self.i += s.len;
    }

    pub fn str(self: *W, s: []const u8) void {
        self.raw("\"");
        self.escaped(s);
        self.raw("\"");
    }

    /// ASCII byte that goes into the output unchanged.
    fn plainAscii(c: u8) bool {
        return c >= 0x20 and c < 0x80 and c != '"' and c != '\\';
    }

    /// Escape for a JSON string body, without the surrounding quotes. Use
    /// inside a string the writer has already opened. Bytes that need no
    /// escape are copied in runs: a path or a package name is mostly plain
    /// ASCII, and one `raw` per byte made a finding cost one memcpy call per
    /// character.
    pub fn escaped(self: *W, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            var run = i;
            while (run < s.len and plainAscii(s[run])) run += 1;
            if (run > i) {
                self.raw(s[i..run]);
                i = run;
                if (i == s.len) return;
            }
            const c = s[i];
            switch (c) {
                '"' => {
                    self.raw("\\\"");
                    i += 1;
                },
                '\\' => {
                    self.raw("\\\\");
                    i += 1;
                },
                '\n' => {
                    self.raw("\\n");
                    i += 1;
                },
                '\r' => {
                    self.raw("\\r");
                    i += 1;
                },
                '\t' => {
                    self.raw("\\t");
                    i += 1;
                },
                else => {
                    // The run above consumed every other ASCII byte.
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        self.raw(&[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                        i += 1;
                    } else {
                        const n = std.unicode.utf8ByteSequenceLength(c) catch {
                            self.raw("\\ufffd");
                            i += 1;
                            continue;
                        };
                        if (i + n > s.len) {
                            self.raw("\\ufffd");
                            i += 1;
                            continue;
                        }
                        const seq = s[i .. i + n];
                        _ = std.unicode.utf8Decode(seq) catch {
                            self.raw("\\ufffd");
                            i += 1;
                            continue;
                        };
                        self.raw(seq);
                        i += n;
                    }
                },
            }
        }
    }

    pub fn slice(self: W) ?[]const u8 {
        if (self.failed) return null;
        return self.buf[0..self.i];
    }
};

/// A leading `-` would let a name from a hostile registry or tap be read by
/// the package manager as an option: `shQuote` returns `--force` unquoted
/// (every byte is shell-safe), so `apt-get purge -y --force` parses as a flag
/// rather than a name. No real package or formula is named that way, so the
/// name is dropped rather than the command disambiguated. Path components
/// use `isSafeIdent` instead: they are always joined onto a constant root, so
/// a leading `-` there is inert.
pub fn isSafeCmdIdent(s: []const u8) bool {
    return s.len > 0 and s[0] != '-' and isSafeIdent(s);
}

pub fn isSafeIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    for (s) |c| {
        if (c >= 0x80) continue;
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '+';
        if (!ok) return false;
    }
    return true;
}

/// Bytes a POSIX shell reads as a literal inside an unquoted word. Same set
/// as Swift `isSafeShellByte`, so a generated command reads the same on both
/// sides of the core.
pub fn isSafeShellByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '@' or c == '%' or c == '+' or c == '=' or
        c == ':' or c == ',' or c == '.' or c == '/' or c == '-';
}

/// POSIX single-quote form of `value`, for a name or path spliced into a
/// generated `/bin/sh` command. A package name or leftover path is attacker
/// controlled: without this, `foo'; reboot; '` runs as two commands, and the
/// UI runs the result under `pkexec`. A value that is already shell-safe is
/// returned as is. Writes into `buf` and returns the slice, or null when it
/// does not fit so the caller fails the render instead of emitting a
/// truncated command. `fuzzsupport.quoteByConstruction` is the harness oracle
/// for the same thing, and takes the byte rule from here.
pub fn shQuote(buf: []u8, value: []const u8) ?[]const u8 {
    var needs_quote = value.len == 0;
    for (value) |c| {
        if (!isSafeShellByte(c)) needs_quote = true;
    }
    if (!needs_quote) return value;
    if (value.len + 2 > buf.len) return null;
    var i: usize = 1;
    buf[0] = '\'';
    for (value) |c| {
        if (i + 4 > buf.len) return null;
        if (c == '\'') {
            @memcpy(buf[i..][0..4], "'\\''");
            i += 4;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    if (i >= buf.len) return null;
    buf[i] = '\'';
    return buf[0 .. i + 1];
}

/// `shQuote` straight into a `W`, failing the row when the value is too long
/// for `buf`. A finding with no command is not a finding with a broken one.
pub fn rawShQuote(w: *W, buf: []u8, value: []const u8) void {
    const q = shQuote(buf, value) orelse {
        w.failed = true;
        return;
    };
    w.raw(q);
}

/// Named outdated finding. `updatable` means the confirm script may run `command`.
/// host.exec still never runs that command.
pub fn writeOutdated(
    w: *W,
    name: []const u8,
    current: []const u8,
    latest: []const u8,
    manager: []const u8,
    command: []const u8,
    updatable: bool,
) void {
    w.raw("{\"kind\":\"outdated\",\"id\":");
    w.str(name);
    w.raw(",\"name\":");
    w.str(name);
    if (current.len > 0) {
        w.raw(",\"current_version\":");
        w.str(current);
    }
    if (latest.len > 0) {
        w.raw(",\"latest_version\":");
        w.str(latest);
    }
    w.raw(",\"status\":\"outdated\",\"updatable\":");
    w.raw(if (updatable) "true" else "false");
    w.raw(",\"command\":");
    if (command.len == 0) {
        w.raw("null");
    } else {
        var cmd_buf: [384]u8 = undefined;
        var name_buf: [320]u8 = undefined;
        const quoted = shQuote(&name_buf, name) orelse {
            w.failed = true;
            return;
        };
        if (command.len + quoted.len > cmd_buf.len) {
            w.failed = true;
            return;
        }
        @memcpy(cmd_buf[0..command.len], command);
        @memcpy(cmd_buf[command.len..][0..quoted.len], quoted);
        w.str(cmd_buf[0 .. command.len + quoted.len]);
    }
    w.raw(",\"manager\":");
    w.str(manager);
    w.raw("}");
}

/// Longest package name a name check accepts. Every registry plugin (npm,
/// Packagist, Homebrew) shares one bound so a name the core validates for one
/// manager is not rejected for another.
pub const max_pkg_name_len = 214;

/// Unscoped ident, or one npm-style `@scope/name`. No `..`, no extra `/`.
pub fn isSafePkgName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_pkg_name_len) return false;
    if (s[0] == '-') return false;
    if (s[0] != '@') return s[0] != '.' and isSafeIdent(s);
    var slash: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == '/') {
            if (slash != null) return false;
            slash = i;
        }
    }
    const sp = slash orelse return false;
    if (sp <= 1 or sp + 1 >= s.len) return false;
    if (s[1] == '.' or s[sp + 1] == '.') return false;
    return isSafeIdent(s[1..sp]) and isSafeIdent(s[sp + 1 ..]);
}

/// Packagist `vendor/package`. One slash. No `@`, no `..`.
pub fn isSafeComposerName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_pkg_name_len) return false;
    if (s[0] == '@' or s[0] == '-') return false;
    var slash: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (i + 1 < s.len and s[i] == '.' and s[i + 1] == '.') return false;
        if (s[i] == '/') {
            if (slash != null) return false;
            slash = i;
        }
    }
    const sp = slash orelse return false;
    if (sp == 0 or sp + 1 >= s.len) return false;
    const vendor = s[0..sp];
    const pkg = s[sp + 1 ..];
    if (vendor[0] == '.' or pkg[0] == '.') return false;
    return isSafeIdent(vendor) and isSafeIdent(pkg);
}

test "json string escapes quotes backslash and controls" {
    var buf: [64]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str("a\"b\\c\n\r\td");
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\td\"", got);
}

test "json string escapes remaining C0 controls" {
    var buf: [64]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str("a\x01b\x1fc");
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"a\\u0001b\\u001fc\"", got);
}

test "json string copies plain runs around the escapes" {
    var buf: [64]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str("plain/run\"next\\end\t/plain");
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"plain/run\\\"next\\\\end\\t/plain\"", got);
}

test "json writer overflow sets failed" {
    var buf: [4]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str("hello");
    try std.testing.expect(w.slice() == null);
}

test "writeOutdated JSON-escapes command and shell-quotes the name" {
    var buf: [512]u8 = undefined;
    var w = W{ .buf = &buf };
    writeOutdated(&w, "a\"b", "1", "2", "apt", "apt install ", true);
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got, "a\\\"b") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"command\":\"apt install 'a\\\"b'\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"updatable\":true") != null);

    var buf2: [256]u8 = undefined;
    var w2 = W{ .buf = &buf2 };
    writeOutdated(&w2, "typescript", "5.4.5", "5.5.0", "npm", "", false);
    const got2 = w2.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"command\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"command\":\"typescript\"") == null);
}

test "shQuote keeps an injected command inside one argv entry" {
    var buf: [256]u8 = undefined;
    const injected = shQuote(&buf, "foo'; reboot; '") orelse return error.Overflow;
    try std.testing.expectEqualStrings("'foo'\\''; reboot; '\\'''", injected);

    var plain: [64]u8 = undefined;
    try std.testing.expectEqualStrings("wget", shQuote(&plain, "wget").?);
    try std.testing.expectEqualStrings("''", shQuote(&plain, "").?);
    try std.testing.expectEqualStrings("'/home/user/a b'", shQuote(&plain, "/home/user/a b").?);

    var small: [4]u8 = undefined;
    try std.testing.expect(shQuote(&small, "a b") == null);
}

test "writeOutdated quotes a name that would otherwise split the command" {
    var buf: [512]u8 = undefined;
    var w = W{ .buf = &buf };
    writeOutdated(&w, "x'; reboot; '", "1", "2", "apt", "apt install ", true);
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got, "apt install 'x'\\\\''; reboot; '\\\\'''") != null);
}

test "isSafeIdent rejects empty and shell metacharacters" {
    try std.testing.expect(isSafeIdent("libfoo0"));
    try std.testing.expect(isSafeIdent(".mozilla"));
    try std.testing.expect(!isSafeIdent(""));
    try std.testing.expect(!isSafeIdent("foo;rm"));
    try std.testing.expect(!isSafeIdent("foo bar"));
}

test "isSafeIdent accepts utf8 letters and rejects invalid bytes" {
    try std.testing.expect(isSafeIdent("café"));
    try std.testing.expect(isSafeIdent("日本語"));
    try std.testing.expect(!isSafeIdent(&[_]u8{0xff}));
    try std.testing.expect(!isSafeIdent("foo\nbar"));
}

test "a name starting with a dash is not a command name" {
    // `shQuote` leaves `--force` unquoted, so it would reach apt-get as a flag.
    try std.testing.expect(isSafeIdent("--force"));
    try std.testing.expect(!isSafeCmdIdent("--force"));
    try std.testing.expect(!isSafeCmdIdent("-rf"));
    try std.testing.expect(isSafeCmdIdent("libfoo-1.2"));
    try std.testing.expect(!isSafePkgName("--registry=evil"));
    try std.testing.expect(!isSafePkgName("-x"));
    try std.testing.expect(isSafePkgName("lodash"));
    try std.testing.expect(isSafePkgName("@scope/name"));
    try std.testing.expect(!isSafeComposerName("-vendor/pkg"));
    try std.testing.expect(isSafeComposerName("vendor/pkg"));
}

test "json string passes utf8 through" {
    var buf: [32]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str("café");
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"café\"", got);
}

test "json string replaces invalid utf8" {
    var buf: [32]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str(&[_]u8{ 'a', 0xff, 'b' });
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"a\\ufffdb\"", got);
}

test "json string replaces truncated utf8 sequence" {
    var buf: [32]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str(&[_]u8{ 'c', 0xc3 });
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"c\\ufffd\"", got);
}

/// The seeds: real names the listing parsers have accepted, the injection
/// payloads a hostile registry or a file in `~/.local/bin` would carry, and
/// the UTF-8 and control bytes that arrive with them.
const fuzz_shquote_names = packFuzzSlice("wget\n@scope/pkg\nlibfoo-1.2_3.4+5\n");
const fuzz_shquote_utf8 = packFuzzSlice("café\n日本語\n\xff\n\xc3\n");
const fuzz_shquote_quotes = packFuzzSlice("'\n''\n'''\na'b'c\nfoo'; reboot; '\nx'; reboot; '\n");
const fuzz_shquote_shell = packFuzzSlice("$(id)\n`id`\na;rm -rf /\na|sh\na&b\na>b\na\\b\n");
const fuzz_shquote_flags = packFuzzSlice("--force\n-rf\n--registry=evil\n");
const fuzz_shquote_control = packFuzzSlice("a\nb\na\rb\na\x00b\na\x01b\na\x7fb\na\tb\n");
const fuzz_shquote_empty = packFuzzSlice("");

test "fuzz shQuote" {
    try std.testing.fuzz({}, fuzzShQuote, .{ .corpus = &.{
        &fuzz_shquote_names,
        &fuzz_shquote_utf8,
        &fuzz_shquote_quotes,
        &fuzz_shquote_shell,
        &fuzz_shquote_flags,
        &fuzz_shquote_control,
        &fuzz_shquote_empty,
    } });
}

/// Every value reaches a generated `/bin/sh` command that the UI runs under
/// `pkexec`, so the property is not that `shQuote` returns: it is that a shell
/// reading the result recovers the value, byte for byte, as one word. A
/// fuzzer that only checked for a null return would see every injection
/// payload here as a pass, because the payload is quoted correctly.
fn fuzzShQuote(_: void, smith: *std.testing.Smith) !void {
    var raw: [512]u8 = undefined;
    const value = raw[0..smith.slice(&raw)];

    // A buffer with room for the worst case: two quotes around the value, and
    // four bytes for each quote in it.
    var buf: [4 * 512 + 2]u8 = undefined;
    const quoted = shQuote(&buf, value) orelse {
        // The only refusal is a value that does not fit, and this one fits.
        try std.testing.expect(false);
        return;
    };

    var all_safe = value.len > 0;
    for (value) |c| {
        if (!isSafeShellByte(c)) all_safe = false;
    }
    if (all_safe) {
        // Nothing to quote means the value is emitted verbatim, so the shell
        // reads it as one word only because every byte is inert on its own.
        try std.testing.expectEqualStrings(value, quoted);
        return;
    }

    // Quoted, so the Qt guard has to accept it and the shell has to read back
    // exactly the value. A form the guard rejects is a cleanup the UI drops.
    try std.testing.expect(isQuotedValue(quoted));
    var back: [512]u8 = undefined;
    try std.testing.expectEqualStrings(value, unquote(quoted, &back) orelse return error.Overflow);
}

// A value that does not fit the caller's buffer is refused rather than
// truncated: a truncated command is a different command, and the UI runs it.
// Sweeping every buffer size, so the sizes that need the widest escape are
// covered whatever the loop reserves.
test "shQuote refuses a value it cannot write whole" {
    var buf: [512]u8 = undefined;
    var back: [512]u8 = undefined;
    for ([_][]const u8{ "wget", "", "a b", "a'b", "a'b'c", "foo'; reboot; '", "café", "a\nb" }) |value| {
        var room: usize = 0;
        while (room <= value.len * 4 + 8) : (room += 1) {
            const quoted = shQuote(buf[0..room], value) orelse continue;
            // A command written from a prefix of the value removes the wrong
            // target, so whatever comes back has to be the whole value.
            if (isQuotedValue(quoted)) {
                try std.testing.expectEqualStrings(value, unquote(quoted, &back) orelse return error.Overflow);
            } else {
                try std.testing.expectEqualStrings(value, quoted);
            }
        }
        // Room for the value and the widest escape on every byte of it is
        // always enough, so a caller that sizes the buffer like this never
        // loses the row.
        try std.testing.expect(shQuote(buf[0 .. value.len * 4 + 2], value) != null);
    }
}
