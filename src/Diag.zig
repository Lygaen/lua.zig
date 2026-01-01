const std = @import("std");

const lua = @import("lua.c");

const utils = @import("utils.zig");

message: [*c]const u8 = "",
err: ?utils.LuaError = null,

/// Generate a zig error from the given lua status,
/// with the case that status is out of bounds
/// returning void as well.
pub fn toErr(status: c_int) utils.LuaError!void {
    return switch (status) {
        lua.LUA_OK => {},
        lua.LUA_YIELD => error.Yield,
        lua.LUA_ERRRUN => error.Runtime,
        lua.LUA_ERRSYNTAX => error.Syntax,
        lua.LUA_ERRMEM => error.Memory,
        lua.LUA_ERRERR => error.General,
        else => {},
    };
}

/// Stores a diagnostics from the given lua state and
/// status. Doesn't do anything if status is LUA_OK
/// or if the status is out of bounds.
pub fn luaToDiag(diagnostics: *@This(), L: *lua.lua_State, status: c_int) utils.LuaError!void {
    toErr(status) catch |err| {
        diagnostics.err = err;
        diagnostics.message = lua.lua_tolstring(L, -1, null);

        return err;
    };
}

pub fn hasErr(diagnostics: @This()) bool {
    return diagnostics.err != null;
}
