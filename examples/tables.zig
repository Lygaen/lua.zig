const std = @import("std");

const lua = @import("lua-zig");

const Opt = struct {
    field: []const u8,
};

const Ret = struct {
    ret: []const u8,
};

const LUA_PROGRAM =
    \\function print_opt(o)
    \\    return { ret = "another one: " .. o.field }
    \\end
;

pub fn main(init: std.process.Init) !void {
    var state: lua.Lua = try .init(init.gpa, .{});
    defer state.deinit();
    defer {
        if (state.diag.hasErr()) {
            std.log.err("{}: {s}", .{ state.diag.err.?, state.diag.message });
        }
    }

    const reader = std.Io.Reader.fixed(LUA_PROGRAM);
    try state.loadFromReader(reader);
    // The program must be ran once to load symbols
    try state.run();

    const ret = try state.call("print_opt", .{
        Opt{
            .field = "Hello World!",
        },
    }, Ret);
    defer state.free(ret); // Free all data inside of it

    std.log.debug("Return is : {s}", .{ret.ret});
}
