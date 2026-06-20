const std = @import("std");

pub fn build(b: *std.Build) void {
    // Nether targets Linux/KVM. Default to cross-compiling x86_64-linux so the
    // build type-checks on any host (e.g. macOS); override with -Dtarget=...
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nether",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The HVF backend (macOS hosts) links Apple's Hypervisor.framework and needs
    // libSystem. The binary must then be codesigned with the hypervisor
    // entitlement before it can run; ad-hoc signing works for local dev:
    //   codesign --sign - --entitlements nether.entitlements --force <binary>
    if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("Hypervisor", .{});
        exe.root_module.link_libc = true;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Nether VMM (requires Linux + /dev/kvm)");
    run_step.dependOn(&run_cmd.step);

    // Tests build for the host so `zig build test` runs locally. The pure-logic
    // and ABI checks have no KVM dependency. On a macOS host whose xcode-select
    // points into Xcode.app, prefix with DEVELOPER_DIR=/Library/Developer/
    // CommandLineTools so the native link finds the SDK.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ABI/layout tests");
    test_step.dependOn(&run_tests.step);
}
