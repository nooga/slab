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

    const exe = b.addExecutable(.{
        .name = "slab",
        .root_module = exe_mod,
    });

    // raylib via homebrew — @cImport in src/c.zig picks up the header here.
    exe_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe_mod.linkSystemLibrary("raylib", .{});

    // miniaudio — vendored single-header, single-TU.
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    exe_mod.addCSourceFile(.{
        .file = b.path("src/native_dialog.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe_mod.addIncludePath(b.path("vendor"));

    // macOS frameworks needed by raylib + miniaudio.
    exe_mod.linkFramework("CoreAudio", .{});
    exe_mod.linkFramework("AudioToolbox", .{});
    exe_mod.linkFramework("CoreFoundation", .{});
    exe_mod.linkFramework("Cocoa", .{});
    exe_mod.linkFramework("IOKit", .{});
    exe_mod.linkFramework("OpenGL", .{});
    exe_mod.link_libc = true;

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

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
