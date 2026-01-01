const std = @import("std");

const lua = @import("lua.c");

const Diag = @import("Diag.zig");
const utils = @import("utils.zig");

const Lua = @This();

L: *lua.lua_State,
allocator: *std.mem.Allocator,
diag: Diag,

pub const InitError = std.mem.Allocator.Error || error{
    LuaError,
};

pub const InitOptions = struct {
    load_libraries: utils.LuaLibs = .all,
    preload_libraries: utils.LuaLibs = .none,
};

pub fn init(allocator: std.mem.Allocator, options: InitOptions) InitError!Lua {
    const alloc_ptr = try allocator.create(std.mem.Allocator);
    alloc_ptr.* = allocator;

    const new_state = lua.lua_newstate(&utils.luaAlloc, alloc_ptr, 0);
    if (new_state == null)
        return error.LuaError;

    lua.luaL_openselectedlibs(
        new_state,
        options.load_libraries.toValue(),
        options.preload_libraries.toValue(),
    );

    return .{
        .L = new_state.?,
        .allocator = alloc_ptr,
        .diag = .{},
    };
}

pub fn loadFromReader(self: *@This(), reader: std.Io.Reader) utils.LuaError!void {
    var buff: [64]u8 = undefined;
    var ud: utils.IoReaderUserData = .{
        .reader = reader,
        .buffer = &buff,
    };

    try self.diag.luaToDiag(
        self.L,
        lua.lua_load(
            self.L,
            &utils.luaIOReader,
            &ud,
            "lua.zig io-reader",
            null,
        ),
    );
}

pub const CallError = error{
    NotAFunction,
    NotFound,
} || utils.LuaError;

pub fn call(self: *@This(), name: ?[*c]const u8) CallError!void {
    if (name) |function_name| {
        const t: utils.Type = @enumFromInt(lua.lua_getglobal(self.L, function_name));

        if (t == .nil) {
            return error.NotFound;
        }

        if (t != .function) {
            return error.NotAFunction;
        }
    }

    try self.diag.luaToDiag(
        self.L,
        lua.lua_pcallk(self.L, 0, lua.LUA_MULTRET, 0, 0, null),
    );
}

pub fn deinit(self: *@This()) void {
    lua.lua_close(self.L);
    self.allocator.destroy(self.allocator);
}
