//! Lua.zig way of representing a diagnostic.
//! It contains both the thrown error as well
//! as a message if the API generated any.

const std = @import("std");

const lua = @import("lua.c");

const definitions = @import("definitions.zig");

/// The human-friendly message of the error
message: [*c]const u8 = "",
/// The error that was thrown
err: ?anyerror = null,

/// Generate a zig error from the given lua status,
/// with the case that status is out of bounds
/// returning void as well.
pub fn luaErr(status: c_int) definitions.Error!void {
    return switch (status) {
        lua.LUA_OK => {},
        lua.LUA_YIELD => error.Yield,
        lua.LUA_ERRRUN => error.Runtime,
        lua.LUA_ERRSYNTAX => error.Syntax,
        lua.LUA_ERRMEM => error.Memory,
        lua.LUA_ERRERR => error.ErrorInErrorHandler,
        else => {},
    };
}

/// Stores a diagnostics from the given lua state and
/// status. Doesn't do anything if status is LUA_OK
/// or if the status is out of bounds.
pub fn luaToDiag(diagnostics: *@This(), L: *lua.lua_State, status: c_int) definitions.Error!void {
    luaErr(status) catch |err| {
        diagnostics.err = err;
        diagnostics.message = lua.lua_tolstring(L, -1, null);

        return err;
    };
}

/// Returns whether the diagnostics has any
/// error.
pub fn hasErr(diagnostics: @This()) bool {
    return diagnostics.err != null;
}
