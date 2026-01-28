const std = @import("std");

const lua = @import("lua.c");

const definitions = @import("definitions.zig");

/// Wrap it up !
fn wrapFunction(comptime func: anytype) lua.lua_CFunction {
    const t_info = @typeInfo(@TypeOf(func));
    if (t_info != .@"fn")
        @compileError("Cannot wrap non function types !");
    const fn_info = t_info.@"fn";

    const Args = std.meta.ArgsTuple(@TypeOf(func));
    const ReturnType = fn_info.return_type;

    return struct {
        fn dispatch(L_nullable: ?*lua.lua_State) callconv(.c) c_int {
            if (L_nullable == null) {
                return 0;
            }
            const L = L_nullable.?;

            var args: Args = undefined;
            if (lua.lua_gettop(L) != fn_info.params.len) {
                _ = lua.lua_pushstring(L, "Invalid number of arguments");
                _ = lua.lua_error(L);
                return 0;
            }

            inline for (@typeInfo(Args).@"struct".fields, 1..) |field, i| {
                @field(args, field.name) = get(L, field.type, i) catch {
                    _ = lua.lua_pushstring(L, "Invalid type for argument");
                    _ = lua.lua_error(L);
                    return 0;
                };
            }

            if (ReturnType) |RT| {
                const val: RT = @call(.auto, func, args);
                if (@typeInfo(RT) == .@"struct") {
                    const rt_info = @typeInfo(RT).@"struct";
                    if (!rt_info.is_tuple)
                        @compileError("Non tuple structs not supported yet");

                    if (lua.lua_checkstack(L, rt_info.fields.len) == 0) {
                        _ = lua.lua_error(L);
                        return 0;
                    }

                    inline for (rt_info.fields) |field| {
                        push(L, @field(val, field.name));
                    }

                    return rt_info.fields.len;
                } else {
                    if (lua.lua_checkstack(L, 1) == 0) {
                        _ = lua.lua_error(L);
                        return 0;
                    }

                    push(L, val);

                    return 1;
                }
            } else {
                @call(.auto, func, args);
            }
        }
    }.dispatch;
}

/// If it walks like a string, quacks
/// like a string, it is probably a string.
pub fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| {
            const is_slice = ptr.size == .slice;
            const is_many_sentinel = (ptr.size == .many and ptr.sentinel() != null) or ptr.size == .c;
            return ptr.child == u8 and (is_slice or is_many_sentinel);
        },
        .array => |arr| arr.child == u8,
        else => false,
    };
}

/// Push a value to the stack. Will guess
/// as best as possible which type of lua value
/// you want to push given the zig type.
/// See implementation for further details.
pub fn push(L: *lua.lua_State, value: anytype) void {
    if (@TypeOf(value) == void)
        return;
    const T = @TypeOf(value);
    const t_info = @typeInfo(T);

    switch (t_info) {
        .null => lua.lua_pushnil(L),
        .int, .comptime_int => lua.lua_pushnumber(L, @floatFromInt(value)),
        .float, .comptime_float => lua.lua_pushnumber(L, @floatCast(value)),
        .bool => lua.lua_pushboolean(L, @intFromBool(value)),
        .optional => {
            if (value) |capt| {
                push(L, capt);
            } else {
                push(L, null);
            }
        },
        .vector, .array => {
            if (isStringLike(T)) {
                const slice: []const u8 = &value;
                push(L, slice);
                return;
            }

            lua.lua_createtable(L, value.len, 0);

            for (value, 1..) |item, i| {
                push(L, item);
                lua.lua_seti(L, -2, @intCast(i));
            }
        },
        .@"struct" => |str| {
            lua.lua_createtable(L, 0, str.fields.len);

            inline for (str.fields) |field| {
                push(L, field.name);
                push(L, @field(value, field.name));
                lua.lua_settable(L, -3);
            }
        },
        .pointer => |ptr| {
            if (T == @typeInfo(lua.lua_CFunction).optional.child) {
                lua.lua_pushcfunction(L, value);
                return;
            }

            const is_simple = ptr.size == .one;

            if (is_simple) {
                push(L, value.*);
                return;
            }

            if (isStringLike(T)) {
                const str: []const u8 = blk: {
                    if (ptr.size != .slice) {
                        break :blk std.mem.span(value);
                    }

                    break :blk value;
                };
                _ = lua.lua_pushlstring(L, @ptrCast(str.ptr), str.len);
                return;
            }

            const is_slice = ptr.size == .slice;
            const is_many_sentinel = (ptr.size == .many and ptr.sentinel() != null) or ptr.size == .c;

            if (!is_slice and !is_many_sentinel)
                @compileError("Pointers need to be slices or sentinel terminated");

            const slice: []const ptr.child = blk: {
                if (is_slice)
                    break :blk value;

                break :blk std.mem.span(value);
            };

            lua.lua_createtable(L, @intCast(slice.len), 0);

            for (slice, 1..) |item, i| {
                push(L, item);
                lua.lua_seti(L, -2, @intCast(i));
            }
        },
        .@"fn" => push(L, wrapFunction(value)),
        else => @compileError("Unsupported push type: " ++ @typeName(T)),
    }
}

pub const GetError = error{
    InvalidPopType,
    OutOfBounds,
} || std.mem.Allocator.Error;

/// Gets a value from the stack, WITHOUT POPPING IT !
/// Useful if you want to manipulate a string or else.
pub fn get(L: *lua.lua_State, comptime T: type, index: c_int) GetError!T {
    const pop_type = lua.lua_type(L, index);
    const t_info = @typeInfo(T);

    return switch (t_info) {
        .null => {
            if (pop_type != lua.LUA_TNIL)
                return error.InvalidPopType;

            return null;
        },
        .int => {
            if (pop_type != lua.LUA_TNUMBER and pop_type != lua.LUA_TSTRING)
                return error.InvalidPopType;

            const i = lua.lua_tonumberx(L, index, null);

            if (i < std.math.minInt(T) or std.math.maxInt(T) < i) {
                return error.OutOfBounds;
            }

            return @intFromFloat(i);
        },
        .float => {
            if (pop_type != lua.LUA_TNUMBER and pop_type != lua.LUA_TSTRING)
                return error.InvalidPopType;

            const f = lua.lua_tonumberx(L, index, null);

            return @floatCast(f);
        },
        .comptime_int,
        .comptime_float,
        => @compileError("Compile time values cannot be obtained from lua stack"),
        .bool => {
            if (pop_type != lua.LUA_TBOOLEAN)
                return error.InvalidPopType;

            return lua.lua_toboolean(L, index) == 1;
        },
        .optional => |opt| {
            if (pop_type == lua.LUA_TNIL)
                return null;

            return try get(L, opt.child, index);
        },
        .vector, .array => |arr| {
            if (pop_type != lua.LUA_TTABLE)
                return null;

            var temp: [arr.len]arr.child = undefined;

            for (1..arr.len + 1) |i| {
                _ = lua.lua_geti(L, index, i);
                defer lua.lua_pop(L, 1);

                temp[i - 1] = try get(L, lua.lua_gettop(L));
            }

            return temp;
        },
        .@"struct" => |str| {
            if (pop_type != lua.LUA_TTABLE)
                return error.InvalidPopType;

            var temp: T = undefined;

            inline for (str.fields) |field| {
                _ = lua.lua_getfield(L, index, field.name);
                defer lua.lua_pop(L, 1);

                @field(temp, field.name) = try get(L, field.type, lua.lua_gettop(L));
            }

            return temp;
        },
        .pointer => |ptr| {
            const is_slice = ptr.size == .slice;
            const is_simple = ptr.size == .one;

            if (is_simple) {
                _ = try get(L, ptr.child, index); // trigger any type error
                return @ptrCast(lua.lua_topointer(L, index));
            }

            if (comptime !isStringLike(T)) {
                @compileLog(T);
                @compileError("Only string like multi item pointer are supported");
            }

            if (pop_type != lua.LUA_TSTRING and pop_type != lua.LUA_TNUMBER)
                return error.InvalidPopType;

            var len: usize = 0;
            const str = lua.lua_tolstring(L, index, &len);

            if (is_slice) {
                return str[0..len];
            }
            return str;
        },
        .@"fn",
        => @compileError("Functions cannot be obtained from lua stack"),
        else => @compileError("Unsupported get type: " ++ @typeName(T)),
    };
}
