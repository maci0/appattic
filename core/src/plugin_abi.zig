const abi = @import("abi.zig");

/// WASM ABI for one query plugin. Each plugin is a separate compilation;
/// `comptime { plugin_abi.bind(id, queryImpl, resultPtr, resultLen); }` exports
/// the guest symbols the host looks up. See path_listing.zig for the listing variant.
pub fn bind(
    comptime id: []const u8,
    comptime queryImpl: anytype,
    comptime resultPtr: anytype,
    comptime resultLen: anytype,
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
            return resultPtr();
        }
        fn result_len() callconv(.c) i32 {
            return resultLen();
        }
    };
    @export(&Impl.plugin_abi_version, .{ .name = "plugin_abi_version" });
    @export(&Impl.plugin_id_ptr, .{ .name = "plugin_id_ptr" });
    @export(&Impl.plugin_id_len, .{ .name = "plugin_id_len" });
    @export(&Impl.plugin_query, .{ .name = "plugin_query" });
    @export(&Impl.result_ptr, .{ .name = "result_ptr" });
    @export(&Impl.result_len, .{ .name = "result_len" });
}
