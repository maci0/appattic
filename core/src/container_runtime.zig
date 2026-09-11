const std = @import("std");
const abi = @import("abi.zig");
const jsonbuf = @import("jsonbuf.zig");
const host_exec = @import("host_exec.zig");

const plugin_id = "container-runtime";
const q_images = "images -f dangling=true";
const q_volumes = "volume ls -f dangling=true";
const q_ps = "ps -a -f status=exited";

var result_buf: [16384]u8 = undefined;
var result_nbytes: u32 = 0;
var images_buf: [4096]u8 = undefined;
var volumes_buf: [4096]u8 = undefined;
var ps_buf: [4096]u8 = undefined;

const none_json =
    \\{"plugin":"container-runtime","engine":null,"findings":[],"script":null,"dialog":{"title":"No container engine","body":"Install docker or podman to scan runtime leftovers. Nothing to remove."},"note":"no container engine"}
;

pub const Hit = struct {
    id: []const u8,
    name: []const u8,
};

fn isHexId(s: []const u8) bool {
    if (s.len < 6 or s.len > 64) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn isSafeImageId(s: []const u8) bool {
    const p = "sha256:";
    if (std.mem.startsWith(u8, s, p)) return isHexId(s[p.len..]);
    return isHexId(s);
}

fn skipHeader(first: []const u8) bool {
    return std.ascii.eqlIgnoreCase(first, "REPOSITORY") or
        std.ascii.eqlIgnoreCase(first, "DRIVER") or
        std.ascii.eqlIgnoreCase(first, "CONTAINER") or
        std.ascii.eqlIgnoreCase(first, "VOLUME");
}

/// Parse `docker images -f dangling=true` / `podman images -f dangling=true`.
/// IMAGE ID is the 3rd column. Idle-days skipped: CREATED is "N weeks ago", not a timestamp.
pub fn parseDanglingImages(text: []const u8, out: []Hit) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const repo = it.next() orelse continue;
        if (skipHeader(repo)) continue;
        _ = it.next() orelse continue;
        const id = it.next() orelse continue;
        if (!isSafeImageId(id)) continue;
        out[n] = .{ .id = id, .name = "<none>:<none>" };
        n += 1;
    }
    return n;
}

/// Parse `docker volume ls -f dangling=true` / `podman volume ls -f dangling=true`.
pub fn parseDanglingVolumes(text: []const u8, out: []Hit) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const first = it.next() orelse continue;
        if (skipHeader(first)) continue;
        var name: []const u8 = first;
        while (it.next()) |tok| name = tok;
        if (name.ptr == first.ptr) continue;
        if (!jsonbuf.isSafeIdent(name)) continue;
        out[n] = .{ .id = name, .name = name };
        n += 1;
    }
    return n;
}

/// Parse `docker ps -a -f status=exited` / `podman ps -a -f status=exited`.
/// First token is CONTAINER ID, last token is NAMES (COMMAND/STATUS have spaces).
pub fn parseExitedContainers(text: []const u8, out: []Hit) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const id = it.next() orelse continue;
        if (skipHeader(id)) continue;
        if (!isSafeImageId(id)) continue;
        var name: []const u8 = id;
        while (it.next()) |tok| name = tok;
        if (!jsonbuf.isSafeIdent(name)) name = id;
        out[n] = .{ .id = id, .name = name };
        n += 1;
    }
    return n;
}

fn execQuery(engine: []const u8, rest: []const u8, buf: []u8) i32 {
    var cmd: [128]u8 = undefined;
    const n = engine.len + 1 + rest.len;
    if (n > cmd.len) return host_exec.bad;
    @memcpy(cmd[0..engine.len], engine);
    cmd[engine.len] = ' ';
    @memcpy(cmd[engine.len + 1 ..][0..rest.len], rest);
    return host_exec.run(cmd[0..n], buf);
}

fn renderCtr(engine: []const u8, images: []const Hit, volumes: []const Hit, containers: []const Hit) bool {
    var w = jsonbuf.W{ .buf = &result_buf };
    w.raw("{\"plugin\":\"container-runtime\",\"engine\":");
    w.str(engine);
    w.raw(",\"findings\":[");
    var first = true;
    for (images) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"dangling-image\",\"id\":");
        w.str(h.id);
        w.raw(",\"name\":\"<none>:<none>\",\"status\":\"orphaned\",\"command\":\"");
        w.raw(engine);
        w.raw(" rmi ");
        w.raw(h.id);
        w.raw("\"}");
    }
    for (volumes) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"unused-volume\",\"id\":");
        w.str(h.id);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"status\":\"orphaned\",\"command\":\"");
        w.raw(engine);
        w.raw(" volume rm ");
        w.raw(h.id);
        w.raw("\"}");
    }
    for (containers) |h| {
        if (!first) w.raw(",");
        first = false;
        w.raw("{\"kind\":\"stopped-container\",\"id\":");
        w.str(h.id);
        w.raw(",\"name\":");
        w.str(h.name);
        w.raw(",\"status\":\"review\",\"command\":\"");
        w.raw(engine);
        w.raw(" rm ");
        w.raw(h.id);
        w.raw("\"}");
    }
    if (!first) w.raw(",");
    w.raw("{\"kind\":\"build-cache\",\"id\":null,\"status\":\"review\",\"command\":null,\"reason\":\"unnamed cache; omitted from script\"}");
    w.raw("],\"script\":");
    const named = images.len + volumes.len + containers.len;
    if (named == 0) {
        w.raw("null");
    } else {
        w.raw("\"#!/bin/sh\\nset -e\\n# AppAttic container-runtime (");
        w.raw(engine);
        w.raw("). Review before running.\\n");
        for (images) |h| {
            w.raw(engine);
            w.raw(" rmi ");
            w.raw(h.id);
            w.raw("\\n");
        }
        for (volumes) |h| {
            w.raw(engine);
            w.raw(" volume rm ");
            w.raw(h.id);
            w.raw("\\n");
        }
        for (containers) |h| {
            w.raw(engine);
            w.raw(" rm ");
            w.raw(h.id);
            w.raw("\\n");
        }
        w.raw("\"");
    }
    w.raw(",\"dialog\":{\"title\":\"Remove container leftovers?\",\"body\":\"Named objects only. Stopped containers use named rm. Unnamed build cache is review-only. Nothing runs until you confirm.\"}}");
    const s = w.slice() orelse return false;
    result_nbytes = @intCast(s.len);
    return true;
}

fn parseBuf(nexec: i32, buf: []const u8) []const u8 {
    if (nexec < 0) return "";
    return buf[0..@intCast(nexec)];
}

export fn plugin_abi_version() i32 {
    return abi.ABI_VERSION;
}

export fn plugin_id_ptr() i32 {
    return @intCast(@intFromPtr(plugin_id.ptr));
}

export fn plugin_id_len() i32 {
    return @intCast(plugin_id.len);
}

export fn plugin_query(present: i32) i32 {
    if (present != abi.EngineDocker and present != abi.EnginePodman) {
        @memcpy(result_buf[0..none_json.len], none_json);
        result_nbytes = @intCast(none_json.len);
        return 0;
    }
    const engine: []const u8 = if (present == abi.EnginePodman) "podman" else "docker";
    const ni = execQuery(engine, q_images, &images_buf);
    const nv = execQuery(engine, q_volumes, &volumes_buf);
    const np = execQuery(engine, q_ps, &ps_buf);
    var images: [16]Hit = undefined;
    var volumes: [16]Hit = undefined;
    var containers: [16]Hit = undefined;
    var nimg = parseDanglingImages(parseBuf(ni, &images_buf), &images);
    var nvol = parseDanglingVolumes(parseBuf(nv, &volumes_buf), &volumes);
    var nps = parseExitedContainers(parseBuf(np, &ps_buf), &containers);
    while (true) {
        if (renderCtr(engine, images[0..nimg], volumes[0..nvol], containers[0..nps])) return 0;
        if (nps > 0) {
            nps -= 1;
            continue;
        }
        if (nvol > 0) {
            nvol -= 1;
            continue;
        }
        if (nimg > 0) {
            nimg -= 1;
            continue;
        }
        return 1;
    }
}

export fn result_ptr() i32 {
    return @intCast(@intFromPtr(&result_buf));
}

export fn result_len() i32 {
    return @intCast(result_nbytes);
}

test "parseDanglingImages IMAGE ID column" {
    var buf: [8]Hit = undefined;
    const text =
        \\REPOSITORY   TAG       IMAGE ID       CREATED        SIZE
        \\<none>       <none>    a1b2c3d4e5f6   2 weeks ago    12MB
        \\<none>       <none>    b9e8d7c6b5a4   3 months ago   8MB
        \\
    ;
    const n = parseDanglingImages(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("a1b2c3d4e5f6", buf[0].id);
    try std.testing.expectEqualStrings("b9e8d7c6b5a4", buf[1].id);
}

test "parseDanglingImages skips empty and header" {
    var buf: [4]Hit = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseDanglingImages("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseDanglingImages("REPOSITORY   TAG       IMAGE ID       CREATED        SIZE\n", &buf),
    );
}

test "parseDanglingVolumes last column name" {
    var buf: [8]Hit = undefined;
    const text =
        \\DRIVER    VOLUME NAME
        \\local     orphvol
        \\local     leftover_data
        \\
    ;
    const n = parseDanglingVolumes(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("orphvol", buf[0].id);
    try std.testing.expectEqualStrings("leftover_data", buf[1].id);
}

test "parseDanglingVolumes skips empty and header" {
    var buf: [4]Hit = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseDanglingVolumes("", &buf));
    try std.testing.expectEqual(@as(usize, 0), parseDanglingVolumes("DRIVER    VOLUME NAME\n", &buf));
}

test "parseExitedContainers first id last name" {
    var buf: [8]Hit = undefined;
    const text =
        \\CONTAINER ID   IMAGE     COMMAND   CREATED        STATUS                      PORTS     NAMES
        \\c0ffee123456   nginx     nginx     3 weeks ago    Exited (0) 3 weeks ago                web
        \\deadbeef0001   alpine    sh        2 months ago   Exited (1) 2 months ago               oldjob
        \\
    ;
    const n = parseExitedContainers(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("c0ffee123456", buf[0].id);
    try std.testing.expectEqualStrings("web", buf[0].name);
    try std.testing.expectEqualStrings("deadbeef0001", buf[1].id);
    try std.testing.expectEqualStrings("oldjob", buf[1].name);
}

test "parseExitedContainers skips empty and header" {
    var buf: [4]Hit = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseExitedContainers("", &buf));
    try std.testing.expectEqual(
        @as(usize, 0),
        parseExitedContainers("CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS   PORTS   NAMES\n", &buf),
    );
}

test "plugin_query docker JSON comes from dangling images volumes ps fixtures" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(1));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"container-runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"engine\":\"docker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dangling-image") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "a1b2c3d4e5f6") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "b9e8d7c6b5a4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "orphvol") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "leftover_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "c0ffee123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"web\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "docker rmi a1b2c3d4e5f6") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "docker volume rm orphvol") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "docker rm c0ffee123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"build-cache\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "idleDays") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "unused-image") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "abandoned-compose") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "system prune") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "rmi -f") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "volume prune") == null);
}

test "plugin_query podman JSON uses podman named commands" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(2));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"engine\":\"podman\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "podman rmi a1b2c3d4e5f6") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "podman volume rm orphvol") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "podman rm c0ffee123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "docker rmi") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "system prune") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "abandoned-pod") == null);
}

test "plugin_query missing is empty findings" {
    try std.testing.expectEqual(@as(i32, 0), plugin_query(0));
    const json = result_buf[0..result_nbytes];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "no container engine") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "system prune") == null);
}
