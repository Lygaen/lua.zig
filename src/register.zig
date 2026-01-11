const std = @import("std");

const lua = @import("lua.c");

const definitions = @import("definitions.zig");

fn get(L: *lua.lua_State, index: c_int, comptime T: type) error{
    InvalidPopType,
}!T {
    const pop_type: definitions.Type = @enumFromInt(lua.lua_type(L, index));

    if (pop_type != definitions.Type.fromType(T)) {
        return error.InvalidPopType;
    }

    return switch (comptime definitions.Type.fromType(T)) {
        .boolean => lua.lua_toboolean(L, index) != 0,
        .nil => null,
        .number => {
            const num = lua.lua_tonumberx(L, index, null);
            const t_info = @typeInfo(T);

            if (t_info == .int) {
                return @intFromFloat(num);
            }

            if (t_info == .float) {
                return @floatCast(num);
            }

            @compileError("Popping a value doesn't support compile time int/floats");
        },
        .string => lua.lua_tostring(L, index),
        else => @compileError("Invalid type"),
    };
}

fn push(L: *lua.lua_State, value: anytype) void {
    if (@TypeOf(value) == void)
        return;

    const lua_t: definitions.Type = comptime .fromType(@TypeOf(value));
    const t_info = @typeInfo(@TypeOf(value));

    switch (lua_t) {
        .nil => lua.lua_pushnil(L),
        .number => {
            if (t_info == .int or t_info == .comptime_int) {
                lua.lua_pushnumber(L, @floatFromInt(value));
            } else {
                lua.lua_pushnumber(L, @floatCast(value));
            }
        },
        .boolean => lua.lua_pushboolean(L, @intFromBool(value)),
        .string => @compileError("TODO: Do something about strings"),
        else => @compileError("Invalid type"),
    }
}

fn wrap(comptime func: anytype) lua.lua_CFunction {
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
                @field(args, field.name) = get(L, i, field.type) catch {
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

pub fn pushFunction(L: *lua.lua_State, comptime Func: anytype) void {
    lua.lua_pushcfunction(L, wrap(Func));
}
