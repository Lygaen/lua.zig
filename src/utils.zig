//! This file regroups a bunch of utilities and
//! definitions used all throughout the Lua Library.
//!
//! I know I shouldn't use a utils file but for the time
//! being I is what it is.

const std = @import("std");

const lua = @import("lua.c");

/// An enum representing possible Lua types.
/// It is compatible with the Lua API, going
/// from one to the other using @intFromEnum
/// and @enumFromInt.
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

    /// Try to guess the relevant Lua type from
    /// a Zig type. Here's the guesses
    ///     - int/float/comptime_* -> number
    ///     - bool -> boolean
    ///     - null -> nil
    ///     - pointer to some u8 -> string
    ///     - pointer matching lua.lua_CFunction -> function
    ///     - struct -> table
    ///     - undefined, noreturn, void, ... -> compile error
    pub fn fromType(comptime T: type) Type {
        return switch (@typeInfo(T)) {
            .null => .nil,
            .int, .comptime_int, .float, .comptime_float => .number,
            .bool => .boolean,
            .pointer => |ptr| {
                if (ptr.child == u8) {
                    return .string;
                }
                if (T == lua.lua_CFunction) {
                    return .function;
                }

                @compileError("Pointers to '" ++ @typeName(T) ++ "' are not supported");
            },
            .@"struct" => .table,
            else => @compileError("Unsupported Type"),
        };
    }
};

/// Representation of the standard libaries
/// that Lua offers to a file.
///
/// Mainly used for allowing the user to represent
/// which specific libraries to open during
/// the init process.
pub const LuaLibs = packed struct(c_int) {
    /// The basic library, it provides core symbols to lua :
    ///     - `assert` / `error` / `warn` / `print`
    ///     - `collectgarbage` / `_G`
    ///     - `getmetatable` / `setmetatable` / `type`
    ///     - `ipairs` / `pairs` / `next`
    ///     - `load` / `loadfile` / `dofile`
    ///     - `pcall` / `xpcall`
    ///     - `raw*`
    ///     - `to*`
    ///     - `select`
    ///     - `_VERSION`
    basic: bool,
    /// The package library provides basic facilities for
    /// loading modules in Lua.
    /// It provides the symbol :
    ///     - `require`
    ///
    /// It exports all of the standard symbols under the
    /// `package` table.
    package: bool,
    /// The library to manipulate coroutines. It provides
    /// all of the standard symbols under the table `coroutine`.
    coroutine: bool,
    /// The library that provides the functionality of Lua's
    /// debug interface. It provides all of the standard
    /// symbols under the table `debug`.
    debug: bool,
    /// The library for I/O file handles operations. It provides
    /// all of the standard symbols under the table `io`.
    io: bool,
    /// The library for mathematical functions. It provides
    /// all of the standard symbols under the table `math`.
    math: bool,
    /// The library for interacting with the OS. It provides
    /// all of the standard symbols under the table `os`.
    os: bool,
    /// The library to manipulate strings. It provides
    /// all of the standard symbols under the table `string`.
    string: bool,
    /// The library for generic table manipulation. It provides
    /// all of the standard symbols under the table `table`.
    table: bool,
    /// The library for basic UTF-8 support. It provides
    /// all of the standard symbols under the table `utf8`.
    utf: bool,
    _: @Int(.unsigned, @bitSizeOf(c_int) - 10) = 0,

    /// Selects none of the packages provided by Lua
    pub const none: @This() = @bitCast(@as(c_int, 0));
    /// Selects all of the packages provided by Lua
    pub const all: @This() = @bitCast(~@as(c_int, 0));
    /// Disables the following "risky" packages :
    ///     - "package": users won't be able to load
    /// external code/dlls (see `package.loadlib`)
    ///     - "io": users won't be able to read/write
    /// to a file (see `io.open`)
    ///     - "os": users won't be able to execute
    /// abitrary commands (see `os.execute`)
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

    /// Returns the struct as a Lua's C API
    /// compatible integer.
    pub fn toValue(self: @This()) c_int {
        return @bitCast(std.mem.bigToNative(c_int, @bitCast(self)));
    }
};

/// Represents a status code returned by error-able Lua functions
pub const Error = error{
    /// The thread / coroutines yields back to the caller.
    /// Not necessarily an error but it could be returned.
    Yield,
    /// Runtime error (unspecified by spec)
    Runtime,
    /// Syntax error during precompilation or format error in a binary chunk.
    Syntax,
    /// Memory allocation error.
    Memory,
    /// Stack overflow while running the message handler due to another stack overflow.
    /// Or, an error while calling the message handler.
    ErrorInErrorHandler,
};

/// The Zig compatible Lua C API allocation function (see
/// `lua_Alloc` in the C API). When used, a pointer to a
/// `std.mem.Allocator` should be passed as userdata.
pub fn __alloc(userdata: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const alloc_ptr: *std.mem.Allocator = @ptrCast(@alignCast(userdata));

    const block: []u8 = blk: {
        if (ptr) |safe_ptr| {
            break :blk @as([*]u8, @ptrCast(safe_ptr))[0..osize];
        }

        break :blk &.{};
    };

    const new_ptr = alloc_ptr.realloc(block, nsize) catch return null;
    return new_ptr.ptr;
}

/// User data for `__IoReader`. It should be
/// passed as a pointer to an instance of this.
pub const IoReaderUserData = struct {
    reader: std.Io.Reader,
    buffer: []u8,
};

/// The Zig's `std.Io.Reader` compatibility function for
/// Lua's C API `lua_Reader`. A `IoReaderUserData` pointer
/// should be passed as userdata to this function.
pub fn __IoReader(_: ?*lua.lua_State, data: ?*anyopaque, size: [*c]usize) callconv(.c) [*c]const u8 {
    const ud: *IoReaderUserData = @ptrCast(@alignCast(data));
    const filled = ud.reader.readSliceShort(ud.buffer) catch {
        size.* = 0;
        return null;
    };

    size.* = filled;
    return ud.buffer.ptr;
}
