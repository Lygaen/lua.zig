const std = @import("std");

lua_lib: *std.Build.Step.Compile,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
exes: ?struct {
    lua: *std.Build.Step.Compile,
    luac: *std.Build.Step.Compile,
},

const LUA_VERSION = std.SemanticVersion.parse("5.5.0") catch unreachable;

pub fn init(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_bins: bool,
) @This() {
    const lua = b.dependency("lua", .{});

    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .version = LUA_VERSION,
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
        }),
    });

    switch (target.result.os.tag) {
        .openbsd, .netbsd, .freebsd, .linux, .macos => {
            lua_lib.rdynamic = true;
        },
        else => {},
    }

    addLuaFlags(target, lua_lib.root_module);

    if (optimize == .Debug) {
        lua_lib.root_module.addCMacro("LUA_USE_APICHECK", "");
    }

    lua_lib.root_module.addCSourceFiles(.{
        .root = lua.path("src/"),
        .files = &LUA_C_FILES,
    });

    var temp: @This() = .{
        .lua_lib = lua_lib,
        .target = target,
        .optimize = optimize,
        .exes = null,
    };

    if (build_bins) {
        temp.exes = .{
            .lua = temp.createLuaBin(b, .lua),
            .luac = temp.createLuaBin(b, .luac),
        };
    }

    return temp;
}

fn createLuaBin(
    self: *@This(),
    b: *std.Build,
    name: enum {
        lua,
        luac,
    },
) *std.Build.Step.Compile {
    const lua = b.dependency("lua", .{});

    const bin = b.addExecutable(.{
        .name = @tagName(name),
        .version = LUA_VERSION,
        .root_module = b.createModule(.{
            .optimize = self.optimize,
            .target = self.target,
        }),
    });

    const name_c = b.fmt("{s}.c", .{@tagName(name)});
    bin.root_module.addCSourceFile(.{
        .file = lua.path(b.pathJoin(&.{ "src", name_c })),
    });
    addLuaFlags(self.target, bin.root_module);
    bin.root_module.linkLibrary(self.lua_lib);

    switch (self.target.result.os.tag) {
        .openbsd, .netbsd, .freebsd => {
            bin.root_module.linkSystemLibrary("edit", .{});
            bin.root_module.linkSystemLibrary("edit", .{});
        },
        .linux => {
            bin.root_module.linkSystemLibrary("dl", .{});
            bin.root_module.linkSystemLibrary("edit", .{});
        },
        .macos => {
            bin.root_module.linkSystemLibrary("readline", .{});
            bin.root_module.linkSystemLibrary("edit", .{});
        },
        else => {},
    }

    return bin;
}

pub fn install(self: @This(), b: *std.Build) void {
    const lua = b.dependency("lua", .{});

    // Install lib to PREFIX/lib/*
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(self.lua_lib, .{}).step,
    );

    // Install headers to PREFIX/include/*
    for (LUA_H_FILES) |lua_h_file| {
        const install_file = b.addInstallFileWithDir(
            lua.path(b.pathJoin(&.{ "src", lua_h_file })),
            .{ .custom = "include" },
            lua_h_file,
        );
        b.getInstallStep().dependOn(&install_file.step);
    }

    // Install bins and their man pages
    if (self.exes) |exes| {
        for (MAN_FILES) |man_file| {
            const install_file = b.addInstallFileWithDir(
                lua.path(b.pathJoin(&.{ "doc", man_file })),
                .{ .custom = "man/man1" },
                man_file,
            );
            b.getInstallStep().dependOn(&install_file.step);
        }

        b.installArtifact(exes.lua);
        b.installArtifact(exes.luac);
    }
}

/// Returns and exposes the lua translate c module under `lua.c`
pub fn toModule(self: @This(), b: *std.Build) *std.Build.Module {
    const lua = b.dependency("lua", .{});
    const write_files = b.addWriteFiles();
    const lua_all_path = write_files.add("lua_all.h", LUA_ALL_H);

    const lua_trans = b.addTranslateC(.{
        .root_source_file = lua_all_path,
        .optimize = self.optimize,
        .target = self.target,
    });

    lua_trans.addIncludePath(lua.path("src/"));
    const lua_mod = lua_trans.addModule("lua.c");
    lua_mod.linkLibrary(self.lua_lib);

    return lua_mod;
}

fn addLuaFlags(target: std.Build.ResolvedTarget, module: *std.Build.Module) void {
    switch (target.result.os.tag) {
        .openbsd, .netbsd, .freebsd => {
            module.addCMacro("LUA_USE_LINUX", "");
            module.addCMacro("LUA_USE_READLINE", "");
            module.linkSystemLibrary("edit", .{});
        },
        .ios => {
            module.addCMacro("LUA_USE_IOS", "");
        },
        .linux => {
            module.addCMacro("LUA_USE_LINUX", "");
            module.linkSystemLibrary("dl", .{});
        },
        .macos => {
            module.addCMacro("LUA_USE_MACOSX", "");
            module.addCMacro("LUA_USE_READLINE", "");
            module.linkSystemLibrary("readline", .{});
        },
        .windows => {
            module.addCMacro("LUA_BUILD_AS_DLL", "");
        },
        else => {
            module.addCMacro("LUA_USE_POSIX", "");
        },
    }
}

const LUA_C_FILES = [_][]const u8{
    "lapi.c",
    "lauxlib.c",
    "lbaselib.c",
    "lcode.c",
    "lcorolib.c",
    "lctype.c",
    "ldblib.c",
    "ldebug.c",
    "ldo.c",
    "ldump.c",
    "lfunc.c",
    "lgc.c",
    "linit.c",
    "liolib.c",
    "llex.c",
    "lmathlib.c",
    "lmem.c",
    "loadlib.c",
    "lobject.c",
    "lopcodes.c",
    "loslib.c",
    "lparser.c",
    "lstate.c",
    "lstring.c",
    "lstrlib.c",
    "ltable.c",
    "ltablib.c",
    "ltm.c",
    "lundump.c",
    "lutf8lib.c",
    "lvm.c",
    "lzio.c",
};

const LUA_H_FILES = [_][]const u8{
    "lua.h",
    "luaconf.h",
    "lualib.h",
    "lauxlib.h",
    "lua.hpp",
};

const MAN_FILES = [_][]const u8{
    "lua.1", "luac.1",
};

const LUA_ALL_H =
    \\#ifndef __LUA_ALL_H__
    \\#define __LUA_ALL_H__
    \\
    \\#include "luaconf.h"
    \\#include "lua.h"
    \\#include "lualib.h"
    \\#include "lauxlib.h"
    \\
    \\#endif // __LUA_ALL_H__
;
