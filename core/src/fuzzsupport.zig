//! Shared helpers for the `std.testing.fuzz` harnesses in this directory.
//!
//! Every parser here returns slices into the text it was handed, never copies,
//! so a harness can prove that with a pointer-range check instead of trusting
//! it. `sliceInside` is that check; `packFuzzSlice` gives a corpus entry the
//! length prefix `Smith.slice` needs, since a comptime seed in a `.corpus`
//! literal carries no length.
//!
//! A command a package name is spliced into is the other boundary worth an
//! oracle: `isQuotedValue` and `unquote` read a single-quoted shell word the
//! way `/bin/sh` does, so a harness can say what the shell will see rather
//! than only that nothing crashed.

const std = @import("std");

/// True when `n` points into `hay`, or is empty. A parser that reports a name
/// or version from outside its input has either over-read the buffer or kept a
/// pointer into a dead stack frame.
pub fn sliceInside(hay: []const u8, n: []const u8) bool {
    if (n.len == 0) return true;
    const h0 = @intFromPtr(hay.ptr);
    const n0 = @intFromPtr(n.ptr);
    return n0 >= h0 and n0 + n.len <= h0 + hay.len;
}

/// Length-prefix a comptime seed so `Smith.slice` can recover the input.
pub fn packFuzzSlice(comptime s: []const u8) [4 + s.len]u8 {
    var out: [4 + s.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4..], s);
    return out;
}

/// `shQuote` restated the slow, obvious way: build the word by appending, one
/// byte at a time, with no width reserved ahead of the byte being written. A
/// harness compares the two, so a value that comes back quoted but not the
/// value, or quoted and cut short, fails instead of passing as "it returned
/// something". `safe` is the caller's shell-safe byte rule, so this stays a
/// statement about the quoting mechanics rather than a second opinion on which
/// bytes are safe. Null when the word does not fit in `out`.
pub fn quoteByConstruction(out: []u8, value: []const u8, safe: *const fn (u8) bool) ?[]const u8 {
    var needs_quote = value.len == 0;
    for (value) |c| {
        if (!safe(c)) needs_quote = true;
    }
    if (!needs_quote) return value;
    if (out.len < 2) return null;
    var n: usize = 1;
    out[0] = '\'';
    for (value) |c| {
        if (c == '\'') {
            if (n + 4 > out.len) return null;
            @memcpy(out[n..][0..4], "'\\''");
            n += 4;
        } else {
            if (n + 1 > out.len) return null;
            out[n] = c;
            n += 1;
        }
    }
    if (n + 1 > out.len) return null;
    out[n] = '\'';
    return out[0 .. n + 1];
}

/// The shape the Qt guard `isQuotedValue` in `ui/linux-qt/finding.cpp`
/// accepts, spelled here so the two sides are held to one rule: one
/// single-quoted value, opening and closing, with a quote inside it only as
/// the four-byte `'\''` run. The UI refuses to run a command whose spliced
/// value is not this, so a form the writer emits that the guard rejects is a
/// cleanup the app will not perform.
pub fn isQuotedValue(q: []const u8) bool {
    if (q.len < 2 or q[0] != '\'' or q[q.len - 1] != '\'') return false;
    const last = q.len - 1;
    var i: usize = 1;
    while (i < last) {
        if (q[i] != '\'') {
            i += 1;
            continue;
        }
        if (i + 3 <= last and std.mem.startsWith(u8, q[i..], "'\\''")) {
            i += 4;
            continue;
        }
        return false;
    }
    return true;
}

/// POSIX single-quote removal, the reading `/bin/sh` gives the word: inside
/// `'` nothing is special until the next `'`, and the `'\''` run is a quote
/// that closed, escaped, and reopened. The oracle for the harnesses that
/// check a quoted value, not a parser under test. Null when `q` is not a
/// single quoted value, or when the value does not fit in `out`.
pub fn unquote(q: []const u8, out: []u8) ?[]const u8 {
    if (!isQuotedValue(q)) return null;
    const last = q.len - 1;
    var i: usize = 1;
    var n: usize = 0;
    while (i < last) {
        if (q[i] == '\'') {
            if (i + 3 > last or !std.mem.startsWith(u8, q[i..], "'\\''")) return null;
            if (n >= out.len) return null;
            out[n] = '\'';
            n += 1;
            i += 4;
            continue;
        }
        if (n >= out.len) return null;
        out[n] = q[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}
