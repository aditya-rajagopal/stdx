const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("stdx", .{
        .root_source_file = b.path("src/stdx.zig"),
        .target = target,
    });

    const @"test" = b.addTest(.{
        .name = "check",
        .root_module = mod,
    });
    // const run_tests = b.addRunArtifact(test_exe);

    // const test_step = b.step("test", "Run the test executable");
    // test_step.dependOn(&run_tests.step);

    const check_step = b.step("check", "Run the check executable");
    check_step.dependOn(&@"test".step);
}
