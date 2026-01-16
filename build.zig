const std = @import("std");

const BuildLua = @import("BuildLua.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check_step = b.step("check", "Checks that everything compiles");
    const skip_zig = b.option(bool, "skip-zig", "Skip any zig related stuff, does a generic lua build") orelse false;
    const skip_lua_exes = b.option(bool, "skip-lua-exes", "Skip any lua exes compilation (useful if missing deps)") orelse false;

    const lua_lib: BuildLua = .init(b, target, optimize, skip_lua_exes);
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

    const cwd = std.Io.Dir.cwd().openDir(b.graph.io, "examples", .{
        .iterate = true,
    }) catch @panic("Could not open examples/ directory !");
    var iter = cwd.iterateAssumeFirstIteration();

    while (iter.next(b.graph.io) catch @panic("Could not walk examples/ directory !")) |entry| {
        if (entry.kind != .file)
            continue;
        const filename = entry.name;
        const example_name = std.fs.path.stem(filename);
        const step_name = b.fmt("run-{s}", .{example_name});
        defer b.allocator.free(step_name);

        const exe = b.addExecutable(.{
            .name = example_name,
            .root_module = b.addModule(example_name, .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(b.pathJoin(&.{
                    "examples/",
                    filename,
                })),
            }),
            .use_llvm = true,
        });

        exe.root_module.addImport("lua-c", lua_c);
        exe.root_module.addImport("lua-zig", lib_mod);

        check_step.dependOn(&exe.step);

        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        const run_step = b.step(step_name, "Run the example");
        run_step.dependOn(&run_exe.step);
    }

    const docs_step = b.step("docs", "Emits the library documentation");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = lib_artifact.getEmittedDocs(),
    }).step);
}
