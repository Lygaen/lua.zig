const std = @import("std");

const lua = @import("lua-zig");

const LUA_PROGRAM =
    \\function append_suffix(str, suffix)
    \\    return str .. suffix
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

    const ret = try state.call("append_suffix", .{ "lua is ", "the best !" }, []const u8);
    // Don't forget to free strings !
    defer state.free(ret);

    std.log.debug("Full string is : '{s}'", .{ret});
}
