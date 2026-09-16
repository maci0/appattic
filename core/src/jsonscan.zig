//! JSON reading for the plugins, on top of `std.json.Scanner`.
//!
//! The plugins used to carry a hand-written scanner: whitespace skipping,
//! string slicing, delimiter matching, escape handling. The standard library
//! owns that now; what is left here is a cursor over `std.json.Scanner` plus
//! the three shapes the plugins ask for.
//!
//! Two properties keep every plugin simple:
//! * the scanner needs an allocator for its nesting stack, so a cursor runs it
//!   on a fixed buffer: std.json reserves 129 bytes for that stack, whatever
//!   the input size, so 256 bytes leave room;
//! * every returned slice points into the input, never into the stack, so a
//!   plugin can keep the strings after the cursor is gone. Strings that arrive
//!   in pieces (the ones that contain escapes) are dropped instead: they would
//!   have to be assembled somewhere, and no package name or version in these
//!   manifests contains an escape.

const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");

pub const Dep = struct {
    name: []const u8,
    version: []const u8,
};

pub const NamedVer = struct {
    name: []const u8,
    current: []const u8,
    latest: []const u8,
};

/// What the walk should do with a key's value once `onPair` has seen it.
pub const Action = enum {
    /// The callback consumed the value.
    took,
    /// Skip the value without looking inside it.
    skip,
    /// Descend into the value.
    walk,
    /// Stop walking.
    stop,
};

pub const Cursor = struct {
    pub const Tok = enum {
        object_begin,
        object_end,
        array_begin,
        array_end,
        string,
        number,
        other,
        end,
    };

    depth_mem: [256]u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    scanner: std.json.Scanner = undefined,
    /// Set while a string that contains escapes is being consumed. Such a
    /// string is reported as `.string` with an empty value.
    dropping: bool = false,
    last: []const u8 = "",

    /// Initialise through a pointer: the scanner keeps the allocator, which
    /// points into this struct.
    pub fn init(self: *Cursor, text: []const u8) void {
        self.depth_mem = undefined;
        self.fba = std.heap.FixedBufferAllocator.init(&self.depth_mem);
        self.scanner = std.json.Scanner.initCompleteInput(self.fba.allocator(), text);
        self.dropping = false;
        self.last = "";
    }

    /// The value of the last `.string` token. Empty for a dropped string.
    pub fn value(self: *const Cursor) []const u8 {
        return self.last;
    }

    pub fn peek(self: *Cursor) Tok {
        return map(self.scanner.peekNextTokenType() catch return .end);
    }

    pub fn next(self: *Cursor) Tok {
        while (true) {
            const tok = self.scanner.next() catch {
                self.last = "";
                return .end;
            };
            switch (tok) {
                .object_begin => return .object_begin,
                .object_end => return .object_end,
                .array_begin => return .array_begin,
                .array_end => return .array_end,
                .number, .partial_number, .allocated_number => return .number,
                .true, .false, .null => return .other,
                .end_of_document => return .end,
                .string => |s| {
                    self.last = if (self.dropping) "" else s;
                    self.dropping = false;
                    return .string;
                },
                .allocated_string => |s| {
                    self.last = if (self.dropping) "" else s;
                    self.dropping = false;
                    return .string;
                },
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => self.dropping = true,
            }
        }
    }

    fn map(t: std.json.TokenType) Tok {
        return switch (t) {
            .object_begin => .object_begin,
            .object_end => .object_end,
            .array_begin => .array_begin,
            .array_end => .array_end,
            .string => .string,
            .number => .number,
            .true, .false, .null => .other,
            .end_of_document => .end,
        };
    }

    /// Consume the rest of the value whose first token was `first`.
    pub fn skipAfter(self: *Cursor, first: Tok) bool {
        switch (first) {
            .object_begin, .array_begin => {
                var depth: usize = 1;
                while (depth > 0) {
                    const t = self.next();
                    switch (t) {
                        .end => return false,
                        .object_begin, .array_begin => depth += 1,
                        .object_end, .array_end => depth -= 1,
                        else => {},
                    }
                }
                return true;
            },
            .end => return false,
            else => return true,
        }
    }

    /// Skip the next value.
    pub fn skipValue(self: *Cursor) bool {
        return self.skipAfter(self.next());
    }
};

/// Walk every object key the linear scan reaches: keys of the document, of
/// nested values the callback asked to descend into, and of objects inside
/// arrays. `Ctx` needs `onPair(ctx, cur, key, value_first) Action`.
pub fn walkValue(cur: *Cursor, comptime Ctx: type, ctx: *Ctx, first: Cursor.Tok) void {
    switch (first) {
        .object_begin => walkObject(cur, Ctx, ctx),
        .array_begin => {
            while (true) {
                const t = cur.next();
                if (t == .array_end or t == .end) return;
                walkValue(cur, Ctx, ctx, t);
            }
        },
        else => {},
    }
}

/// Walk the whole document, arrays included.
pub fn walkDocument(cur: *Cursor, comptime Ctx: type, ctx: *Ctx) void {
    walkValue(cur, Ctx, ctx, cur.next());
}

/// Walk the keys of one object whose `{` was already consumed.
pub fn walkObject(cur: *Cursor, comptime Ctx: type, ctx: *Ctx) void {
    while (true) {
        const kt = cur.next();
        if (kt == .object_end or kt == .end) return;
        if (kt != .string) {
            // Malformed: treat the stray token as a value.
            _ = cur.skipAfter(kt);
            continue;
        }
        const key = cur.value();
        const vt = cur.next();
        if (vt == .end) return;
        switch (Ctx.onPair(ctx, cur, key, vt)) {
            .took => {},
            .skip => _ = cur.skipAfter(vt),
            .walk => walkValue(cur, Ctx, ctx, vt),
            .stop => return,
        }
    }
}

/// Run `Item` over every object element of an array whose `[` was already
/// consumed, calling `Item.finish` after each element. A non-object element is
/// skipped. `Item` needs `onPair` and `finish`.
pub fn eachObjectInArray(cur: *Cursor, comptime Item: type, item: *Item) void {
    while (true) {
        const t = cur.next();
        if (t == .array_end or t == .end) return;
        if (t == .object_begin) {
            walkObject(cur, Item, item);
            Item.finish(item);
        } else {
            _ = cur.skipAfter(t);
        }
    }
}

const VersionCtx = struct {
    version: []const u8 = "",

    fn onPair(self: *VersionCtx, cur: *Cursor, key: []const u8, vt: Cursor.Tok) Action {
        if (std.mem.eql(u8, key, "version") and vt == .string) {
            if (self.version.len == 0) self.version = cur.value();
        }
        // Nested values are skipped, so a dependency tree inside a dependency
        // does not leak into the parent's version.
        return .skip;
    }
};

fn takeVersion(cur: *Cursor, vt: Cursor.Tok) []const u8 {
    if (vt == .string) return cur.value();
    if (vt != .object_begin) return "";
    var ctx = VersionCtx{};
    walkObject(cur, VersionCtx, &ctx);
    return ctx.version;
}

const DepsCtx = struct {
    out: []Dep,
    n: usize = 0,

    fn onPair(self: *DepsCtx, cur: *Cursor, key: []const u8, vt: Cursor.Tok) Action {
        if (std.mem.eql(u8, key, "dependencies") and vt == .object_begin) {
            self.takeAll(cur);
            return .took;
        }
        // Anything else is skipped without descending, so a nested dependency
        // tree is not reported as a top-level one.
        return .skip;
    }

    /// Keys of a `dependencies` object: name -> version (string or object).
    fn takeAll(self: *DepsCtx, cur: *Cursor) void {
        while (true) {
            const kt = cur.next();
            if (kt == .object_end or kt == .end) return;
            if (kt != .string) {
                _ = cur.skipAfter(kt);
                continue;
            }
            const name = cur.value();
            const vt = cur.next();
            if (vt == .end) return;
            const version = takeVersion(cur, vt);
            if (self.n < self.out.len and jsonbuf.isSafePkgName(name)) {
                self.out[self.n] = .{ .name = name, .version = version };
                self.n += 1;
            }
        }
    }
};

/// `{"dependencies":{"name":{"version":"1.2.3"}}}` in any manifest shape: the
/// key is looked for at the document level and inside arrays.
pub fn parseJsonDependencies(text: []const u8, out: []Dep) usize {
    var cur: Cursor = undefined;
    Cursor.init(&cur, text);
    var ctx = DepsCtx{ .out = out };
    walkDocument(&cur, DepsCtx, &ctx);
    return ctx.n;
}

const OutdatedCtx = struct {
    out: []NamedVer,
    n: usize = 0,

    fn onPair(self: *OutdatedCtx, cur: *Cursor, key: []const u8, vt: Cursor.Tok) Action {
        if (vt != .object_begin) return .skip;
        var current: []const u8 = "";
        var latest: []const u8 = "";
        var wanted: []const u8 = "";
        // `npm outdated -g --json` keys its object by package name.
        takeVersions(cur, &current, &latest, &wanted);
        if (self.n < self.out.len and jsonbuf.isSafePkgName(key) and (current.len > 0 or latest.len > 0)) {
            self.out[self.n] = .{
                .name = key,
                .current = current,
                .latest = if (latest.len > 0) latest else wanted,
            };
            self.n += 1;
        }
        return .took;
    }

    fn takeVersions(cur: *Cursor, current: *[]const u8, latest: *[]const u8, wanted: *[]const u8) void {
        while (true) {
            const kt = cur.next();
            if (kt == .object_end or kt == .end) return;
            if (kt != .string) {
                _ = cur.skipAfter(kt);
                continue;
            }
            const key = cur.value();
            const vt = cur.next();
            if (vt == .end) return;
            if (vt == .string) {
                if (std.mem.eql(u8, key, "current")) current.* = cur.value();
                if (std.mem.eql(u8, key, "latest")) latest.* = cur.value();
                if (std.mem.eql(u8, key, "wanted")) wanted.* = cur.value();
            } else {
                _ = cur.skipAfter(vt);
            }
        }
    }
};

/// `npm outdated -g --json`: top-level object keyed by package name.
pub fn parseJsonNamedOutdated(text: []const u8, out: []NamedVer) usize {
    var cur: Cursor = undefined;
    Cursor.init(&cur, text);
    if (cur.next() != .object_begin) return 0;
    var ctx = OutdatedCtx{ .out = out };
    walkObject(&cur, OutdatedCtx, &ctx);
    return ctx.n;
}

const FieldCtx = struct {
    field: []const u8,
    found: ?[]const u8 = null,

    fn onPair(self: *FieldCtx, cur: *Cursor, key: []const u8, vt: Cursor.Tok) Action {
        if (!std.mem.eql(u8, key, self.field)) return .walk;
        if (vt == .string) self.found = cur.value();
        // The first matching key decides, as before.
        return .stop;
    }
};

/// The value of the first `"field"` key whose value is a string, at any depth.
pub fn findJsonStringField(text: []const u8, field: []const u8) ?[]const u8 {
    var cur: Cursor = undefined;
    Cursor.init(&cur, text);
    var ctx = FieldCtx{ .field = field };
    walkDocument(&cur, FieldCtx, &ctx);
    return ctx.found;
}

test "parseJsonDependencies object and array" {
    var buf: [8]Dep = undefined;
    const obj =
        \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
    ;
    const n = parseJsonDependencies(obj, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);
    try std.testing.expectEqualStrings("prettier", buf[1].name);
    try std.testing.expectEqualStrings("3.3.0", buf[1].version);

    const arr =
        \\[{"dependencies":{"nx":{"version":"19.0.0"}}}]
    ;
    const n2 = parseJsonDependencies(arr, &buf);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("nx", buf[0].name);
    try std.testing.expectEqualStrings("19.0.0", buf[0].version);
}

test "parseJsonDependencies scoped and skips nested trees" {
    var buf: [8]Dep = undefined;
    const text =
        \\{"dependencies":{"@vue/cli":{"version":"5.0.8","dependencies":{"evil":{"version":"1.0.0"}}}}}
    ;
    const n = parseJsonDependencies(text, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("@vue/cli", buf[0].name);
    try std.testing.expectEqualStrings("5.0.8", buf[0].version);

    const sibling =
        \\{"other":{"dependencies":{"evil":{"version":"1.0.0"}}},"dependencies":{"typescript":{"version":"5.4.5"}}}
    ;
    const n2 = parseJsonDependencies(sibling, &buf);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].version);

    const string_ver =
        \\{"dependencies":{"leftpad":"1.3.0","@scope/pkg":{"version":"0.1.0"}}}
    ;
    const n3 = parseJsonDependencies(string_ver, &buf);
    try std.testing.expectEqual(@as(usize, 2), n3);
    try std.testing.expectEqualStrings("leftpad", buf[0].name);
    try std.testing.expectEqualStrings("1.3.0", buf[0].version);
}

test "parseJsonNamedOutdated npm outdated JSON" {
    var buf: [4]NamedVer = undefined;
    const text =
        \\{"typescript":{"current":"5.4.5","wanted":"5.5.0","latest":"5.5.0"},"@vue/cli":{"current":"5.0.0","latest":"5.0.8"}}
    ;
    const n = parseJsonNamedOutdated(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("typescript", buf[0].name);
    try std.testing.expectEqualStrings("5.4.5", buf[0].current);
    try std.testing.expectEqualStrings("5.5.0", buf[0].latest);
    try std.testing.expectEqualStrings("@vue/cli", buf[1].name);
    try std.testing.expectEqualStrings("5.0.8", buf[1].latest);
    try std.testing.expectEqual(@as(usize, 0), parseJsonNamedOutdated("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseJsonNamedOutdated("[]", &buf));
}

test "parseJsonDependencies empty junk" {
    var buf: [4]Dep = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("{}", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("not json", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseJsonDependencies("{\"dependencies\":{\"x\":", &buf));
}

test "findJsonStringField any depth" {
    try std.testing.expectEqualStrings(
        "1.2.3",
        findJsonStringField("{\"a\":{\"b\":{\"version\":\"1.2.3\"}}}", "version").?,
    );
    try std.testing.expectEqualStrings(
        "npm",
        findJsonStringField("{\"name\":\"npm\",\"version\":\"1\"}", "name").?,
    );
    try std.testing.expect(findJsonStringField("{\"a\":1}", "a") == null);
    try std.testing.expect(findJsonStringField("{}", "a") == null);
    try std.testing.expect(findJsonStringField("not json", "a") == null);
}

test "isSafePkgName scoped" {
    try std.testing.expect(jsonbuf.isSafePkgName("typescript"));
    try std.testing.expect(jsonbuf.isSafePkgName("@vue/cli"));
    try std.testing.expect(!jsonbuf.isSafePkgName("@vue"));
    try std.testing.expect(!jsonbuf.isSafePkgName("foo/bar/baz"));
    try std.testing.expect(!jsonbuf.isSafePkgName("../etc"));
    try std.testing.expect(!jsonbuf.isSafePkgName("foo;rm"));
}

fn sliceInside(hay: []const u8, n: []const u8) bool {
    if (n.len == 0) return true;
    const h0 = @intFromPtr(hay.ptr);
    const n0 = @intFromPtr(n.ptr);
    return n0 >= h0 and n0 + n.len <= h0 + hay.len;
}

fn packFuzzSlice(comptime s: []const u8) [4 + s.len]u8 {
    var out: [4 + s.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4..], s);
    return out;
}

const fuzz_npm_obj = packFuzzSlice(
    \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"}}}
);
const fuzz_npm_arr = packFuzzSlice(
    \\[{"dependencies":{"nx":{"version":"19.0.0"}}}]
);
const fuzz_npm_scoped = packFuzzSlice(
    \\{"dependencies":{"@vue/cli":{"version":"5.0.8","dependencies":{"evil":{"version":"1.0.0"}}}}}
);
const fuzz_npm_sibling = packFuzzSlice(
    \\{"other":{"dependencies":{"evil":{"version":"1.0.0"}}},"dependencies":{"typescript":{"version":"5.4.5"}}}
);
const fuzz_npm_string_ver = packFuzzSlice(
    \\{"dependencies":{"leftpad":"1.3.0","@scope/pkg":{"version":"0.1.0"}}}
);
const fuzz_truncated = packFuzzSlice(
    \\{"dependencies":{"typescript":{"version":"5.4
);
const fuzz_unclosed = packFuzzSlice("{\"dependencies\":{\"x\":\"abc");
const fuzz_nested = packFuzzSlice("{\"a\":{\"b\":{\"c\":[1,2,{\"d\":\"e\"}]}}}");
const fuzz_escapes = packFuzzSlice("{\"dependencies\":{\"a\\\"b\":{\"version\":\"1\\n2\"}}}");
const fuzz_ws = packFuzzSlice(" \t\n\r{\"dependencies\" : { } }");
const fuzz_nulls = packFuzzSlice("{\"dependencies\":{\"x\":null,\"y\":true,\"z\":false}}");
const fuzz_not_json = packFuzzSlice("not json {{{");
const fuzz_empty_obj = packFuzzSlice("{}");
const fuzz_deep = packFuzzSlice("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<{{{{{{{{{{{{{{{{}}}}}}}}}}}}}}}}");

test "fuzz json parsers" {
    try std.testing.fuzz({}, fuzzJsonScan, .{ .corpus = &.{
        &fuzz_npm_obj,
        &fuzz_npm_arr,
        &fuzz_npm_scoped,
        &fuzz_npm_sibling,
        &fuzz_npm_string_ver,
        &fuzz_truncated,
        &fuzz_unclosed,
        &fuzz_nested,
        &fuzz_escapes,
        &fuzz_ws,
        &fuzz_nulls,
        &fuzz_not_json,
        &fuzz_empty_obj,
        &fuzz_deep,
    } });
}

fn fuzzJsonScan(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const n = smith.slice(&raw);
    const text = raw[0..n];

    var deps: [32]Dep = undefined;
    const got = parseJsonDependencies(text, &deps);
    try std.testing.expect(got <= deps.len);
    for (deps[0..got]) |d| {
        try std.testing.expect(sliceInside(text, d.name));
        try std.testing.expect(d.version.len == 0 or sliceInside(text, d.version));
        try std.testing.expect(jsonbuf.isSafePkgName(d.name));
    }

    var named: [32]NamedVer = undefined;
    const nout = parseJsonNamedOutdated(text, &named);
    try std.testing.expect(nout <= named.len);
    for (named[0..nout]) |d| {
        try std.testing.expect(sliceInside(text, d.name));
        try std.testing.expect(jsonbuf.isSafePkgName(d.name));
        try std.testing.expect(d.current.len == 0 or sliceInside(text, d.current));
        try std.testing.expect(d.latest.len == 0 or sliceInside(text, d.latest));
    }

    if (findJsonStringField(text, "version")) |v| {
        try std.testing.expect(sliceInside(text, v));
    }
    if (findJsonStringField(text, "name")) |v| {
        try std.testing.expect(sliceInside(text, v));
    }

    // The cursor must consume bounded input: a truncated document cannot spin.
    var cur: Cursor = undefined;
    Cursor.init(&cur, text);
    var steps: usize = 0;
    while (cur.next() != .end) {
        steps += 1;
        try std.testing.expect(steps <= text.len + 2);
    }
}
