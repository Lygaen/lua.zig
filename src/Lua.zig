//! The type representing a `lua_State`.
//!
//! It contains tangeant logic such as
//! loading from a reader etc.

const std = @import("std");

const lua = @import("lua.c");

const definitions = @import("definitions.zig");
const Diagnostics = @import("Diagnostics.zig");
const stack = @import("stack.zig");

const Lua = @This();

/// The internal lua state
L: *lua.lua_State,
/// Allocator for the state
allocator: *std.mem.Allocator,
/// Diagnostics for the state
diag: Diagnostics,

/// Options for modulating the creation of
/// a state.
pub const InitOptions = struct {
    load_libraries: definitions.Libraries = .all,
    preload_libraries: definitions.Libraries = .none,
};

/// Creates a new lua state from the given allocator
/// and options. Will only fail in the case of an OOM
pub fn init(allocator: std.mem.Allocator, options: InitOptions) std.mem.Allocator.Error!Lua {
    const alloc_ptr = try allocator.create(std.mem.Allocator);
    alloc_ptr.* = allocator;

    const new_state = lua.lua_newstate(&definitions.__alloc, alloc_ptr, 0);
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
pub fn loadFromReader(self: *@This(), reader: std.Io.Reader) definitions.Error!void {
    var buff: [64]u8 = undefined;
    var ud: definitions.IoReaderUserData = .{
        .reader = reader,
        .buffer = &buff,
    };

    try self.diag.luaToDiagnostics(
        self.L,
        lua.lua_load(
            self.L,
            &definitions.__IoReader,
            &ud,
            "lua.zig io-reader",
            null,
        ),
    );
}

/// Dupes a string to a c-compatible string.
/// Caller owns memory.
fn stringToCString(self: *@This(), str: []const u8) std.mem.Allocator.Error![:0]const u8 {
    return self.allocator.dupeZ(u8, str);
}

pub const CallError = error{
    NotAFunction,
    NotFound,
} || stack.GetError || definitions.Error || std.mem.Allocator.Error;

/// Runs the currently loaded script. Does no checking on the values,
/// is UB if nothing is currently on the stack.
pub fn run(self: *@This()) CallError!void {
    try self.call(null, .{}, void);
}

/// Calls for a specific lua function.
/// This can be called as such :
/// ```
/// // Equivalent to lua.run()
/// lua.call(null, .{}, void);
///
/// // Equivalent to 'invoking' the lua code `const ret = my_function(2,3)`
/// const ret = lua.call("my_function", .{2, 3}, u32);
///
/// // Multiple return values
/// const quotient, const mod = lua.call("div", .{10, 7}, .{u32, u32});
/// ```
///
/// For the return values, caller owns memory iff it is a string or the container contains
/// one (ie struct with a string field).
/// The rest is on the stack as usual.
/// If in doubt, call free on it as it is a no-op on types that don't need allocation.
pub fn call(
    self: *@This(),
    /// Name of the function or null to run the bare code
    name: ?[]const u8,
    /// Arguments to be passed, should be a tuple of values
    args: anytype,
    /// The return type, either a tuple or a type
    comptime ReturnType: anytype,
) CallError!ReturnType {
    const ArgsT = @TypeOf(args);

    if (@typeInfo(ArgsT) != .@"struct" or !@typeInfo(ArgsT).@"struct".is_tuple)
        @compileError("Args is not a tuple");
    const t_info = @typeInfo(ArgsT).@"struct";

    const ArgsTypes: [t_info.fields.len]type = comptime blk: {
        var temp: [t_info.fields.len]type = undefined;
        for (t_info.fields, 0..) |field, index| {
            temp[index] = field.type;
        }

        break :blk temp;
    };

    const return_type_length, const is_simple = comptime blk: {
        const ret_type_info = @typeInfo(@TypeOf(ReturnType));
        if (ret_type_info == .type) {
            if (ReturnType == void) {
                break :blk .{ 0, true };
            }
            break :blk .{ 1, true };
        }

        if (ret_type_info != .@"struct" or !ret_type_info.@"struct".is_tuple)
            @compileError("ReturnType must be a type or a tuple of types");

        for (ReturnType) |ret_type| {
            if (@typeInfo(@TypeOf(ret_type)) != .type)
                @compileError("ReturnType must be a type or a tuple of types");
        }

        return .{ ret_type_info.@"struct".fields.len, false };
    };

    const ReturnTypes: [return_type_length]type = comptime blk: {
        var temp: [return_type_length]type = undefined;

        if (is_simple) {
            if (return_type_length > 0) {
                temp[0] = ReturnType;
            }
            break :blk temp;
        }

        for (ReturnType, 0..) |T, index| {
            temp[index] = T;
        }

        break :blk temp;
    };

    if (name) |function_name| {
        const c_name = try self.stringToCString(function_name);
        defer self.allocator.free(c_name);
        const t = lua.lua_getglobal(self.L, c_name);

        if (t == lua.LUA_TNIL) {
            return error.NotFound;
        }

        if (t != lua.LUA_TFUNCTION) {
            return error.NotAFunction;
        }
    }

    // Push arguments
    inline for (args) |arg| {
        stack.push(self.L, arg);
    }

    try self.diag.luaToDiagnostics(
        self.L,
        lua.lua_pcallk(
            self.L,
            ArgsTypes.len,
            ReturnTypes.len,
            0,
            0,
            null,
        ),
    );

    if (is_simple) {
        if (ReturnType == void)
            return;

        defer lua.lua_pop(self.L, 1);
        return self.dupeAll(try stack.get(self.L, ReturnType, -1));
    }

    var temp: ReturnType = undefined;
    const top: usize = lua.lua_gettop(self.L);
    defer lua.lua_pop(self.L, ReturnTypes.len);

    inline for (ReturnTypes, 0..) |RT, i| {
        temp[i] = try stack.get(self.L, RT, top - i);
    }

    return try self.dupeAll(temp);
}

/// Dupe value if it is memory sensitive (pointer etc.)
/// If value is a struct, dupe if needed its fields.
fn dupeAll(self: *@This(), value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    const t_info = @typeInfo(T);

    if (t_info == .pointer) {
        const ptr = t_info.pointer;
        if (ptr.size == .one) {
            const temp = try self.allocator.create(ptr.child);
            temp.* = value.*;
            return temp;
        }

        const slice: []const ptr.child = blk: {
            if (ptr.size == .slice)
                break :blk value;

            break :blk std.mem.span(value);
        };

        if (ptr.sentinel() != null) {
            return try self.allocator.dupeZ(ptr.child, slice);
        }

        return try self.allocator.dupe(ptr.child, slice);
    }

    if (t_info == .@"struct") {
        var temp: T = undefined;
        inline for (t_info.@"struct".fields) |field| {
            @field(temp, field.name) = try self.dupeAll(@field(value, field.name));
        }
        return temp;
    }

    return value;
}

/// Free any memory associated with a struct or pointer
/// It is a no-op if the type passed should not have
/// any memory allocated.
pub fn free(self: *@This(), value: anytype) void {
    const t_info = @typeInfo(@TypeOf(value));

    if (t_info == .pointer) {
        self.allocator.free(value);
        return;
    }

    if (t_info != .@"struct")
        return;

    inline for (t_info.@"struct".fields) |field| {
        if (comptime stack.isStringLike(field.type) and @typeInfo(field.type) == .pointer) {
            self.free(@field(value, field.name));
        }
    }
}

/// Register a value as a global symbol.
/// Value can be anything from a function,
/// table, or just a simple integer etc.
pub fn setGlobal(self: *@This(), name: []const u8, value: anytype) std.mem.Allocator.Error!void {
    stack.push(self.L, value);

    const c_name = try self.stringToCString(name);
    defer self.free(c_name);

    lua.lua_setglobal(self.L, c_name);
}

/// Destroys and frees any allocation done
/// by the state
pub fn deinit(self: *@This()) void {
    lua.lua_close(self.L);
    self.allocator.destroy(self.allocator);
}
