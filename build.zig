const std = @import("std");
const builtin = @import("builtin");

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

        buildShaders(b);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(step_name, "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}

fn buildShaders(b: *std.Build) void {
    const sokol_tools_bin_dir = "../sokol-tools-bin/bin/";
    const shaders_dir = "assets/shaders/";
    const shaders_out_dir = "src/shaders/";

    const shaders = .{
        "pbr",
    };

    const optional_shdc: ?[:0]const u8 = comptime switch (builtin.os.tag) {
        .windows => "win32/sokol-shdc.exe",
        .linux => "linux/sokol-shdc",
        .macos => if (builtin.cpu.arch.isX86()) "osx/sokol-shdc" else "osx_arm64/sokol-shdc",
        else => null,
    };

    if (optional_shdc == null) {
        std.log.warn("unsupported host platform, skipping shader compiler step", .{});
        return;
    }

    const shdc_step = b.step("shaders", "Compile shaders (needs ../sokol-tools-bin)");
    const shdc_path = sokol_tools_bin_dir ++ optional_shdc.?;
    const slang = "glsl300es:glsl430:wgsl:metal_macos:metal_ios:metal_sim:hlsl4";

    // build the .zig versions
    inline for (shaders) |shader| {
        const shader_with_ext = shader ++ ".glsl";
        const cmd = b.addSystemCommand(&.{
            shdc_path,
            "-i",
            shaders_dir ++ shader_with_ext,
            "-o",
            shaders_out_dir ++ shader_with_ext ++ ".zig",
            "-l",
            slang,
            "-f",
            "sokol_zig",
            "--reflection",
        });
        shdc_step.dependOn(&cmd.step);
    }

    // build the yaml reflection versions
    inline for (shaders) |shader| {
        const shader_with_ext = shader ++ ".glsl";
        std.fs.cwd().makePath(shaders_dir ++ "built/" ++ shader) catch |err| {
            std.log.info("Could not create path {}", .{err});
        };

        const cmd = b.addSystemCommand(&.{
            shdc_path,
            "-i",
            shaders_dir ++ shader_with_ext,
            "-o",
            shaders_dir ++ "built/" ++ shader ++ "/" ++ shader,
            "-l",
            slang,
            "-f",
            "bare_yaml",
            "--reflection",
        });
        shdc_step.dependOn(&cmd.step);
    }
}

