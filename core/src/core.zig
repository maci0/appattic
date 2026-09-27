const abi = @import("abi.zig");

export fn core_abi_version() i32 {
    return abi.ABI_VERSION;
}
