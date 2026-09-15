const std = @import("std");
const linux = std.os.linux;
const listing = @import("./path_listing.zig");
const jsonbuf = @import("./jsonbuf.zig");
const jsonscan = @import("./jsonscan.zig");
const apt = @import("./apt.zig");

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000000000 + @as(u64, @intCast(ts.nsec));
}

var sink: usize = 0;
var list_text: []u8 = &.{};
var apt_text: []u8 = &.{};

fn bench(name: []const u8, iters: usize, f: *const fn () usize) void {
    _ = f();
    const t0 = now();
    var local: usize = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) local +%= f();
    const ns = now() - t0;
    sink +%= local;
    std.debug.print("{s:28} {d:8} {d:12.1} {d}\n", .{ name, iters, @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)), local });
}

fn rep(n: usize, args_fn: *const fn (usize, []u8) []u8, buf: []u8) []u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const line = args_fn(i, &tmp);
        @memcpy(buf[pos..][0..line.len], line);
        pos += line.len;
        buf[pos] = '\n';
        pos += 1;
    }
    return buf[0..pos];
}

fn listingLine(i: usize, tmp: []u8) []u8 {
    return std.fmt.bufPrint(tmp, "leftover-app-{d:0>4}-data", .{i}) catch unreachable;
}
fn aptLine(i: usize, tmp: []u8) []u8 {
    return std.fmt.bufPrint(tmp, "libpkg{d}/stable {d}.{d}.1 amd64 [upgradable from: {d}.{d}.0]", .{ i, i % 40, (i * 7) % 90, i % 40, (i * 7) % 90 }) catch unreachable;
}

fn fListing() usize {
    var hits: [8192]listing.Orphan = undefined;
    var paths: [262144]u8 = undefined;
    return listing.parseListing(list_text, "dconf\nhtop\n", "/home/user/.config", &hits, &paths, "");
}
fn fSysName() usize {
    return if (listing.isSystemLeftoverName("leftover-app-0042-data")) 1 else 0;
}
fn fSysNameHit() usize {
    return if (listing.isSystemLeftoverName("dconf")) 1 else 0;
}
fn fApt() usize {
    var out: [8192]apt.AptOutdated = undefined;
    return apt.parseAptUpgradable(apt_text, &out);
}
fn fJsonStr() usize {
    var buf: [256]u8 = undefined;
    var w = jsonbuf.W{ .buf = &buf };
    w.str("/home/user/.config/leftover-app-0042-data");
    return w.slice().?.len;
}
fn fJsonDeps() usize {
    var out: [512]jsonscan.Dep = undefined;
    return jsonscan.parseJsonDependencies(npm_json, &out);
}

pub fn main() void {
    var list_buf: [512 * 1024]u8 = undefined;
    var apt_buf: [512 * 1024]u8 = undefined;
    list_text = rep(5000, &listingLine, &list_buf);
    apt_text = rep(5000, &aptLine, &apt_buf);

    bench("zig_parse_listing", 10, &fListing);
    bench("zig_is_system_name_miss", 20000, &fSysName);
    bench("zig_is_system_name_hit", 20000, &fSysNameHit);
    bench("zig_apt_upgradable", 10, &fApt);
    bench("zig_json_str", 2000, &fJsonStr);
    bench("zig_json_deps", 20, &fJsonDeps);
    std.debug.print("sink={d}\n", .{sink});
}

const npm_json =
    \\{"name":"lib","dependencies":{"typescript":{"version":"5.4.5"},"prettier":{"version":"3.3.0"},"@vue/cli":{"version":"5.0.8"},"nx":{"version":"19.0.0"},"jest":{"version":"29.7.0"},"eslint":{"version":"8.57.0"}}}
;
