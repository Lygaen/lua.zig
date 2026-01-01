const std = @import("std");

const lua = @import("lua.c");

pub const Type = enum(u8) {
    nil = lua.LUA_TNIL,
    number = lua.LUA_TNUMBER,
    boolean = lua.LUA_TBOOLEAN,
    string = lua.LUA_TSTRING,
    table = lua.LUA_TTABLE,
    function = lua.LUA_TFUNCTION,
    userdata = lua.LUA_TUSERDATA,
    thread = lua.LUA_TTHREAD,
    light_userdata = lua.LUA_TLIGHTUSERDATA,
};

pub const LuaLibs = packed struct(c_int) {
    basic: bool,
    package: bool,
    coroutine: bool,
    debug: bool,
    io: bool,
    math: bool,
    os: bool,
    string: bool,
    table: bool,
    utf: bool,
    _: @Int(.unsigned, @bitSizeOf(c_int) - 10) = 0,

    pub const none: @This() = @bitCast(@as(c_int, 0));
    pub const all: @This() = @bitCast(~@as(c_int, 0));
    /// Disables the following "risky" packages :
    ///     - "package": users won't be able to load
    /// external code/dlls
    ///     - "io": users won't be able to read/write
    /// to a file
    ///     - "os": users won't be able to execute
    /// abitrary commands
    pub const sandboxed: @This() = .{
        .basic = true,
        .package = false,
        .coroutine = true,
        .debug = true,
        .io = false,
        .math = true,
        .os = false,
        .string = true,
        .table = true,
        .utf = true,
    };

    pub fn toValue(self: @This()) c_int {
        return @bitCast(std.mem.bigToNative(c_int, @bitCast(self)));
    }
};

pub const LuaError = error{
    Yield,
    Runtime,
    Syntax,
    Memory,
    General,
};

pub fn luaAlloc(userdata: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const alloc_ptr: *std.mem.Allocator = @ptrCast(@alignCast(userdata));

    // nsize = 0 means it acts like C's free
    if (nsize == 0) {
        if (ptr) |block| {
            alloc_ptr.free(@as([*]u8, @ptrCast(block))[0..osize]);
        }
        return null;
    }

    if (ptr) |block| {
        // Reallocation request
        const new_ptr = alloc_ptr.realloc(@as([*]u8, @ptrCast(block))[0..osize], nsize) catch return null;
        return new_ptr.ptr;
    } else {
        // Allocation request
        const new_ptr = alloc_ptr.alloc(u8, nsize) catch return null;
        return new_ptr.ptr;
    }
}

pub const IoReaderUserData = struct {
    reader: std.Io.Reader,
    buffer: []u8,
};

pub fn luaIOReader(_: ?*lua.lua_State, data: ?*anyopaque, size: [*c]usize) callconv(.c) [*c]const u8 {
    const ud: *IoReaderUserData = @ptrCast(@alignCast(data));
    const filled = ud.reader.readSliceShort(ud.buffer) catch {
        size.* = 0;
        return null;
    };

    size.* = filled;
    return ud.buffer.ptr;
}
