//! Shared helpers for the `std.testing.fuzz` harnesses in this directory.
//!
//! Every parser here returns slices into the text it was handed, never copies,
//! so a harness can prove that with a pointer-range check instead of trusting
//! it. `sliceInside` is that check; `packFuzzSlice` gives a corpus entry the
//! length prefix `Smith.slice` needs, since a comptime seed in a `.corpus`
//! literal carries no length.

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
