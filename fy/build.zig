const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    // Options
    const codesign_id_opt = b.option([]const u8, "codesign-id", "Code signing identity for macOS JIT (omit for ad-hoc)");
    const codesign_id = codesign_id_opt orelse "-";
    const want_exe = b.option(bool, "exe", "Build the fy CLI (requires zigline, currently broken on 0.16)") orelse false;

    // ------------------------------------------------------------------
    // Library module — the Fy runtime, consumable by other zig projects
    // (e.g. slab). No REPL, no zigline dependency.
    // ------------------------------------------------------------------
    const fy_mod = b.addModule("fy", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C headers (zig 0.17 has no @cImport): src/c.h becomes module "c".
    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    fy_mod.addImport("c", c_mod);

    // Static library artifact — for C consumers of the C-ABI.
    const lib = b.addLibrary(.{
        .name = "fy",
        .linkage = .static,
        .root_module = fy_mod,
    });
    b.installArtifact(lib);

    // ------------------------------------------------------------------
    // Unit tests — run against the library module.
    // ------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = fy_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (builtin.os.tag == .macos) {
        const sign_tests_enabled = b.option(bool, "codesign-tests", "Codesign unit tests for macOS JIT (default: false)") orelse false;
        if (sign_tests_enabled) {
            const sign_tests = b.addSystemCommand(&[_][]const u8{
                "codesign", "-s", codesign_id, "--force", "--entitlements", "entitlements.plist", "--options", "runtime",
            });
            sign_tests.addFileArg(unit_tests.getEmittedBin());
            sign_tests.step.dependOn(&unit_tests.step);
            run_unit_tests.step.dependOn(&sign_tests.step);
        }
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ------------------------------------------------------------------
    // Microbenchmarks — generated-code timing plus compiler report counters.
    // Use `zig build bench --release=fast -- --iters 10000000`.
    // ------------------------------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("fy", fy_mod);
    const bench_exe = b.addExecutable(.{
        .name = "fy-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();

    if (builtin.os.tag == .macos) {
        const sign_bench_enabled = b.option(bool, "codesign-bench", "Codesign benchmark executable for macOS JIT (default: false)") orelse false;
        if (sign_bench_enabled) {
            const sign_bench = b.addSystemCommand(&[_][]const u8{
                "codesign", "-s", codesign_id, "--force", "--entitlements", "entitlements.plist", "--options", "runtime",
            });
            sign_bench.addFileArg(bench_exe.getEmittedBin());
            sign_bench.step.dependOn(&bench_exe.step);
            run_bench.step.dependOn(&sign_bench.step);
        }
    }
    const bench_step = b.step("bench", "Run fy microbenchmarks");
    bench_step.dependOn(&run_bench.step);

    // ------------------------------------------------------------------
    // Optional CLI executable — gated on -Dexe=true. The REPL pulls in
    // zigline which hasn't been ported to zig 0.16 yet. Build when it
    // becomes relevant again; for now the library target is what slab
    // needs.
    // ------------------------------------------------------------------
    if (want_exe) {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("c", c_mod);
        const exe = b.addExecutable(.{
            .name = "fy",
            .root_module = exe_mod,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        const run_step = b.step("run", "Run fy CLI");
        run_step.dependOn(&run_cmd.step);

        if (builtin.os.tag == .macos) {
            const sign_exe = b.addSystemCommand(&[_][]const u8{
                "codesign", "-s", codesign_id, "--force", "--entitlements", "entitlements.plist", "--options", "runtime",
            });
            sign_exe.addFileArg(exe.getEmittedBin());
            sign_exe.step.dependOn(&exe.step);
            run_cmd.step.dependOn(&sign_exe.step);
        }
    }
}
