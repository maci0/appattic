const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

/// Query commands that did not answer during one plugin run.
///
/// `host_exec.run` returns a negative code for a refused command, a failed or
/// timed-out child, and a too-small output buffer. A plugin that treats that
/// as "no rows" reports an empty finding list, which reads as a clean scan:
/// no orphans, nothing outdated, nothing left over. The Log keeps the command
/// and the reason so `render` can name them in the result `note`.
pub const max_logged = 8;

pub const Log = struct {
    items: [max_logged][2][]const u8 = undefined,
    n: usize = 0,
    /// Failures past `max_logged`, counted rather than dropped. The note is
    /// the only signal that a plugin's finding list is short of the whole
    /// machine, so a note that names the first `max_logged` failures and stops
    /// reads exactly like a scan that had no more than that: a truncated
    /// count is a clean-looking count.
    dropped: usize = 0,

    pub fn add(self: *Log, cmd: []const u8, rc: i32) void {
        if (rc >= 0) return;
        if (self.n == self.items.len) {
            self.dropped += 1;
            return;
        }
        self.items[self.n] = .{ cmd, host_exec.reason(rc) };
        self.n += 1;
    }

    /// Append the `note` field. Writes nothing when every command answered, so
    /// a clean result keeps the shape it had before.
    pub fn write(self: *const Log, w: *jsonbuf.W) void {
        if (self.n == 0 and self.dropped == 0) return;
        w.raw(",\"note\":\"");
        for (self.items[0..self.n], 0..) |item, i| {
            if (i > 0) w.raw("; ");
            w.escaped(item[0]);
            w.raw(" did not answer: ");
            w.escaped(item[1]);
        }
        if (self.dropped > 0) {
            if (self.n > 0) w.raw("; ");
            var tail: [64]u8 = undefined;
            w.escaped(std.fmt.bufPrint(
                &tail,
                "{d} more command{s} did not answer",
                .{ self.dropped, if (self.dropped == 1) @as([]const u8, "") else "s" },
            ) catch "more commands did not answer");
        }
        w.raw("\"");
    }
};

test "a failed command is named in the note" {
    var buf: [512]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.add("apt list --upgradable", host_exec.fail);
    log.add("dpkg -l", host_exec.deny);
    log.write(&w);
    try std.testing.expectEqualStrings(
        ",\"note\":\"apt list --upgradable did not answer: it failed, was cancelled, or hit the 60s timeout" ++
            "; dpkg -l did not answer: the host refused it as not an allowlisted query\"",
        w.slice().?,
    );
}

test "a command that answered adds no note" {
    var buf: [64]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.add("apt list --upgradable", 0);
    log.write(&w);
    try std.testing.expect(w.slice().?.len == 0);
}

test "the log stops at its bound" {
    var log = Log{};
    for (0..max_logged + 3) |i| {
        var name: [8]u8 = undefined;
        const label = try std.fmt.bufPrint(&name, "cmd-{d}", .{i});
        log.add(label, host_exec.fail);
    }
    try std.testing.expectEqual(max_logged, log.n);
    try std.testing.expectEqual(3, log.dropped);
}

test "failures past the bound are counted, not dropped" {
    var buf: [1024]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.add("apt list --upgradable", host_exec.fail);
    for (0..max_logged) |_| log.add("dpkg -l", host_exec.fail);
    log.write(&w);
    const note = w.slice().?;
    try std.testing.expect(std.mem.indexOf(u8, note, "1 more command did not answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "more commands did not answer") == null);
}

test "the dropped count is the real overflow, not the bound" {
    var buf: [1024]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    for (0..max_logged + 12) |i| {
        var name: [8]u8 = undefined;
        const label = try std.fmt.bufPrint(&name, "cmd-{d}", .{i});
        log.add(label, host_exec.fail);
    }
    log.write(&w);
    try std.testing.expectEqual(12, log.dropped);
    try std.testing.expect(
        std.mem.indexOf(u8, w.slice().?, "12 more commands did not answer") != null,
    );
}
