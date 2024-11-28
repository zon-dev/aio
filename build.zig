const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "aio",
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);
    // const lib = b.addStaticLibrary(.{
    //     .name = "t2",
    //     .root_source_file = b.path("src/root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // b.installArtifact(lib);

    inline for ([_]struct {
        name: []const u8,
        src: []const u8,
    }{}) |execfg| {
        const exe_name = execfg.name;
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path(execfg.src),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("io", &lib.root_module);

        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const step_name = "run-" ++ exe_name;
        const run_step = b.step(step_name, "Run the app " ++ exe_name);
        run_step.dependOn(&run_cmd.step);
    }

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/testing/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const io_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_io_tests = b.addRunArtifact(io_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_io_tests.step);
}
