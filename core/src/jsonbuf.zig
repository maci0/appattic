const std = @import("std");

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
        var i: usize = 0;
        while (i < s.len) {
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
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        self.raw(&[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                        i += 1;
                    } else if (c < 0x80) {
                        self.raw(&[_]u8{c});
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
        self.raw("\"");
    }

    pub fn slice(self: W) ?[]const u8 {
        if (self.failed) return null;
        return self.buf[0..self.i];
    }
};

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
        if (command.len + name.len > cmd_buf.len) {
            w.failed = true;
            return;
        }
        @memcpy(cmd_buf[0..command.len], command);
        @memcpy(cmd_buf[command.len..][0..name.len], name);
        w.str(cmd_buf[0 .. command.len + name.len]);
    }
    w.raw(",\"manager\":");
    w.str(manager);
    w.raw("}");
}

/// Unscoped ident, or one npm-style `@scope/name`. No `..`, no extra `/`.
pub fn isSafePkgName(s: []const u8) bool {
    if (s.len == 0 or s.len > 214) return false;
    if (s[0] != '@') return isSafeIdent(s);
    var slash: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == '/') {
            if (slash != null) return false;
            slash = i;
        }
    }
    const sp = slash orelse return false;
    if (sp <= 1 or sp + 1 >= s.len) return false;
    return isSafeIdent(s[1..sp]) and isSafeIdent(s[sp + 1 ..]);
}

/// Packagist `vendor/package`. One slash. No `@`, no `..`.
pub fn isSafeComposerName(s: []const u8) bool {
    if (s.len == 0 or s.len > 214) return false;
    if (s[0] == '@') return false;
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

test "json writer overflow sets failed" {
    var buf: [4]u8 = undefined;
    var w = W{ .buf = &buf };
    w.str("hello");
    try std.testing.expect(w.slice() == null);
}

test "writeOutdated JSON-escapes command and name" {
    var buf: [512]u8 = undefined;
    var w = W{ .buf = &buf };
    writeOutdated(&w, "a\"b", "1", "2", "apt", "apt install ", true);
    const got = w.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got, "a\\\"b") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"command\":\"apt install a\\\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"updatable\":true") != null);

    var buf2: [256]u8 = undefined;
    var w2 = W{ .buf = &buf2 };
    writeOutdated(&w2, "typescript", "5.4.5", "5.5.0", "npm", "", false);
    const got2 = w2.slice() orelse return error.Overflow;
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"command\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"updatable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"command\":\"typescript\"") == null);
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
