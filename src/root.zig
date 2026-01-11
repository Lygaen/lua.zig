//! This is a **very experimental** thin wrapper over Lua's C
//! API. This was initially done for a personal side-project
//! but seeing the state of other libraries (not matching my needs),
//! decided to give it open source it.
//!
//! I use the MIT License.
//!
//! Most of the coding is done inside `Lua.zig`. This will
//! be where you pull most of the code.
//!
//! There is also a diagnostics system in place.
//! To learn the API, read those docs or read the
//! examples (recommended). Here's the `simple.zig` file
//! that show how generally the API works.
//!
//! ```zig
//! const std = @import("std");
//! const lua = @import("lua-zig");
//!
//! const LUA_PROGRAM =
//!  \\ print("Hello World !")
//! ;
//!
//! pub fn main() !void {
//!     var alloc: std.heap.GeneralPurposeAllocator(.{}) = .init;
//!     defer _ = alloc.deinit();
//!     const allocator = alloc.allocator();
//!
//!     var state: lua.Lua = try .init(allocator, .{});
//!     defer state.deinit();
//!     defer {
//!     if (state.diag.hasErr()) {
//!             std.log.err("{}: {s}", .{ state.diag.err.?, state.diag.message });
//!         }
//!     }
//!
//!
//!     const reader = std.Io.Reader.fixed(LUA_PROGRAM);
//!     try state.loadFromReader(reader);
//!     try state.callRaw(null);
//! }
//! ```

pub const definitions = @import("definitions.zig");
pub const Diag = @import("Diag.zig");
pub const Lua = @import("Lua.zig");
