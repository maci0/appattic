const abi = @import("abi.zig");

/// Publish `json` as the whole plugin result: the whole of `buf`, and its
/// length in `n`.
///
/// Every plugin answers a manager it could not run by writing its own
/// "inactive" document here and returning 0, and every one of them spelled the
/// pair out the same way. `buf` and `n` are the buffer and the length the
/// plugin declares and hands to `bind`, so the caller cannot publish into a
/// buffer the ABI does not read back.
///
/// @intCast traps when the document is longer than what `n` can hold, which is
/// the point: the document is a compile-time constant and the buffer is not.
pub fn publishMissing(buf: []u8, n: *u32, json: []const u8) void {
    @memcpy(buf[0..json.len], json);
    n.* = @intCast(json.len);
}

/// WASM ABI for one query plugin. Each plugin is a separate compilation;
/// `comptime { plugin_abi.bind(id, queryImpl, &result_buf, &result_nbytes); }`
/// exports the guest symbols the host looks up, taking the result buffer and
/// its length where the plugin keeps them. See path_listing.zig for the
/// listing variant.
pub fn bind(
    comptime id: []const u8,
    comptime queryImpl: anytype,
    comptime buf: anytype,
    comptime n: anytype,
) void {
    const Impl = struct {
        fn plugin_abi_version() callconv(.c) i32 {
            return abi.ABI_VERSION;
        }
        fn plugin_id_ptr() callconv(.c) i32 {
            return @intCast(@intFromPtr(id.ptr));
        }
        fn plugin_id_len() callconv(.c) i32 {
            return @intCast(id.len);
        }
        fn plugin_query(present: i32) callconv(.c) i32 {
            return queryImpl(present);
        }
        fn result_ptr() callconv(.c) i32 {
            return @intCast(@intFromPtr(buf));
        }
        fn result_len() callconv(.c) i32 {
            return @intCast(n.*);
        }
    };
    @export(&Impl.plugin_abi_version, .{ .name = "plugin_abi_version" });
    @export(&Impl.plugin_id_ptr, .{ .name = "plugin_id_ptr" });
    @export(&Impl.plugin_id_len, .{ .name = "plugin_id_len" });
    @export(&Impl.plugin_query, .{ .name = "plugin_query" });
    @export(&Impl.result_ptr, .{ .name = "result_ptr" });
    @export(&Impl.result_len, .{ .name = "result_len" });
}
