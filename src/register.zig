const std = @import("std");

const lua = @import("lua.c");

fn wrap(comptime Func: anytype) lua.lua_CFunction {
    _ = Func; // autofix
    return undefined;
}
