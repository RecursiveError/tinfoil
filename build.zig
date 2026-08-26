const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.createModule(.{
        .root_source_file = b.path("src/usb_core/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const interfaces = b.createModule(.{
        .root_source_file = b.path("src/buildin_interfaces/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    interfaces.addImport("core", core);

    const tinfoil = b.addModule("tinfoil", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    tinfoil.addImport("core", core);
    tinfoil.addImport("interfaces", interfaces);
}
