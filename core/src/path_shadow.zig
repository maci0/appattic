const std = @import("std");
const builtin = @import("builtin");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const pstore = @import("path_store.zig");

const Io = std.Io;
const Dir = Io.Dir;

const plugin_id = "path-shadow";

fn nativeIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

pub const ShadowFinding = struct {
    name: []const u8,
    path: []const u8,
    shadows: []const u8,
};

fn resolvePathNative(io: Io, path: []const u8, buf: []u8) ?[]const u8 {
    const n = Dir.realPathFileAbsolute(io, path, buf) catch return null;
    return buf[0..n];
}

fn isRegularFile(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn findShadowsNative(
    overlayDirs: []const []const u8,
    packageDirs: []const []const u8,
    out: []ShadowFinding,
    path_store: []u8,
) usize {
    var n: usize = 0;
    var used: usize = 0;
    var o_res: [4096]u8 = undefined;
    var p_res: [4096]u8 = undefined;

    const io = nativeIo();
    for (overlayDirs) |odir| {
        var dir = Dir.cwd().openDir(io, odir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (n >= out.len) return n;
            if (entry.kind == .directory) continue;
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') continue;
            if (!jsonbuf.isSafeIdent(name)) continue;

            // Probe on a local cursor: a name that turns out not to shadow
            // anything leaves no path behind, so a root with more files than
            // the store holds still reaches its last entry.
            var probe = used;
            const overlay_path = pstore.joinPath(odir, name, path_store, &probe) orelse continue;
            if (!isRegularFile(io, overlay_path)) continue;
            const resolved_overlay = resolvePathNative(io, overlay_path, &o_res) orelse continue;

            var packaged: ?[]const u8 = null;
            var same = false;
            for (packageDirs) |pdir| {
                const pkg_path = pstore.joinPath(pdir, name, path_store, &probe) orelse continue;
                if (!isRegularFile(io, pkg_path)) continue;
                const resolved_pkg = resolvePathNative(io, pkg_path, &p_res) orelse continue;
                if (std.mem.eql(u8, resolved_overlay, resolved_pkg)) {
                    same = true;
                    break;
                }
                if (packaged == null) packaged = pkg_path;
            }
            if (same or packaged == null) continue;
            // entry.name points into the dir reader buffer, which the next
            // it.next call invalidates. joinPath already copied the name into
            // path_store, so take it from the stored path instead.
            out[n] = .{
                .name = overlay_path[odir.len + 1 ..],
                .path = overlay_path,
                .shadows = packaged.?,
            };
            used = probe;
            n += 1;
        }
    }
    return n;
}

fn resolvePathExec(path: []const u8, buf: []u8) ?[]const u8 {
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "realpath {s}", .{path}) catch return null;
    const n = host_exec.run(cmd, buf);
    if (n < 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn fileExistsExec(path: []const u8) bool {
    var cmd_buf: [512]u8 = undefined;
    var out: [8]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "test -f {s}", .{path}) catch return false;
    return host_exec.run(cmd, &out) == 0;
}

/// Package dirs are read once up front. fork+exec+wait measures 3.8 ms on this
/// machine, so probing every overlay name against every package dir costs
/// hundreds of them per scan; a name the listing does not carry could only have
/// failed the `test -f` that follows, so the listing is a free exact prefilter.
/// The `test -f` stays because `ls` lists directories too and only the test
/// knows which it was.
const max_package_dirs = 8;
const pkg_listing_store_len = 131072;

/// Module level, not a local: 128 KiB of guest stack is more than a plugin
/// wants to carry into a linear-memory sandbox.
var pkg_store: [pkg_listing_store_len]u8 = undefined;

/// `ls -1` names are whole lines, so membership is a line compare and never a
/// substring hit on a longer name.
fn listingHasName(listing: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), name)) return true;
    }
    return false;
}

fn findShadowsExec(
    overlayDirs: []const []const u8,
    packageDirs: []const []const u8,
    out: []ShadowFinding,
    path_store: []u8,
) usize {
    var n: usize = 0;
    var used: usize = 0;
    var ls_buf: [65536]u8 = undefined;
    var ov_buf: [512]u8 = undefined;
    var pkg_buf: [512]u8 = undefined;
    var name_store: [8192]u8 = undefined;
    var names: [64][]const u8 = undefined;
    var name_used: usize = 0;

    var pkg_used: usize = 0;
    // One scratch for the whole loop: the Log copies the command it names, so
    // a buffer per iteration would work too, and a single one keeps every
    // entry naming its own text.
    var pkg_cmd_buf: [512]u8 = undefined;
    var pkg_listings: [max_package_dirs]?[]const u8 = .{null} ** max_package_dirs;
    const pkg_count = @min(packageDirs.len, max_package_dirs);
    for (packageDirs[0..pkg_count], 0..) |pdir, i| {
        const cmd = std.fmt.bufPrint(&pkg_cmd_buf, "ls -1 {s}", .{pdir}) catch continue;
        const m = host_exec.run(cmd, pkg_store[pkg_used..]);
        note.add(cmd, m);
        // A dir that could not be listed keeps a null prefilter, so its names
        // are probed the way they were before rather than dropped.
        if (m < 0) continue;
        pkg_listings[i] = pkg_store[pkg_used .. pkg_used + @as(usize, @intCast(m))];
        pkg_used += @intCast(m);
    }

    for (overlayDirs) |odir| {
        var cmd_buf: [512]u8 = undefined;
        const ls_cmd = std.fmt.bufPrint(&cmd_buf, "ls -1 {s}", .{odir}) catch continue;
        const ls_n = host_exec.run(ls_cmd, &ls_buf);
        note.add(ls_cmd, ls_n);
        if (ls_n < 0) continue;
        const raw_n = pstore.listingNames(ls_buf[0..@intCast(ls_n)], &names, "");
        var copied: usize = 0;
        while (copied < raw_n) : (copied += 1) {
            const src = names[copied];
            if (name_used + src.len > name_store.len) break;
            const start = name_used;
            @memcpy(name_store[name_used..][0..src.len], src);
            name_used += src.len;
            names[copied] = name_store[start..name_used];
        }

        for (names[0..copied]) |name| {
            if (n >= out.len) return n;
            // Probe on a local cursor; only an accepted shadow keeps its
            // paths. See findShadowsNative.
            var probe = used;
            const overlay_path = pstore.joinPath(odir, name, path_store, &probe) orelse continue;
            if (!fileExistsExec(overlay_path)) continue;
            const resolved_overlay = resolvePathExec(overlay_path, &ov_buf) orelse continue;

            var packaged: ?[]const u8 = null;
            var same = false;
            for (packageDirs[0..pkg_count], 0..) |pdir, i| {
                if (pkg_listings[i]) |listing| {
                    if (!listingHasName(listing, name)) continue;
                }
                const pkg_path = pstore.joinPath(pdir, name, path_store, &probe) orelse continue;
                if (!fileExistsExec(pkg_path)) continue;
                const resolved_pkg = resolvePathExec(pkg_path, &pkg_buf) orelse continue;
                if (std.mem.eql(u8, resolved_overlay, resolved_pkg)) {
                    same = true;
                    break;
                }
                if (packaged == null) packaged = pkg_path;
            }
            if (same or packaged == null) continue;
            out[n] = .{ .name = name, .path = overlay_path, .shadows = packaged.? };
            used = probe;
            n += 1;
        }
    }
    return n;
}

/// Scan overlay dirs for files that shadow same-named files in package dirs.
pub fn findShadows(
    overlayDirs: []const []const u8,
    packageDirs: []const []const u8,
    out: []ShadowFinding,
    path_store: []u8,
) usize {
    if (comptime builtin.cpu.arch == .wasm32) {
        return findShadowsExec(overlayDirs, packageDirs, out, path_store);
    }
    return findShadowsNative(overlayDirs, packageDirs, out, path_store);
}

var result_buf: [8192]u8 = undefined;
var note: querynote.Log = .{};
var result_nbytes: u32 = 0;

const none_json =
    \\{"plugin":"path-shadow","engine":null,"findings":[],"script":null,"dialog":{"title":"No overlay roots","body":"Overlay PATH dirs missing. Plugin inactive."},"note":"path missing"}
;

const overlay_fixture = pstore.home_sentinel ++ "/.local/bin";
const overlay_home_bin = pstore.home_sentinel ++ "/bin";
const package_fixture = "/usr/bin";

fn renderShadows(hits: []const ShadowFinding) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    var q_buf: [1024]u8 = undefined;
    w.raw("{\"plugin\":\"path-shadow\",\"engine\":null,\"findings\":[");
    for (hits, 0..) |h, i| {
        if (i != 0) w.raw(",");
        w.raw("{\"kind\":\"shadow\",\"id\":");
        w.str(h.name);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"path\":");
        w.str(h.path);
        w.raw(",\"status\":\"shadow\",\"shadows\":");
        w.str(h.shadows);
        jsonbuf.writeRmCommand(&w, &q_buf, "rm -f ", h.path);
        w.raw("}");
    }
    w.raw("],\"script\":");
    if (hits.len == 0) {
        w.raw("null");
    } else {
        var script_buf: [8192]u8 = undefined;
        var s_w = jsonbuf.W{ .buf = &script_buf };
        s_w.raw("#!/bin/sh\nset -e\n# AppAttic path-shadow. Review before running.\n");
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
    w.raw(",\"dialog\":{\"title\":\"Remove shadowing files?\",\"body\":\"Overlay files hide packaged copies. Nothing runs until you confirm.\"}");
    note.write(&w);
    w.raw("}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn query_impl(present: i32) i32 {
    // Here, not in findShadowsExec: findShadows also has a native path, and
    // a note left over from the previous run would name that run's failures.
    note = .{};
    if (present == 0) {
        @memcpy(result_buf[0..none_json.len], none_json);
        result_nbytes = @intCast(none_json.len);
        return 0;
    }
    const overlays = [_][]const u8{ overlay_fixture, overlay_home_bin };
    const packages = [_][]const u8{package_fixture};
    var hits: [32]ShadowFinding = undefined;
    var paths: [2048]u8 = undefined;
    var n = findShadows(&overlays, &packages, &hits, &paths);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderShadows, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "listingHasName matches whole lines only" {
    const listing = "python3\npip3\nnode\n";
    try std.testing.expect(listingHasName(listing, "python3"));
    try std.testing.expect(listingHasName(listing, "node"));
    try std.testing.expect(!listingHasName(listing, "pyth"));
    try std.testing.expect(!listingHasName(listing, "python"));
    try std.testing.expect(!listingHasName(listing, "th"));
    try std.testing.expect(!listingHasName(listing, ""));
    try std.testing.expect(!listingHasName("", "python3"));
    try std.testing.expect(listingHasName("  spaced  \r\n", "spaced"));
    try std.testing.expect(!listingHasName("  spaced  \r\n", "spaced "));
}

test "findShadows reports different overlay file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "overlay");
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "overlay/python3", .data = "#!/bin/sh\necho user\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/python3", .data = "#!/bin/sh\necho distro\n" });

    var overlay_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const overlay_dir = try tmp.dir.realPathFile(io, "overlay", &overlay_rp);
    const package_dir = try tmp.dir.realPathFile(io, "usr/bin", &package_rp);

    var hits: [8]ShadowFinding = undefined;
    var paths: [1024]u8 = undefined;
    const overlays = [_][]const u8{overlay_rp[0..overlay_dir]};
    const packages = [_][]const u8{package_rp[0..package_dir]};
    const n = findShadows(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("python3", hits[0].name);
    try std.testing.expect(std.mem.endsWith(u8, hits[0].path, "/overlay/python3"));
    try std.testing.expect(std.mem.endsWith(u8, hits[0].shadows, "/usr/bin/python3"));
}

test "findShadows skips symlink to packaged file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "overlay");
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/python3", .data = "#!/bin/sh\necho distro\n" });

    var pkg_rp: [512]u8 = undefined;
    const pkg_n = try tmp.dir.realPathFile(io, "usr/bin/python3", &pkg_rp);
    try tmp.dir.symLink(io, pkg_rp[0..pkg_n], "overlay/python3", .{});

    var overlay_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const overlay_dir = try tmp.dir.realPathFile(io, "overlay", &overlay_rp);
    const package_dir = try tmp.dir.realPathFile(io, "usr/bin", &package_rp);

    var hits: [8]ShadowFinding = undefined;
    var paths: [1024]u8 = undefined;
    const overlays = [_][]const u8{overlay_rp[0..overlay_dir]};
    const packages = [_][]const u8{package_rp[0..package_dir]};
    const n = findShadows(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "findShadows reaches a later root after a long run of non-shadowing files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "overlay-a");
    try tmp.dir.createDirPath(io, "overlay-b");
    try tmp.dir.createDirPath(io, "usr/bin");
    // Names long enough that a handful of rejected candidates fills a small
    // path store, so the first root is where an unbounded probe cursor would
    // run the scan out before the second root is read.
    var long_name: [176]u8 = undefined;
    for (0..8) |i| {
        const head = try std.fmt.bufPrint(long_name[0..16], "tool-{d}-", .{i});
        @memset(long_name[head.len..], 'x');
        const name = long_name[0 .. head.len + 160];
        const sub = try std.fs.path.join(std.testing.allocator, &.{ "overlay-a", name });
        defer std.testing.allocator.free(sub);
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "a" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "overlay-b/python3", .data = "#!/bin/sh\necho user\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/python3", .data = "#!/bin/sh\necho distro\n" });

    var a_rp: [512]u8 = undefined;
    var b_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const a_dir = try tmp.dir.realPathFile(io, "overlay-a", &a_rp);
    const b_dir = try tmp.dir.realPathFile(io, "overlay-b", &b_rp);
    const package_dir = try tmp.dir.realPathFile(io, "usr/bin", &package_rp);

    var hits: [8]ShadowFinding = undefined;
    var paths: [1024]u8 = undefined;
    const overlays = [_][]const u8{ a_rp[0..a_dir], b_rp[0..b_dir] };
    const packages = [_][]const u8{package_rp[0..package_dir]};
    const n = findShadows(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("python3", hits[0].name);
    try std.testing.expect(std.mem.endsWith(u8, hits[0].path, "/overlay-b/python3"));
    try std.testing.expect(std.mem.endsWith(u8, hits[0].shadows, "/usr/bin/python3"));
}

test "plugin_query present JSON includes shadow finding" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"path-shadow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dialog\":") != null);
}

test "a rendered shadow finding is one parseable row" {
    // query_impl only reaches the render with a row when the host answers its
    // fixture commands, so the row shape is rendered here: the finding array
    // is what the Qt smoke and the UI parse, and an unquoted `command` makes
    // the whole document unparseable, not just its field.
    const hits = [_]ShadowFinding{.{
        .name = "python3",
        .path = "/home/user/.local/bin/python3",
        .shadows = "/usr/bin/python3",
    }};
    try std.testing.expect(renderShadows(&hits));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\":\"rm -f /home/user/.local/bin/python3\"") != null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), query_impl(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
}

test "a note from one run does not reach the next" {
    note.add("ls -1 /home/user/.local/bin", host_exec.fail);
    try std.testing.expectEqual(@as(i32, 0), query_impl(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(jsonbuf.isValidJson(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "did not answer") == null);
}
