const std = @import("std");

const BuildLua = @import("BuildLua.zig");

const EXAMPLES_NAMES = [_][]const u8{
    "simple",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check_step = b.step("check", "Checks that everything compiles");
    const skip_zig = b.option(bool, "skip-zig", "Skip any zig related stuff, does a generic lua build") orelse false;

    const lua_lib: BuildLua = .init(b, target, optimize);
    lua_lib.install(b);

    if (skip_zig)
        return;

    const lua_c = lua_lib.toModule(b);

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
