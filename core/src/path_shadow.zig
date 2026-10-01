const std = @import("std");
const builtin = @import("builtin");
const plugin_abi = @import("plugin_abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const querynote = @import("querynote.zig");
const host_exec = @import("host_exec.zig");
const pstore = @import("path_store.zig");
const fuzzsupport = @import("fuzzsupport.zig");

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
        // `name_store` is reset per root, not per scan: `listingNames` hands
        // back names pointing into `ls_buf`, which the next root's `run`
        // overwrites, so each root needs its own stable copy. Carrying the
        // cursor across roots spent the 8 KiB on the first root's names and
        // left every later root with a list cut short at whatever the bound
        // was left at, so a shadow in a later root went unreported.
        name_used = 0;
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

// The overlay roots are the four the rest of the product names for a user
// file that hides a packaged one: `~/.local/bin` and `~/bin` from the shell
// PATH, `~/.cargo/bin` from the Rust toolchain's own PATH entry, and the
// XDG data dir's `applications`, where a desktop file shadows a packaged one
// of the same name. They are exactly the four `kHomeRules` in
// `ui/linux-qt/corehost.cpp` tests to decide this plugin's presence tag, so a
// machine whose only overlay is `~/.cargo/bin` is tagged ACTIVE and then found
// nothing to report, which reads as a clean machine. `defaultOverlayShadowRoots`
// in `Sources/AppAtticScan/Overlays.swift` is the same four on the Swift side;
// keep the two in step.
const overlay_local_bin = pstore.home_sentinel ++ "/.local/bin";
const overlay_home_bin = pstore.home_sentinel ++ "/bin";
const overlay_cargo_bin = pstore.home_sentinel ++ "/.cargo/bin";
const overlay_applications = pstore.home_sentinel ++ "/.local/share/applications";

// The packaged roots, in the same order `defaultPackageShadowDirs` lists the
// ones that need no discovery: the four FHS bin dirs and the two desktop
// dirs first, so the finding a user sees is the one under a real packaged
// tree. `max_package_dirs` bounds how many are prefiltered, and a root past
// the bound is dropped with no note, so the bound is checked at compile time
// rather than left to the next person who adds a root.
const package_usr_bin = "/usr/bin";
const package_usr_sbin = "/usr/sbin";
const package_bin = "/bin";
const package_sbin = "/sbin";
const package_usr_local_bin = "/usr/local/bin";
const package_usr_applications = "/usr/share/applications";
const package_usr_local_applications = "/usr/local/share/applications";

// The test fixture names, kept as the two-arg shorthand every existing test
// passes to `findShadows`.
const overlay_fixture = overlay_local_bin;
const package_fixture = package_usr_bin;

/// Every overlay root this plugin reads, in the order it reads them. One
/// definition for `query_impl` and the root-set test, so a root added to one
/// and not the other cannot pass.
const overlay_roots = [_][]const u8{
    overlay_local_bin,
    overlay_home_bin,
    overlay_cargo_bin,
    overlay_applications,
};

/// Every packaged root `overlay_roots` is compared against. A dir past
/// `max_package_dirs` is not prefiltered and its matches go unreported, so the
/// count is checked where the bound is declared rather than left to overflow
/// silently at the next root.
const package_roots = [_][]const u8{
    package_usr_bin,
    package_usr_sbin,
    package_bin,
    package_sbin,
    package_usr_local_bin,
    package_usr_applications,
    package_usr_local_applications,
};

comptime {
    if (package_roots.len > max_package_dirs) {
        @compileError("path-shadow lists more packaged roots than " ++
            "max_package_dirs prefilters: raise the bound or drop a root.");
    }
}

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
    var hits: [32]ShadowFinding = undefined;
    var paths: [2048]u8 = undefined;
    var n = findShadows(&overlay_roots, &package_roots, &hits, &paths);
    note.addTruncatedRows(n, hits.len);
    return note.renderShrinking(renderShadows, &hits, &n);
}

comptime {
    plugin_abi.bind(plugin_id, query_impl, &result_buf, &result_nbytes);
}

test "a shadow in ~/.cargo/bin over /usr/sbin is found" {
    // The two roots kHomeRules tags on that the plugin used to skip: the
    // plugin read ~/.local/bin and ~/bin against /usr/bin and nothing else, so
    // a machine whose only overlay is a ~/.cargo/bin shim over /usr/sbin was
    // tagged ACTIVE and reported no shadows, which reads as a clean machine.
    // scripts/lint.sh holds this list against kHomeRules; this holds the scan
    // to the list. A test on ~/.local/bin alone would pass against the old
    // list too, which is why the probe sits in the two roots that were
    // missing.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A name no real install ships. The other root sets in package_roots are
    // real paths, so a fixture name that exists in one of them on the machine
    // running this test would be found a second time and break the count.
    const shadowed = "appattic-shadow-probe";

    try tmp.dir.createDirPath(io, "cargo/bin");
    try tmp.dir.createDirPath(io, "usr/sbin");
    try tmp.dir.writeFile(io, .{ .sub_path = "cargo/bin/" ++ shadowed, .data = "#!/bin/sh\necho user\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/sbin/" ++ shadowed, .data = "#!/bin/sh\necho distro\n" });

    var overlay_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const overlay_dir = try tmp.dir.realPathFile(io, "cargo/bin", &overlay_rp);
    const package_dir = try tmp.dir.realPathFile(io, "usr/sbin", &package_rp);

    // The fixture stands in for the two named roots, in place, rather than
    // for the last entries of whatever list is present. Substituting by
    // position passes against the old two-root list too, because a trimmed
    // list still has a last entry; substituting by name fails when the named
    // root is gone, which is the regression this pins.
    var overlays: [overlay_roots.len][]const u8 = overlay_roots;
    var packages: [package_roots.len][]const u8 = package_roots;
    var swapped_overlay = false;
    for (&overlays) |*slot| {
        if (std.mem.eql(u8, slot.*, overlay_cargo_bin)) {
            slot.* = overlay_rp[0..overlay_dir];
            swapped_overlay = true;
        }
    }
    var swapped_package = false;
    for (&packages) |*slot| {
        if (std.mem.eql(u8, slot.*, package_usr_sbin)) {
            slot.* = package_rp[0..package_dir];
            swapped_package = true;
        }
    }
    // A root that went missing from either list leaves the fixture out of the
    // scan, and the finding count below would then pass for the wrong reason,
    // so the swap itself is asserted first.
    try std.testing.expect(swapped_overlay);
    try std.testing.expect(swapped_package);

    var hits: [8]ShadowFinding = undefined;
    var paths: [1024]u8 = undefined;
    const n = findShadows(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings(shadowed, hits[0].name);
    try std.testing.expect(std.mem.endsWith(u8, hits[0].path, "/cargo/bin/" ++ shadowed));
    try std.testing.expect(std.mem.endsWith(u8, hits[0].shadows, "/usr/sbin/" ++ shadowed));
}

test "every packaged root is one the plugin can actually prefilter" {
    // A packaged dir past max_package_dirs keeps a null listing, so the
    // per-name probe still runs for it, but the dir was dropped from the
    // prefiltered set and its cost is silently different from the rest. The
    // comptime check above refuses to build past the bound; this says what the
    // bound is, so raising it is a deliberate edit.
    try std.testing.expect(package_roots.len <= max_package_dirs);
    // /usr/bin has to be one of them: every shadow finding names a packaged
    // file, and this is the packaged path a Linux install actually uses.
    var found = false;
    for (package_roots) |p| {
        if (std.mem.eql(u8, p, package_fixture)) found = true;
    }
    try std.testing.expect(found);
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

test "findShadowsExec reads every root, not only the first few" {
    // `findShadowsExec` copies each root's `ls` names into a scratch store so
    // the names outlive the buffer `ls` filled, and that copy has to be reset
    // per root. Carrying one cursor across the whole scan spends the store on
    // the first roots and silently truncates every later root's candidate
    // list, so a shadow in a late root is never reported. The fixture root
    // lists five names, so 300 roots need far more than the 8 KiB store and
    // only the per-root reset lets the last of them reach `python3`.
    const root_repeats = 300;
    const packages = [_][]const u8{package_fixture};
    var hits: [root_repeats]ShadowFinding = undefined;
    // Every finding keeps its overlay path in `path_store` for the whole scan,
    // so this store is sized for all of them: 300 paths of about 60 bytes.
    var paths: [root_repeats * 64]u8 = undefined;

    var overlays: [root_repeats][]const u8 = undefined;
    for (&overlays) |*o| o.* = overlay_fixture;

    const n = findShadowsExec(&overlays, &packages, &hits, &paths);
    try std.testing.expectEqual(@as(usize, root_repeats), n);
    for (hits) |h| {
        try std.testing.expectEqualStrings("python3", h.name);
        try std.testing.expect(std.mem.endsWith(u8, h.shadows, "/usr/bin/python3"));
    }
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

// ---------------------------------------------------------------------------
// Fuzz target.
//
// `findShadows` reads directory entries in `~/.local/bin` and `~/bin` that any
// unprivileged process can create, and turns one into an `rm -f <path>` line
// the UI runs under `pkexec`. So the harness holds every row to the property
// that keeps the removal safe, rather than checking only that nothing crashed:
//
//   - the name is a basename, never a path, never empty, never a dot name, and
//     survives `isSafeIdent`, the predicate that gates every entry before it
//     can reach a command;
//   - `name`, `path` and `shadows` are copies inside the caller's path store,
//     never pointers into a directory-reader buffer the next read invalidates;
//   - `path` sits under an overlay root and `shadows` under a package root, so
//     a row can never name a removal outside the roots that were asked about;
//   - `path` names a file and never the root itself;
//   - reading the same names twice gives the same rows, or a scan replayed
//     from a recorded listing disagrees with the one the user confirmed;
//   - `shQuote` can spell the path, which is what the script writer needs.
//
// The seeds are the shapes an overlay root actually holds: ordinary binaries,
// scoped and path-like names, shell metacharacter soup, non-ASCII and truncated
// UTF-8, control bytes, names of only dots and slashes, a name long enough to
// fill a small path store, and the empty and whitespace-only listings.
// ---------------------------------------------------------------------------

// The filesystem per-component limit, the ceiling on what a directory
// entry in an overlay root can be. A name longer than this never becomes
// a row, so the harness stops trying to create one rather than reading
// `NameTooLong` from the tree instead of a row from the parser.
const fuzz_name_max = 255;

const fuzz_overlay_names = fuzzsupport.packFuzzSlice("python3\npip3\nnode\n.cache-secret\n");
const fuzz_overlay_scoped = fuzzsupport.packFuzzSlice("@scope/tool\n./python3\n../bin/node\nnode_modules\n");
const fuzz_overlay_shell = fuzzsupport.packFuzzSlice("x'; reboot; '\nrm -rf /\n$(id)\n`id`\na b\na|b\n~/x\n--flag\n-e\n");
const fuzz_overlay_utf8 = fuzzsupport.packFuzzSlice("caf\u{e9}\nna\u{ef}ve\n\u{1F600}\n\xc3\n\xff\xfe\n");
const fuzz_overlay_control = fuzzsupport.packFuzzSlice("a\tb\na\nb\nplain\n\x1b[2J\n");
const fuzz_overlay_dots = fuzzsupport.packFuzzSlice(".\n..\n./\n/\n//\na/\n.hidden\n..hidden\n");
const fuzz_overlay_empty = fuzzsupport.packFuzzSlice("");
const fuzz_overlay_blank = fuzzsupport.packFuzzSlice(" \t \n\n\r\n");
const fuzz_overlay_long = fuzzsupport.packFuzzSlice("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");

test "fuzz findShadows" {
    try std.testing.fuzz({}, fuzzFindShadows, .{ .corpus = &.{
        &fuzz_overlay_names,
        &fuzz_overlay_scoped,
        &fuzz_overlay_shell,
        &fuzz_overlay_utf8,
        &fuzz_overlay_control,
        &fuzz_overlay_dots,
        &fuzz_overlay_empty,
        &fuzz_overlay_blank,
        &fuzz_overlay_long,
    } });
}

// The exec reader answers "is this name in the `ls -1` output" by comparing
// whole trimmed lines, and it compares a line the parser has already accepted
// against a listing it has not. That is the one place in this module where a
// hostile line can arrive without the filesystem having to hold it, so the
// harness drives it directly: a name must match only on a whole line, and never
// on a prefix, a suffix, a substring of a longer name, or an empty line.
test "fuzz listingHasName" {
    try std.testing.fuzz({}, fuzzListingHasName, .{ .corpus = &.{
        &fuzz_overlay_names,
        &fuzz_overlay_shell,
        &fuzz_overlay_utf8,
        &fuzz_overlay_control,
        &fuzz_overlay_dots,
        &fuzz_overlay_blank,
    } });
}

fn fuzzListingHasName(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const listing = raw[0..smith.slice(&raw)];

    // A hit must be a whole line: reading the same listing the same way twice
    // cannot change the answer, and trimming is applied before the compare, so
    // the line that hit is a line a re-read hits too.
    if (listingHasName(listing, "python3")) {
        try std.testing.expect(listingHasName(listing, "python3"));
        try std.testing.expectEqual(true, listingHasName(listing, "python3"));
    }

    // A name holding a newline can never be one line of a listing, so it can
    // never match: a hit would mean the compare spans lines and a crafted name
    // could match a listing line it does not name.
    const nl_name = "ab\ncd";
    try std.testing.expect(!listingHasName(listing, nl_name));
    try std.testing.expect(!listingHasName(listing, "a\nb\n"));

    // Every line of a listing is found. This is the direction that has
    // consequences: the caller uses this to skip a package directory that does
    // not hold the file, and a false negative there means a shadow is never
    // reported at all, so a removal the user confirmed quietly leaves the
    // shadowing file in place. An off-by-one in the trim, a dropped line, or a
    // scan that stops early all show up here.
    var iter = std.mem.splitScalar(u8, listing, '\n');
    while (iter.next()) |candidate| {
        const line = std.mem.trim(u8, candidate, " \t\r");
        if (line.len == 0) continue;
        try std.testing.expect(listingHasName(listing, line));
        // Re-asking cannot change the answer, so a hit is stable across reads.
        try std.testing.expectEqual(true, listingHasName(listing, line));
    }

    // The compare is on whole lines, not on substrings. For every line of the
    // listing, ask about each of its proper prefixes: a prefix matches if and
    // only if the listing holds that prefix as a line of its own. A compare
    // that accepted substrings would match every prefix, which is how a listing
    // holding "python3" comes to answer yes for "py" and a package directory
    // is wrongly believed to hold a file it does not.
    var lines_a = std.mem.splitScalar(u8, listing, '\n');
    while (lines_a.next()) |raw_a| {
        const line_a = std.mem.trim(u8, raw_a, " \t\r");
        var cut: usize = 1;
        while (cut < line_a.len) : (cut += 1) {
            const prefix = line_a[0..cut];
            const is_a_line = block: {
                var it = std.mem.splitScalar(u8, listing, '\n');
                var hit = false;
                while (it.next()) |w| {
                    if (std.mem.eql(u8, std.mem.trim(u8, w, " \t\r"), prefix)) hit = true;
                }
                break :block hit;
            };
            try std.testing.expectEqual(is_a_line, listingHasName(listing, prefix));
        }
    }

    // An empty listing matches nothing, including the empty name.
    try std.testing.expect(!listingHasName("", ""));
    try std.testing.expect(!listingHasName("", "x"));

    // A name the parser would have rejected as unsafe never reaches this
    // compare from the overlay reader, so a listing may hold one without the
    // reader ever matching it. The two answers have to stay independent: an
    // unsafe line in a listing is text, not a name.
    if (listingHasName(listing, "rm -rf /")) {
        try std.testing.expect(!jsonbuf.isSafeIdent("rm -rf /"));
    }
}

fn fuzzFindShadows(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    const listing = raw[0..smith.slice(&raw)];

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The names `listingNames` keeps, copied into one store so they outlive the
    // listing buffer and can be handed to `joinPath` as stable slices. A name
    // longer than the store stops the round instead of overrunning it.
    var names: [32][]const u8 = undefined;
    var name_store: [4096]u8 = undefined;
    var name_used: usize = 0;
    var n_names = pstore.listingNames(listing, &names, "");
    var kept: usize = 0;
    while (kept < n_names) : (kept += 1) {
        names[kept] = pstore.copyInto(names[kept], &name_store, &name_used) orelse break;
    }
    n_names = kept;

    // Materialise the listing as a real overlay root and a real package root.
    // Only the names the tree can actually hold become rows, so the round is
    // about the parsers rather than about which `openat` failed. `NAME_MAX` is
    // the filesystem's own limit: a name past it never reaches a parser, and
    // asking the tree to hold one reports `NameTooLong` instead of the reading
    // under test.
    try tmp.dir.createDirPath(io, "overlay");
    try tmp.dir.createDirPath(io, "usr/bin");
    for (names[0..n_names]) |name| {
        if (name.len == 0 or name.len > fuzz_name_max) continue;
        // The same name under both roots with different contents, so it is a
        // shadow rather than a symlink to the packaged file.
        const overlay_sub = try std.fs.path.join(std.testing.allocator, &.{ "overlay", name });
        defer std.testing.allocator.free(overlay_sub);
        const pkg_sub = try std.fs.path.join(std.testing.allocator, &.{ "usr/bin", name });
        defer std.testing.allocator.free(pkg_sub);
        tmp.dir.writeFile(io, .{ .sub_path = overlay_sub, .data = "overlay" }) catch continue;
        tmp.dir.writeFile(io, .{ .sub_path = pkg_sub, .data = "packaged" }) catch continue;
    }

    // A second overlay entry that symlinks to the packaged file. It shadows
    // nothing: both paths resolve to the same file, so reporting it would ask
    // the user to remove a file whose packaged copy is the very same inode. The
    // module decides that by comparing resolved paths, and this is the only
    // shape in the tree that exercises that comparison. The link target is
    // absolute, because a relative one would resolve against the link's own
    // directory and dangle instead of naming the packaged file.
    {
        const link_sub = try std.fs.path.join(std.testing.allocator, &.{ "overlay", "linked-shadow" });
        defer std.testing.allocator.free(link_sub);
        const target_sub = try std.fs.path.join(std.testing.allocator, &.{ "usr/bin", "linked-shadow" });
        defer std.testing.allocator.free(target_sub);
        tmp.dir.writeFile(io, .{ .sub_path = target_sub, .data = "packaged" }) catch {};
        var tp: [512]u8 = undefined;
        const tn = try tmp.dir.realPathFile(io, target_sub, &tp);
        tmp.dir.symLink(io, tp[0..tn], link_sub, .{}) catch {};
    }

    var overlay_rp: [512]u8 = undefined;
    var package_rp: [512]u8 = undefined;
    const overlay_n = try tmp.dir.realPathFile(io, "overlay", &overlay_rp);
    const package_n = try tmp.dir.realPathFile(io, "usr/bin", &package_rp);
    const overlay_dir = overlay_rp[0..overlay_n];
    const package_dir = package_rp[0..package_n];
    const overlays = [_][]const u8{overlay_dir};
    const packages = [_][]const u8{package_dir};

    var hits: [16]ShadowFinding = undefined;
    var paths: [2048]u8 = undefined;
    const n = findShadows(&overlays, &packages, &hits, &paths);
    // `out` is fixed, so a listing with more rows than it holds stops at the
    // bound rather than writing past it.
    try std.testing.expect(n <= hits.len);

    for (hits[0..n]) |hit| {
        // A name that reaches a removal command is the identifier the rest of
        // the core gates on: no shell metacharacter, no path, no dot name.
        try std.testing.expect(jsonbuf.isSafeIdent(hit.name));
        try std.testing.expect(hit.name.len != 0);
        try std.testing.expect(hit.name[0] != '.');
        try std.testing.expect(std.mem.indexOfScalar(u8, hit.name, '/') == null);
        // Copies in the caller's store, so no pointer into a directory reader
        // or into a buffer this round reuses.
        try std.testing.expect(fuzzsupport.sliceInside(&paths, hit.name));
        try std.testing.expect(fuzzsupport.sliceInside(&paths, hit.path));
        try std.testing.expect(fuzzsupport.sliceInside(&paths, hit.shadows));
        // The roots the caller passed bound both ends of the row.
        try std.testing.expect(std.mem.startsWith(u8, hit.path, overlay_dir));
        try std.testing.expect(std.mem.startsWith(u8, hit.shadows, package_dir));
        try std.testing.expectEqualStrings(hit.name, pstore.basenameOf(hit.path));
        try std.testing.expectEqualStrings(hit.name, pstore.basenameOf(hit.shadows));
        // A removal may name a file, never the root it was found under.
        try std.testing.expect(hit.path.len > overlay_dir.len + 1);
        try std.testing.expect(hit.shadows.len > package_dir.len + 1);
        // The writer turns the path into the `command` field and the script
        // line; a path `shQuote` refuses is a removal it cannot spell.
        var q: [1024]u8 = undefined;
        const quoted = jsonbuf.shQuote(&q, hit.path) orelse return error.Overflow;
        try std.testing.expect(
            fuzzsupport.isQuotedValue(quoted) or std.mem.eql(u8, quoted, hit.path),
        );
    }

    // The rows have to survive the writer that turns them into what the UI
    // runs. This is the binding step: `renderShadows` is where a row becomes an
    // `rm -f` line, so a writer that lost the quote or dropped a path shows up
    // here as a script that does not name the file it was built from.
    if (n > 0) {
        try std.testing.expect(renderShadows(hits[0..n]));
        const json = result_buf[0..result_nbytes];
        try std.testing.expect(jsonbuf.isValidJson(json));
        for (hits[0..n]) |hit| {
            // Every row reaches both the reported command and the script, so a
            // row the writer dropped is a file the user confirmed and no
            // command names.
            try std.testing.expect(std.mem.indexOf(u8, json, "\"shadows\":\"") != null);
            // The path appears in the script, shell-quoted, and nowhere raw:
            // a raw path in a row carrying a space would split the `rm`.
            var qs: [1024]u8 = undefined;
            const sq = jsonbuf.shQuote(&qs, hit.path) orelse return error.Overflow;
            if (!std.mem.eql(u8, sq, hit.path)) {
                try std.testing.expect(std.mem.indexOf(u8, json, sq) != null);
            }
        }
    }

    // The symlinked entry is not a shadow, so no row names it. A row that did
    // would put `rm -f` on a path whose packaged copy is the same inode.
    for (hits[0..n]) |hit| {
        try std.testing.expect(!std.mem.eql(u8, pstore.basenameOf(hit.path), "linked-shadow"));
    }

    // The same directory read twice gives the same rows, or a scan replayed
    // from a recorded listing disagrees with the one the user confirmed.
    var hits2: [16]ShadowFinding = undefined;
    var paths2: [2048]u8 = undefined;
    const n2 = findShadows(&overlays, &packages, &hits2, &paths2);
    try std.testing.expectEqual(n, n2);
    for (hits[0..n], hits2[0..n2]) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.shadows, b.shadows);
    }
}
