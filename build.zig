const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pass no options through — fy's build.zig registers its own `target`
    // and `optimize` via standard*Option, and zig 0.16 surfaces a warning
    // when we forward them. Our exe module takes the locally-resolved
    // target/optimize anyway; fy just needs to compile to the same ABI,
    // which matches since both default to the host.
    const fy_dep = b.dependency("fy", .{});
    const fy_mod = fy_dep.module("fy");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("fy", fy_mod);
    exe_mod.addImport("tamzen", b.createModule(.{ .root_source_file = b.path("vendor/tamzen/tamzen.zig") }));
    // The version About shows, from build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "slab",
        .root_module = exe_mod,
    });

    configureNativeDeps(b, exe_mod);

    const kernel_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_probe_mod.addImport("fy", fy_mod);
    configureNativeDeps(b, kernel_probe_mod);

    const kernel_probe = b.addExecutable(.{
        .name = "kernel-probe",
        .root_module = kernel_probe_mod,
    });

    const kernel_probe_cmd = b.addRunArtifact(kernel_probe);
    if (b.args) |args| kernel_probe_cmd.addArgs(args);
    const kernel_probe_step = b.step("kernel-probe", "Run a testable Fy DSP kernel fixture");
    kernel_probe_step.dependOn(&kernel_probe_cmd.step);

    // Headless machine workbench (docs/17 Track C): same adapter as the DAW.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("fy", fy_mod);
    configureNativeDeps(b, bench_mod);
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    const bench_cmd = b.addRunArtifact(bench);
    if (b.args) |args| bench_cmd.addArgs(args);
    const bench_step = b.step("bench", "Render machines headless: sheets, reports, goldens");
    bench_step.dependOn(&bench_cmd.step);

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // macOS ad-hoc codesign with JIT entitlements so fy's MAP_JIT pages
    // execute. Signs the installed binary in place, gated on install.
    const codesign = b.addSystemCommand(&[_][]const u8{
        "codesign", "-s", "-", "--force", "--entitlements", "entitlements.plist", "--options", "runtime",
    });
    codesign.addArg(b.getInstallPath(.bin, exe.out_filename));
    codesign.step.dependOn(&install.step);
    b.getInstallStep().dependOn(&codesign.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Slab");
    run_step.dependOn(&run_cmd.step);

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    const bench_tests = b.addTest(.{ .root_module = bench_mod });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
}

fn configureNativeDeps(b: *std.Build, mod: *std.Build.Module) void {
    // raylib via homebrew — @cImport in src/c.zig picks up the header here.
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("raylib", .{});

    // miniaudio — vendored single-header, single-TU.
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    mod.addCSourceFile(.{
        .file = b.path("src/native_dialog.m"),
        .flags = &.{"-fobjc-arc"},
    });
    mod.addCSourceFile(.{
        .file = b.path("src/native_app.m"),
        .flags = &.{"-fobjc-arc"},
    });
    mod.addCSourceFile(.{
        .file = b.path("src/native_ml.m"),
        .flags = &.{"-fobjc-arc"},
    });
    mod.addCSourceFile(.{ .file = b.path("src/native_audio.c") });
    mod.addIncludePath(b.path("vendor"));

    // macOS frameworks needed by raylib + miniaudio.
    mod.linkFramework("CoreAudio", .{});
    mod.linkFramework("AudioToolbox", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("IOKit", .{});
    mod.linkFramework("OpenGL", .{});
    // The extractors' models (docs/30 §Stems).
    mod.linkFramework("CoreML", .{});
    mod.link_libc = true;
}
