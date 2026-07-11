const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Nether targets Linux/KVM. Default to cross-compiling x86_64-linux so the
    // build type-checks on any host (e.g. macOS); override with -Dtarget=...
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    });
    const optimize = b.standardOptimizeOption(.{});

    // On Apple Silicon the HVF backend only gets the hypervisor if the binary is
    // codesigned with the com.apple.security.hypervisor entitlement. Automate that
    // so `zig build -Dtarget=native` (and `zig build run`) always yield a signed,
    // runnable binary - the whole "rebuilt, forgot to re-sign, HV_DENIED" class is
    // killed. scripts/sign.sh is the single source of truth (see docs/codesigning.md).
    // Options are declared unconditionally so -Dcodesign=false is always accepted
    // (e.g. to hand signing to a downstream release pipeline).
    const codesign_opt = b.option(
        bool,
        "codesign",
        "Codesign the native macOS binary with the hypervisor entitlement (default: on when host and target are macOS)",
    );
    const entitlements_path = b.option(
        []const u8,
        "entitlements",
        "Path to the codesign entitlements plist (default: nether.entitlements)",
    ) orelse "nether.entitlements";

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

    // Auto-sign the installed native binary. Gate to a macOS host building a macOS
    // target: codesign only exists on macOS, and it only embeds the entitlement into
    // a Mach-O (an ELF cross-build would sign "generic" and silently drop it, so we
    // must not run it there - scripts/sign.sh also asserts this defensively).
    const host_is_macos = builtin.os.tag == .macos;
    const target_is_macos = target.result.os.tag == .macos;
    const do_codesign = codesign_opt orelse (host_is_macos and target_is_macos);
    var sign_step: ?*std.Build.Step = null;
    if (do_codesign and host_is_macos and target_is_macos) {
        const sign = b.addSystemCommand(&.{
            b.pathFromRoot("scripts/sign.sh"),
            b.getInstallPath(.bin, exe.out_filename),
            b.pathFromRoot(entitlements_path),
        });
        // Sign the INSTALLED copy (in zig-out), not the content-addressed cache
        // artifact - mutating a cache output out-of-band would confuse the cache.
        sign.step.dependOn(b.getInstallStep());
        const sign_top = b.step("sign", "Codesign the native binary with the hypervisor entitlement (implies install)");
        sign_top.dependOn(&sign.step);
        // Make bare `zig build` (the default step is install) produce a SIGNED binary.
        // `zig build install` still installs unsigned if explicitly requested.
        b.default_step = sign_top;
        sign_step = &sign.step;
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // A launched VM will HV_DENIED on an unsigned binary, so `zig build run` must
    // sign first on native macOS.
    if (sign_step) |s| run_cmd.step.dependOn(s);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_desc = if (target.result.os.tag == .macos)
        "Run the Nether VMM (HVF; auto-codesigned via scripts/sign.sh)"
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
