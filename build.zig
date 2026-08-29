const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opentelemetry = b.dependency("opentelemetry", .{});
    const sdk_module = opentelemetry.module("sdk");
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_module = httpz.module("httpz");

    const executable = b.addExecutable(.{
        .name = "cache-api",
        .root_module = appModule(b, target, optimize, sdk_module, httpz_module),
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_command.addArgs(args);

    const run_step = b.step("run", "Run the cache API");
    run_step.dependOn(&run_command.step);

    const tests = b.addTest(.{
        .root_module = appModule(b, target, optimize, sdk_module, httpz_module),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run cache API tests");
    test_step.dependOn(&run_tests.step);
}

fn appModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk_module: *std.Build.Module,
    httpz_module: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "opentelemetry-sdk", .module = sdk_module },
            .{ .name = "httpz", .module = httpz_module },
        },
    });
}
