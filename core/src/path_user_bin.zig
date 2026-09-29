const std = @import("std");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const pstore = @import("path_store.zig");

const plugin_id = "path-user-bin";

const Root = struct {
    path: []const u8,
    label: []const u8,
};

const roots = [_]Root{
    .{ .path = pstore.home_sentinel ++ "/.local/bin", .label = ".local/bin" },
    .{ .path = pstore.home_sentinel ++ "/bin", .label = "bin" },
};

const keep = "dconf\n";

pub const BrokenLink = struct {
    name: []const u8,
    path: []const u8,
    root_label: []const u8,
};

fn testFlagOk(path: []const u8, flag: []const u8) bool {
    var cmd_buf: [512]u8 = undefined;
    var out: [8]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "test {s} {s}", .{ flag, path }) catch return false;
    return host_exec.run(cmd, &out) == 0;
}

/// Dangling user-bin symlink: test -h (symlink) and not test -e (target missing).
fn isDanglingSymlink(path: []const u8) bool {
    if (!testFlagOk(path, "-h")) return false;
    return !testFlagOk(path, "-e");
}

pub fn findBrokenLinks(out: []BrokenLink, paths: []u8, dropped: *usize) usize {
    note = .{};
    dropped.* = 0;
    var n: usize = 0;
    var used: usize = 0;
    var ls_buf: [2048]u8 = undefined;
    var names: [64][]const u8 = undefined;

    for (roots) |root| {
        var cmd_buf: [512]u8 = undefined;
        const ls_cmd = std.fmt.bufPrint(&cmd_buf, "ls -1 {s}", .{root.path}) catch continue;
        const ls_n = host_exec.run(ls_cmd, &ls_buf);
        note.add(ls_cmd, ls_n);
        if (ls_n < 0) continue;
        const name_n = pstore.listingNames(ls_buf[0..@intCast(ls_n)], &names, keep);

        for (names[0..name_n]) |name| {
            if (n >= out.len) return n;
            // Probe on a local cursor: a name that is not a dangling symlink
            // leaves no path behind, so a root with more files than the store
            // holds still reaches its last entry.
            var probe = used;
            const stable_name = pstore.copyInto(name, paths, &probe) orelse {
                dropped.* += 1;
                continue;
            };
            const link_path = pstore.joinPath(root.path, stable_name, paths, &probe) orelse {
                dropped.* += 1;
                continue;
            };
            if (!isDanglingSymlink(link_path)) continue;
            out[n] = .{ .name = stable_name, .path = link_path, .root_label = root.label };
            used = probe;
            n += 1;
        }
    }
    return n;
}

var result_buf: [65536]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;
var path_store: [8192]u8 = undefined;

fn render(hits: []const BrokenLink) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":");
    w.str(plugin_id);
    w.raw(",\"engine\":null,\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"symlink\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"rootLabel\":");
        w.str(h.root_label);
        w.raw(",\"status\":\"orphaned\"");
        jsonbuf.writeRmCommand(&w, &q_buf, "rm -f ", h.path);
        w.raw("}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        var script_buf: [8192]u8 = undefined;
        var s_w = jsonbuf.W{ .buf = &script_buf };
        s_w.raw("#!/bin/sh\nset -e\n# AppAttic ");
        s_w.raw(plugin_id);
        s_w.raw(". Review before running.\n");
        for (hits) |h| {
            s_w.raw("rm -f ");
            s_w.raw(jsonbuf.shQuote(&q_buf, h.path) orelse {
                s_w.failed = true;
                break;
            });
            s_w.raw("\n");
        }
        w.str(s_w.slice() orelse {
            w.failed = true;
            return false;
        });
    }
    w.raw(",\"dialog\":{\"title\":\"Remove leftover user binaries?\",\"body\":\"Named dirs only. Nothing runs until you confirm.\"}");
    note.write(&w);
    w.raw("}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

const missing_json =
    \\{"plugin":"path-user-bin","engine":null,"findings":[],"script":null,"dialog":{"title":"No leftover root","body":"~/.local/bin is missing. Plugin inactive."},"note":"path missing"}
;

fn query_impl(present: i32) i32 {
    if (present == 0) {
        @memcpy(result_buf[0..missing_json.len], missing_json);
        result_nbytes = @intCast(missing_json.len);
        return 0;
    }
    var found: [128]BrokenLink = undefined;
    var store_dropped: usize = 0;
    var n = findBrokenLinks(&found, &path_store, &store_dropped);
    note.addTruncatedRows(n, found.len);
    note.addDroppedRows(store_dropped);
    return note.renderShrinking(render, &found, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

pub fn resultSlice() []const u8 {
    return result_buf[0..result_nbytes];
}

test "findBrokenLinks reports dangling symlink only" {
    var scratch: [8]BrokenLink = undefined;
    var dropped: usize = 0;
    const n = findBrokenLinks(&scratch, &path_store, &dropped);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("gone-app", scratch[0].name);
    try std.testing.expectEqualStrings("/home/user/.local/bin/gone-app", scratch[0].path);
    try std.testing.expectEqualStrings(".local/bin", scratch[0].root_label);
}

test "plugin_query present JSON uses symlink orphaned fields" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-user-bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"symlink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"orphaned\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home/user/.local/bin/gone-app") != null);
    // `rm -f`, not `rm`: the script runs under `set -e`, so a bare `rm` on a
    // link a previous run already took away exits nonzero there and stops
    // every line below it. The same shape path_shadow.zig writes.
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -f /home/user/.local/bin/gone-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rm -rf") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dconf") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = resultSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}
