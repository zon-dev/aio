const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("aio", .{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // HTTP 服务器示例
    const http_server_module = b.addModule("http_server", .{
        .root_source_file = b.path("examples/http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_server_module.addImport("aio", module);

    const http_server = b.addExecutable(.{
        .name = "http_server",
        .root_module = http_server_module,
    });

    const run_http_server = b.addRunArtifact(http_server);
    run_http_server.step.dependOn(b.getInstallStep());

    const http_server_step = b.step("http_server", "Run HTTP server example");
    http_server_step.dependOn(&run_http_server.step);
}
