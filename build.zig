const std = @import("std");

const EXAMPLES_NAMES = [_][]const u8{
    "simple",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check_step = b.step("check", "Checks that everything compiles");

    generateLuaModule(b, target, optimize);
    const lua_c = b.modules.get("lua.c") orelse unreachable;

    // Library
    const lib_mod = b.addModule("lua.zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("lua.c", lua_c);

    const lib_artifact = b.addLibrary(.{
        .name = "lua-zig",
        .root_module = lib_mod,
    });
    b.installArtifact(lib_artifact);
    check_step.dependOn(&lib_artifact.step);

    inline for (EXAMPLES_NAMES) |example_name| {
        const exe = b.addExecutable(.{
            .name = example_name,
            .root_module = b.addModule(example_name, .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(b.pathJoin(&.{
                    "examples/",
                    example_name ++ ".zig",
                })),
            }),
            .use_llvm = true,
        });

        exe.root_module.addImport("lua-c", lua_c);
        exe.root_module.addImport("lua-zig", lib_mod);

        check_step.dependOn(&exe.step);

        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        const run_step = b.step("run-" ++ example_name, "Run the example '" ++ example_name ++ "'");
        run_step.dependOn(&run_exe.step);
    }

    const docs_step = b.step("docs", "Emits the library documentation");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = lib_artifact.getEmittedDocs(),
    }).step);
}

/// Generates and exposes a zig translate-c module of
/// the lua library under the `lua.c` module
pub fn generateLuaModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const lua = b.dependency("lua", .{});

    const write_files = b.addWriteFiles();
    const lua_all_path = write_files.add("lua_all.h", LUA_ALL_H);

    const lua_trans = b.addTranslateC(.{
        .root_source_file = lua_all_path,
        .optimize = optimize,
        .target = target,
    });

    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .version = std.SemanticVersion.parse("5.5.0") catch unreachable,
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
        }),
    });

    switch (target.result.os.tag) {
        .openbsd, .netbsd, .freebsd => {
            lua_lib.root_module.addCMacro("LUA_USE_LINUX", "");
            lua_lib.root_module.addCMacro("LUA_USE_READLINE", "");
            lua_lib.root_module.linkSystemLibrary("edit", .{});
            lua_lib.rdynamic = true;
        },
        .ios => {
            lua_lib.root_module.addCMacro("LUA_USE_IOS", "");
        },
        .linux => {
            lua_lib.root_module.addCMacro("LUA_USE_LINUX", "");
            lua_lib.root_module.linkSystemLibrary("dl", .{});
            lua_lib.rdynamic = true;
        },
        .macos => {
            lua_lib.root_module.addCMacro("LUA_USE_MACOSX", "");
            lua_lib.root_module.addCMacro("LUA_USE_READLINE", "");
            lua_lib.root_module.linkSystemLibrary("readline", .{});
            lua_lib.rdynamic = true;
        },
        .windows => {
            lua_lib.root_module.addCMacro("LUA_BUILD_AS_DLL", "");
        },
        else => {
            lua_lib.root_module.addCMacro("LUA_USE_POSIX", "");
        },
    }

    if (optimize == .Debug) {
        lua_lib.root_module.addCMacro("LUA_USE_APICHECK", "");
    }

    lua_lib.root_module.addCSourceFiles(.{
        .root = lua.path("src/"),
        .files = &LUA_C_FILES,
    });

    b.getInstallStep().dependOn(
        &b.addInstallArtifact(lua_lib, .{}).step,
    );

    lua_trans.addIncludePath(lua.path("src/"));
    lua_trans.addModule("lua.c").linkLibrary(lua_lib);
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
