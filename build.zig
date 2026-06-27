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
    // Link libc on every target: the user-mode network stack (slirp) and the
    // control/file-transfer plumbing use the C socket/file APIs, and both host
    // paths (KVM and HVF) now route guest egress through slirp's firewall.
    exe.root_module.link_libc = true;
    // The HVF backend (macOS hosts) additionally links Apple's Hypervisor.framework.
    // The binary must then be codesigned with the hypervisor entitlement before it
    // can run; ad-hoc signing works for local dev:
    //   codesign --sign - --entitlements nether.entitlements --force <binary>
    if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("Hypervisor", .{});
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_desc = if (target.result.os.tag == .macos)
        "Run the Nether VMM (HVF; codesign with nether.entitlements first)"
    else
        "Run the Nether VMM (requires Linux + /dev/kvm)";
    const run_step = b.step("run", run_desc);
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
    // Same libc dependency as the exe: root.zig pulls in the slirp/control/host
    // paths that call the C socket/file APIs. macOS auto-links libc for native
    // tests, but a Linux host's test link needs it spelled out explicitly.
    tests.root_module.link_libc = true;
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ABI/layout tests");
    test_step.dependOn(&run_tests.step);

    // Coverage-guided fuzzing of the guest-facing parsers (the `fuzz:` tests in
    // src/fuzz.zig, driven via std.testing.fuzz). `zig build fuzz` runs the whole
    // suite once (the always-on smoke); `zig build fuzz --fuzz` starts the
    // coverage-guided fuzzer (web UI) over the same harnesses. Same binary as the
    // test step, exposed under its own name so the intent is discoverable.
    const fuzz_step = b.step("fuzz", "Fuzz the guest-facing parsers (add --fuzz for coverage-guided mode)");
    fuzz_step.dependOn(&run_tests.step);
}
