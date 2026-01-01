const std = @import("std");

const lua = @import("lua-zig");

const LUA_PROGRAM =
    \\ print("Hello World !")
;

pub fn main() !void {
    var alloc: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = alloc.deinit();
    const allocator = alloc.allocator();

    var state: lua.Lua = try .init(allocator);
    defer state.deinit();
}
