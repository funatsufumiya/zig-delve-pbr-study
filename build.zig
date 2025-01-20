const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const variants = [_][]const u8{
        "",  // default main.zig
        // "diamond",
        // Add more variants here as needed
    };

    const delve_dep = b.dependency("delve", .{
        .target = target,
        .optimize = optimize,
    });

    for (variants) |variant| {
        const exe_name = if (variant.len == 0) 
            "delve_pbr_study" 
        else 
            b.fmt("delve_pbr_study_{s}", .{variant});

        const source_path = if (variant.len == 0)
            "src/main.zig"
        else
            b.fmt("src/main_{s}.zig", .{variant});

        const step_name = if (variant.len == 0)
            "run"
        else
            b.fmt("run-{s}", .{variant});

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path(source_path),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("delve", delve_dep.module("delve"));

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(step_name, "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
