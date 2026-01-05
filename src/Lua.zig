//! The type representing a `lua_State`.
//!
//! It contains tangeant logic such as
//! loading from a reader etc.

const std = @import("std");

const lua = @import("lua.c");

const Diag = @import("Diag.zig");
const utils = @import("utils.zig");

const Lua = @This();

/// The internal lua state
L: *lua.lua_State,
/// Allocator for the state
allocator: *std.mem.Allocator,
/// Diagnostics for the state
diag: Diag,

/// Options for modulating the creation of
/// a state.
pub const InitOptions = struct {
    load_libraries: utils.LuaLibs = .all,
    preload_libraries: utils.LuaLibs = .none,
};

/// Creates a new lua state from the given allocator
/// and options. Will only fail in the case of an OOM
pub fn init(allocator: std.mem.Allocator, options: InitOptions) std.mem.Allocator.Error!Lua {
    const alloc_ptr = try allocator.create(std.mem.Allocator);
    alloc_ptr.* = allocator;

    const new_state = lua.lua_newstate(&utils.__alloc, alloc_ptr, 0);
    // Spec guarantees that newstate will only fail if OOM
    if (new_state == null)
        return error.OutOfMemory;

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

/// Loads a lua text or binary from an Io.Reader.
/// Lua determines if it is a binary or text.
pub fn loadFromReader(self: *@This(), reader: std.Io.Reader) utils.Error!void {
    var buff: [64]u8 = undefined;
    var ud: utils.IoReaderUserData = .{
        .reader = reader,
        .buffer = &buff,
    };

    try self.diag.luaToDiag(
        self.L,
        lua.lua_load(
            self.L,
            &utils.__IoReader,
            &ud,
            "lua.zig io-reader",
            null,
        ),
    );
}

pub const CallError = error{
    NotAFunction,
    NotFound,
} || utils.Error;

pub fn callRaw(self: *@This(), name: ?[*c]const u8) CallError!void {
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

/// Destroys and frees any allocation done
/// by the state
pub fn deinit(self: *@This()) void {
    lua.lua_close(self.L);
    self.allocator.destroy(self.allocator);
}
