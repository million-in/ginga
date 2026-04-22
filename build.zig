const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode for the installed ginga binary") orelse .ReleaseSafe;

    const mod = b.addModule("ginga", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ginga",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ginga", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const desktop_cmd = b.addSystemCommand(&.{ "bun", "scripts/desktop-check.ts", "build" });
    desktop_cmd.step.dependOn(b.getInstallStep());

    const install_global_cmd = b.addSystemCommand(&.{ "bash", "scripts/install-global.sh", "zig-out/bin/ginga" });
    install_global_cmd.step.dependOn(b.getInstallStep());

    const desktop_step = b.step("desktop", "Build the Electron desktop shell");
    desktop_step.dependOn(&desktop_cmd.step);

    const install_global_step = b.step("install-global", "Install the ginga CLI onto the shell PATH");
    install_global_step.dependOn(&install_global_cmd.step);

    const all_step = b.step("all", "Build the ginga CLI and the Electron desktop shell");
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(&desktop_cmd.step);
    all_step.dependOn(&install_global_cmd.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
