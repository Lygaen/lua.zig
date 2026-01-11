//! The type representing a `lua_State`.
//!
//! It contains tangeant logic such as
//! loading from a reader etc.

const std = @import("std");

const lua = @import("lua.c");

const definitions = @import("definitions.zig");
const Diagnostics = @import("Diagnostics.zig");
const register = @import("register.zig");

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

/// Pushes a value, duplicating it using the allocator
/// only in the case of a string.
/// See `Type.fromType` for type coercion depending on the zig type.
pub fn pushValue(self: *@This(), comptime T: type, value: T) std.mem.Allocator.Error!void {
    const lua_t: definitions.Type = comptime .fromType(T);
    const t_info = @typeInfo(T);

    switch (lua_t) {
        .nil => lua.lua_pushnil(self.L),
        .number => {
            if (t_info == .int or t_info == .comptime_int) {
                lua.lua_pushnumber(self.L, @floatFromInt(value));
            } else {
                lua.lua_pushnumber(self.L, @floatCast(value));
            }
        },
        .boolean => lua.lua_pushboolean(self.L, @intFromBool(value)),
        .string => {
            const str: []const u8 = blk: {
                if (t_info.pointer.sentinel_ptr != null) {
                    break :blk std.mem.span(value);
                }

                break :blk value;
            };
            const c_str = try self.allocator.dupeZ(u8, str);

            _ = lua.lua_pushexternalstring(self.L, c_str, value.len, &definitions.__alloc, self.allocator);
        },
        else => @compileError("Invalid type"),
    }
}

/// Represents an error while trying to pop a value
pub const PopError = error{
    InvalidPopType,
    OutOfBounds,
} || std.mem.Allocator.Error;

/// Pop the top value from the stack, trying to pop void is a no-op.
/// If value is a string, caller owns the memory and must free with lua.allocator
/// This will pop the top value if the type match (eg. no `error.InvalidPopType`
/// thrown), even if there is an oom / oob error.
pub fn popValue(self: *@This(), comptime T: type) PopError!T {
    if (T == void)
        return;

    const stack_top = lua.lua_gettop(self.L);
    const pop_type: definitions.Type = @enumFromInt(lua.lua_type(self.L, stack_top));

    if (pop_type != definitions.Type.fromType(T)) {
        return error.InvalidPopType;
    }

    // Pop the value even if an error occured
    defer lua.lua_pop(self.L, stack_top);

    return switch (comptime definitions.Type.fromType(T)) {
        .boolean => lua.lua_toboolean(self.L, stack_top) != 0,
        .nil => null,
        .number => {
            const num = lua.lua_tonumberx(self.L, stack_top, null);
            const t_info = @typeInfo(T);

            if (t_info == .int) {
                return @intFromFloat(num);
            }

            if (t_info == .float) {
                return @floatCast(num);
            }

            @compileError("Popping a value doesn't support compile time int/floats");
        },
        .string => {
            const c_str = lua.lua_tostring(self.L, stack_top);
            return try self.allocator.dupe(u8, std.mem.span(c_str orelse ""));
        },
        else => @compileError("Invalid type"),
    };
}

pub const CallError = error{
    NotAFunction,
    NotFound,
} || PopError || definitions.Error || std.mem.Allocator.Error;

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
/// For the return values, caller owns memory iff it is a string. The rest
/// is on the stack as usual.
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
        const t: definitions.Type = @enumFromInt(lua.lua_getglobal(self.L, c_name));

        if (t == .nil) {
            return error.NotFound;
        }

        if (t != .function) {
            return error.NotAFunction;
        }
    }

    // Push arguments
    inline for (ArgsTypes, args) |ArgT, arg| {
        try self.pushValue(ArgT, arg);
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
        return try self.popValue(ReturnType);
    }

    var temp: ReturnType = undefined;
    inline for (ReturnTypes, 0..) |RT, i| {
        temp[i] = try self.popValue(RT);
    }

    return temp;
}

pub fn free(self: *@This(), memory: anytype) void {
    self.allocator.free(memory);
}

pub fn registerFunction(self: *@This(), name: []const u8, comptime func: anytype) std.mem.Allocator.Error!void {
    register.pushFunction(self.L, func);

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
