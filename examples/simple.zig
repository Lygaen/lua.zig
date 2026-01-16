const std = @import("std");

const lua = @import("lua-zig");

fn functor(value: u32) u32 {
    std.log.debug("functor({})", .{value});

    return value * value;
}

const LUA_PROGRAM =
    \\function multiply(x, y)
    \\    local z = x * y
    \\    z = functor(z)
    \\    return z
    \\end
;

pub fn main() !void {
    var alloc: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = alloc.deinit();
    const allocator = alloc.allocator();

    var state: lua.Lua = try .init(allocator, .{});
    defer state.deinit();
    defer {
        if (state.diag.hasErr()) {
            std.log.err("{}: {s}", .{ state.diag.err.?, state.diag.message });
        }
    }

    try state.registerFunction("functor", functor);

    const reader = std.Io.Reader.fixed(LUA_PROGRAM);
    try state.loadFromReader(reader);
    // The program must be ran once to load symbols
    try state.run();

    const ret = try state.call("multiply", .{ 2, 3 }, u32);

    std.log.debug("functor(2 * 3) = {}", .{ret});
}
