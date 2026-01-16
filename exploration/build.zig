const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const objc_dep = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    const cocoa_module = b.addModule("cocoa", .{
        .root_source_file = b.path("src/cocoa.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "objc", .module = objc_dep.module("objc") },
        },
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/window_example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cocoa", .module = cocoa_module },
            .{ .name = "objc", .module = objc_dep.module("objc") },
        },
    });
    exe_module.linkFramework("Cocoa", .{});

    const exe = b.addExecutable(.{
        .name = "window_example",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the window example");
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const check_exe = b.addExecutable(.{
        .name = "check",
        .root_module = exe_module,
    });

    const check_step = b.step("check", "Run the window example");
    check_step.dependOn(&check_exe.step);
}
