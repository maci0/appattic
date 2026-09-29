const std = @import("std");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

/// Failures kept per plugin run. Past this the rest are counted, not listed.
pub const max_logged = 8;

/// Command text one logged failure keeps. Every plugin builds its command in a
/// buffer this size or smaller, so nothing a real caller passes is cut.
const max_cmd_bytes = 512;

/// Query commands that did not answer during one plugin run.
///
/// `host_exec.run` returns a negative code for a refused command, a failed or
/// timed-out child, and a too-small output buffer. A plugin that treats that
/// as "no rows" reports an empty finding list, which reads as a clean scan:
/// no orphans, nothing outdated, nothing left over. The Log keeps the command
/// and the reason so the plugin's render step can name them in the result
/// `note`.
pub const Log = struct {
    items: [max_logged][2][]const u8 = undefined,
    /// The text `items[i][0]` points at. A plugin passes the scratch buffer it
    /// formats the command into, and that buffer dies with the iteration that
    /// filled it, so a kept slice would name a dead stack frame: every note
    /// would read as whatever the last loop iteration wrote there. The copy is
    /// what the item names.
    cmd_store: [max_logged][max_cmd_bytes]u8 = undefined,
    n: usize = 0,
    /// Failures past `max_logged`, counted rather than dropped. The note is
    /// the only signal that a plugin's finding list is short of the whole
    /// machine, so a note that names the first `max_logged` failures and stops
    /// reads exactly like a scan that had no more than that: a truncated
    /// count is a clean-looking count.
    dropped: usize = 0,
    /// Rows a parser had to drop because the plugin's fixed finding array was
    /// full, or because its path store had no room for a joined path. A full
    /// array means the answer was longer than the table, so the
    /// finding list is short of the machine for the same reason a command
    /// that did not answer leaves it short: without this the run reads as
    /// "these are all of them", and an all-of-them list is what the user
    /// confirms a deletion from. Counted in lists, not rows, to match the
    /// `note` that names them.
    dropped_rows: usize = 0,

    pub fn add(self: *Log, cmd: []const u8, rc: i32) void {
        if (rc >= 0) return;
        if (self.n == self.items.len) {
            self.dropped += 1;
            return;
        }
        var kept = @min(cmd.len, max_cmd_bytes);
        // A cut inside a multi-byte scalar leaves a trailing byte the note's
        // JSON string cannot carry, so the cut backs up to the scalar it split.
        while (kept > 0 and kept < cmd.len and (cmd[kept] & 0xC0) == 0x80) kept -= 1;
        @memcpy(self.cmd_store[self.n][0..kept], cmd[0..kept]);
        self.items[self.n] = .{ self.cmd_store[self.n][0..kept], host_exec.reason(rc) };
        self.n += 1;
    }

    /// Record rows a parser could not keep. `kept == cap` is the signal: the
    /// parser filled the array, so at least one more row existed. Anything
    /// less means the array was not the limit and nothing was dropped.
    pub fn addTruncatedRows(self: *Log, kept: usize, cap: usize) void {
        if (kept >= cap) self.dropped_rows += 1;
    }

    /// Record one list that a render gave up rows to make the result fit its
    /// buffer. The plugins shed rows from the end until the render succeeds,
    /// so a machine with more findings than `result_buf` holds is reported as
    /// the shorter list. The user confirms a deletion from that list, so the
    /// rows that went missing have to be visible the same way a missing
    /// command is.
    ///
    /// `dropped` is a row count and the note words this as a list, so one call
    /// is one list however many rows it lost: `200 lists hit the row limit`
    /// for a single root is not a fact about the machine.
    pub fn addDroppedRows(self: *Log, dropped: usize) void {
        if (dropped == 0) return;
        self.dropped_rows += 1;
    }

    /// Trim rows off the end of a parsed list until `render` fits it in the
    /// result buffer, recording what the trimming cost. Returns 0 once the
    /// render succeeds, 1 when the list is empty and it still does not.
    ///
    /// The count is recorded as the first row goes, not once the render
    /// succeeds: `render` writes the note itself, so a count added afterwards
    /// never reaches the result and the shortened list reads as the whole
    /// machine.
    pub fn renderShrinking(
        self: *Log,
        comptime render: anytype,
        list: anytype,
        n: *usize,
    ) i32 {
        const n_parsed = n.*;
        while (true) {
            if (render(list[0..n.*])) return 0;
            if (n.* == 0) return 1;
            if (n.* == n_parsed) self.addDroppedRows(1);
            n.* -= 1;
        }
    }

    /// `renderShrinking` for the plugins that parse two lists. `second` is
    /// trimmed first, so the shorter-lived list of the two is what survives.
    pub fn renderShrinkingPair(
        self: *Log,
        comptime render: anytype,
        first: anytype,
        n_first: *usize,
        second: anytype,
        n_second: *usize,
    ) i32 {
        var noted = false;
        while (true) {
            if (render(first[0..n_first.*], second[0..n_second.*])) return 0;
            if (n_second.* > 0) {
                n_second.* -= 1;
            } else if (n_first.* > 0) {
                n_first.* -= 1;
            } else {
                return 1;
            }
            if (!noted) {
                self.addDroppedRows(1);
                noted = true;
            }
        }
    }

    /// `renderShrinkingPair` for a plugin that parses four lists, trimmed
    /// `second`, then `fourth`, then `third`, then `first`: the order apt
    /// wants, so an outdated list never survives at the cost of an orphan.
    pub fn renderShrinkingQuad(
        self: *Log,
        comptime render: anytype,
        first: anytype,
        n_first: *usize,
        second: anytype,
        n_second: *usize,
        third: anytype,
        n_third: *usize,
        fourth: anytype,
        n_fourth: *usize,
    ) i32 {
        var noted = false;
        while (true) {
            if (render(
                first[0..n_first.*],
                second[0..n_second.*],
                third[0..n_third.*],
                fourth[0..n_fourth.*],
            )) return 0;
            if (n_second.* > 0) {
                n_second.* -= 1;
            } else if (n_fourth.* > 0) {
                n_fourth.* -= 1;
            } else if (n_third.* > 0) {
                n_third.* -= 1;
            } else if (n_first.* > 0) {
                n_first.* -= 1;
            } else {
                return 1;
            }
            if (!noted) {
                self.addDroppedRows(1);
                noted = true;
            }
        }
    }

    /// Append the `note` field. Writes nothing when every command answered and
    /// no parser ran out of room, so a clean result keeps the shape it had
    /// before.
    ///
    /// The note is a member of the result object, not a document of its own, so
    /// the caller writes the object's closing `}` after this returns. A plugin
    /// that closed the object first put the note outside it, and the host parser
    /// dropped the whole plugin result on any run where a command did not
    /// answer.
    pub fn write(self: *const Log, w: *jsonbuf.W) void {
        if (self.n == 0 and self.dropped == 0 and self.dropped_rows == 0) return;
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
        if (self.dropped_rows > 0) {
            if (self.n > 0 or self.dropped > 0) w.raw("; ");
            var tail: [96]u8 = undefined;
            w.escaped(std.fmt.bufPrint(
                &tail,
                "{d} list{s} hit the row limit: more rows exist than were shown",
                .{ self.dropped_rows, if (self.dropped_rows == 1) @as([]const u8, "") else "s" },
            ) catch "a list hit the row limit");
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

test "a logged command survives the buffer it was built in" {
    var log = Log{};
    // The shape a plugin uses: a scratch buffer per iteration, handed to `add`
    // and dead by the next one.
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    log.add(try std.fmt.bufPrint(&first, "ls -1 {s}", .{"alpha"}), host_exec.fail);
    log.add(try std.fmt.bufPrint(&second, "ls -1 {s}", .{"beta"}), host_exec.fail);
    var buf: [512]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    log.write(&w);
    const reason = host_exec.reason(host_exec.fail);
    var want: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(
            &want,
            ",\"note\":\"ls -1 alpha did not answer: {s}" ++
                "; ls -1 beta did not answer: {s}\"",
            .{ reason, reason },
        ),
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

test "a full finding array is named in the note" {
    var buf: [512]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.addTruncatedRows(128, 128);
    log.write(&w);
    try std.testing.expectEqualStrings(
        ",\"note\":\"1 list hit the row limit: more rows exist than were shown\"",
        w.slice().?,
    );
}

test "a list that did not fill its array adds no note" {
    var buf: [64]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.addTruncatedRows(12, 128);
    log.write(&w);
    try std.testing.expect(w.slice().?.len == 0);
}

test "truncated lists and failed commands share one note" {
    var buf: [512]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.add("apt list --upgradable", host_exec.fail);
    log.addTruncatedRows(32, 32);
    log.addTruncatedRows(32, 32);
    log.write(&w);
    const note = w.slice().?;
    try std.testing.expect(std.mem.indexOf(u8, note, "apt list --upgradable did not answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "2 lists hit the row limit") != null);
}

test "rows shed from one list are one list, not one list each" {
    var buf: [256]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.addDroppedRows(200);
    log.write(&w);
    try std.testing.expectEqualStrings(
        ",\"note\":\"1 list hit the row limit: more rows exist than were shown\"",
        w.slice().?,
    );
}

test "the note is a member of the result object" {
    var buf: [512]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.add("ls -1 /home/user", host_exec.fail);
    w.raw("{\"plugin\":\"path-xdg-config\"");
    log.write(&w);
    w.raw("}");
    try std.testing.expect(jsonbuf.isValidJson(w.slice().?));
}

test "a list that lost no rows adds no note" {
    var buf: [64]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    var log = Log{};
    log.addDroppedRows(0);
    log.write(&w);
    try std.testing.expect(w.slice().?.len == 0);
}
