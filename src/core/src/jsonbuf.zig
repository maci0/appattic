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
        for (s) |c| {
            switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                else => self.raw(&[_]u8{c}),
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
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '+';
        if (!ok) return false;
    }
    return true;
}

/// Report-only outdated finding. Named upgrade lives in `command`. Never live-exec.
pub fn writeOutdated(
    w: *W,
    name: []const u8,
    current: []const u8,
    latest: []const u8,
    manager: []const u8,
    command: []const u8,
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
    w.raw(",\"status\":\"outdated\",\"updatable\":false,\"command\":\"");
    w.raw(command);
    w.raw(name);
    w.raw("\",\"manager\":");
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
