const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ccdocker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Copy Docker files alongside binary for dev use
    // Copy Docker files alongside binary (into zig-out/bin/)
    b.installFile("Dockerfile", "bin/Dockerfile");
    b.installFile("entrypoint.sh", "bin/entrypoint.sh");
    b.installFile(".dockerignore", "bin/.dockerignore");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ccdocker");
    run_step.dependOn(&run_cmd.step);

    // Test step — uses `zig test` directly to avoid build-runner IPC issues
    const test_cmd = b.addSystemCommand(&.{ "zig", "test", "src/main.zig" });
    test_cmd.has_side_effects = true;
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);
}
