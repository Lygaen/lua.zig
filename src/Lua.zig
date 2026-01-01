const std = @import("std");

const lua = @import("lua.c");

const Diag = @import("Diag.zig");

const Lua = @This();

L: *lua.lua_State,
allocator: *std.mem.Allocator,
diag: Diag,

fn luaAlloc(userdata: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const alloc_ptr: *std.mem.Allocator = @ptrCast(@alignCast(userdata));

    if (ptr) |block| {
        const remapped = alloc_ptr.remap(@as([*]u8, @ptrCast(block))[0..osize], nsize);
        if (remapped) |new_ptr| {
            return new_ptr.ptr;
        }
        return null;
    }

    if (nsize == 0)
        return null;

    const new_ptr = alloc_ptr.alloc(u8, nsize) catch return null;

    return new_ptr.ptr;
}

pub const InitError = std.mem.Allocator.Error || error{
    LuaError,
};

pub fn init(allocator: std.mem.Allocator) InitError!Lua {
    const alloc_ptr = try allocator.create(std.mem.Allocator);
    alloc_ptr.* = allocator;

    const new_state = lua.lua_newstate(&luaAlloc, alloc_ptr, 0);
    if (new_state == null)
        return error.LuaError;

    return .{
        .L = new_state.?,
        .allocator = alloc_ptr,
        .diag = .{},
    };
}

pub fn deinit(self: *@This()) void {
    lua.lua_close(self.L);
    self.allocator.destroy(self.allocator);
}
